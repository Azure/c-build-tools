// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "repo_validator.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <dirent.h>
#include <sys/stat.h>
#endif

int is_path_excluded(const char* relative_path, const char** exclude_folders, int num_excludes)
{
    for (int i = 0; i < num_excludes; i++)
    {
        size_t len = strlen(exclude_folders[i]);
        if (len == 0) continue;

        if (strncmp(relative_path, exclude_folders[i], len) == 0 &&
            (relative_path[len] == PATH_SEP || relative_path[len] == '/' ||
             relative_path[len] == '\\' || relative_path[len] == '\0'))
        {
            return 1;
        }
    }
    return 0;
}

unsigned int classify_file_type(const char* filename)
{
    const char* dot = strrchr(filename, '.');
    if (!dot) return 0;

    if (strcmp(dot, ".c") == 0)   return FILE_TYPE_C;
    if (strcmp(dot, ".h") == 0)   return FILE_TYPE_H;
    if (strcmp(dot, ".cpp") == 0) return FILE_TYPE_CPP;
    if (strcmp(dot, ".hpp") == 0) return FILE_TYPE_HPP;
    if (strcmp(dot, ".cs") == 0)  return FILE_TYPE_CS;
    if (strcmp(dot, ".md") == 0)  return FILE_TYPE_MD;
    if (strcmp(dot, ".txt") == 0) return FILE_TYPE_TXT;
    return 0;
}

int is_in_devdoc_directory(const char* path)
{
    // Check if any path component is "devdoc" and the file is a direct child
    const char* p = path;
    while (*p)
    {
        // Find next path separator
        const char* sep = p;
        while (*sep && *sep != '/' && *sep != '\\') sep++;
        size_t component_len = (size_t)(sep - p);

        if (component_len == 6 && strncmp(p, "devdoc", 6) == 0)
        {
            // Check if the next component is the filename (no more separators after it)
            if (*sep == '/' || *sep == '\\')
            {
                const char* after = sep + 1;
                while (*after && *after != '/' && *after != '\\') after++;
                if (*after == '\0')
                {
                    return 1;
                }
            }
        }

        if (*sep == '\0') break;
        p = sep + 1;
    }
    return 0;
}

char* read_file_content(const char* path, size_t* out_length)
{
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (size < 0)
    {
        fclose(f);
        return NULL;
    }

    char* buffer = (char*)malloc((size_t)size + 1);
    if (!buffer)
    {
        fclose(f);
        return NULL;
    }

    size_t read_count = fread(buffer, 1, (size_t)size, f);
    fclose(f);

    buffer[read_count] = '\0';
    if (out_length) *out_length = read_count;

    return buffer;
}

int compute_line_number(const char* content, size_t offset)
{
    int line = 1;
    for (size_t i = 0; i < offset; i++)
    {
        if (content[i] == '\n') line++;
    }
    return line;
}

typedef struct walk_context_tag
{
    const VALIDATOR_CONFIG* config;
    const CHECK_DEFINITION** checks;
    int num_checks;
    int total_violations;
} WALK_CONTEXT;

static int process_file(WALK_CONTEXT* ctx, const char* full_path, const char* relative_path)
{
    const char* filename = strrchr(full_path, PATH_SEP);
#ifdef _WIN32
    if (!filename) filename = strrchr(full_path, '/');
#endif
    if (filename) filename++;
    else filename = full_path;

    unsigned int file_type = classify_file_type(filename);
    if (file_type == 0) return 0;

    int in_devdoc = is_in_devdoc_directory(relative_path);

    unsigned int flags = file_type;
    if (in_devdoc) flags |= FILE_FLAG_IN_DEVDOC;

    // Check if filename contains _ut (unit test file)
    if (strstr(filename, "_ut.c") != NULL || strstr(filename, "_ut.") != NULL)
    {
        flags |= FILE_FLAG_IS_UT;
    }

    // Determine if any active check needs this file
    int needed = 0;
    for (int i = 0; i < ctx->num_checks; i++)
    {
        const CHECK_DEFINITION* check = ctx->checks[i];

        if (check->requires_devdoc && !in_devdoc) continue;
        if ((check->file_types & file_type) == 0) continue;

        needed = 1;
        break;
    }

    if (!needed) return 0;

    // Read file content
    size_t content_length = 0;
    char* content = read_file_content(full_path, &content_length);
    if (!content) return 0;

    // Build FILE_INFO
    FILE_INFO file_info;
    memset(&file_info, 0, sizeof(file_info));
    strncpy(file_info.path, full_path, MAX_PATH_LENGTH - 1);
    strncpy(file_info.relative_path, relative_path, MAX_PATH_LENGTH - 1);
    file_info.type_flags = flags;
    file_info.content = content;
    file_info.content_length = content_length;

    // Run each check on this file
    for (int i = 0; i < ctx->num_checks; i++)
    {
        const CHECK_DEFINITION* check = ctx->checks[i];

        if (check->requires_devdoc && !in_devdoc) continue;
        if ((check->file_types & file_type) == 0) continue;

        if (check->check_file)
        {
            int result = check->check_file(&file_info, ctx->config);
            if (result > 0)
            {
                ctx->total_violations += result;
            }
        }
    }

    free(content);
    return 0;
}

#ifdef _WIN32
static int walk_directory_recursive(WALK_CONTEXT* ctx, const char* dir)
{
    char search_path[MAX_PATH_LENGTH];
    snprintf(search_path, sizeof(search_path), "%s\\*", dir);

    WIN32_FIND_DATAA ffd;
    HANDLE h_find = FindFirstFileA(search_path, &ffd);
    if (h_find == INVALID_HANDLE_VALUE) return 0;

    do
    {
        if (ffd.cFileName[0] == '.') continue;

        char full_path[MAX_PATH_LENGTH];
        snprintf(full_path, sizeof(full_path), "%s\\%s", dir, ffd.cFileName);

        // Compute relative path
        const char* relative = full_path + ctx->config->repo_root_length;
        if (*relative == '\\' || *relative == '/') relative++;

        if (ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
        {
            if (!is_path_excluded(relative, ctx->config->exclude_folders, ctx->config->num_exclude_folders))
            {
                walk_directory_recursive(ctx, full_path);
            }
        }
        else
        {
            if (!is_path_excluded(relative, ctx->config->exclude_folders, ctx->config->num_exclude_folders))
            {
                process_file(ctx, full_path, relative);
            }
        }
    } while (FindNextFileA(h_find, &ffd));

    FindClose(h_find);
    return 0;
}
#else
static int walk_directory_recursive(WALK_CONTEXT* ctx, const char* dir)
{
    DIR* d = opendir(dir);
    if (!d) return 0;

    struct dirent* entry;
    while ((entry = readdir(d)) != NULL)
    {
        if (entry->d_name[0] == '.') continue;

        char full_path[MAX_PATH_LENGTH];
        snprintf(full_path, sizeof(full_path), "%s/%s", dir, entry->d_name);

        const char* relative = full_path + ctx->config->repo_root_length;
        if (*relative == '/') relative++;

        struct stat st;
        if (stat(full_path, &st) != 0) continue;

        if (S_ISDIR(st.st_mode))
        {
            if (!is_path_excluded(relative, ctx->config->exclude_folders, ctx->config->num_exclude_folders))
            {
                walk_directory_recursive(ctx, full_path);
            }
        }
        else if (S_ISREG(st.st_mode))
        {
            if (!is_path_excluded(relative, ctx->config->exclude_folders, ctx->config->num_exclude_folders))
            {
                process_file(ctx, full_path, relative);
            }
        }
    }

    closedir(d);
    return 0;
}
#endif

int walk_repository(const VALIDATOR_CONFIG* config, const CHECK_DEFINITION** checks, int num_checks)
{
    WALK_CONTEXT ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.config = config;
    ctx.checks = checks;
    ctx.num_checks = num_checks;
    ctx.total_violations = 0;

    walk_directory_recursive(&ctx, config->repo_root);

    return ctx.total_violations;
}
