// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../repo_validator.h"

static int enable_mocks_violations;

static int enable_mocks_init(const VALIDATOR_CONFIG* config)
{
    (void)config;
    enable_mocks_violations = 0;
    return 0;
}

// Check if a line matches "#define ENABLE_MOCKS" (with optional leading whitespace)
// Returns 1 if match, 0 otherwise
static int is_define_enable_mocks(const char* line, size_t len)
{
    const char* p = line;
    const char* end = line + len;

    // Skip leading whitespace
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end || *p != '#') return 0;
    p++;
    // Skip whitespace after #
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    // Check "define"
    if (end - p < 6 || strncmp(p, "define", 6) != 0) return 0;
    p += 6;
    // Need at least one whitespace
    if (p >= end || (*p != ' ' && *p != '\t')) return 0;
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    // Check "ENABLE_MOCKS"
    if (end - p < 12 || strncmp(p, "ENABLE_MOCKS", 12) != 0) return 0;
    p += 12;
    // Should be end of line (only whitespace remaining)
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    return (p >= end);
}

// Check if a line matches "#undef ENABLE_MOCKS" (with optional leading whitespace)
static int is_undef_enable_mocks(const char* line, size_t len)
{
    const char* p = line;
    const char* end = line + len;

    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end || *p != '#') return 0;
    p++;
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (end - p < 5 || strncmp(p, "undef", 5) != 0) return 0;
    p += 5;
    if (p >= end || (*p != ' ' && *p != '\t')) return 0;
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (end - p < 12 || strncmp(p, "ENABLE_MOCKS", 12) != 0) return 0;
    p += 12;
    while (p < end && (*p == ' ' || *p == '\t')) p++;
    return (p >= end);
}

// Check if line ends with "// force" (case-insensitive)
static int has_force_comment(const char* line, size_t len)
{
    // Search backwards for "// force" pattern
    if (len < 8) return 0;
    size_t end = len;
    while (end > 0 && (line[end - 1] == ' ' || line[end - 1] == '\t')) end--;
    if (end < 8) return 0;

    // Check for "force" (case-insensitive)
    if ((line[end-5] == 'f' || line[end-5] == 'F') &&
        (line[end-4] == 'o' || line[end-4] == 'O') &&
        (line[end-3] == 'r' || line[end-3] == 'R') &&
        (line[end-2] == 'c' || line[end-2] == 'C') &&
        (line[end-1] == 'e' || line[end-1] == 'E'))
    {
        // Check for "//" before "force" with optional whitespace
        size_t j = end - 5;
        while (j > 0 && (line[j-1] == ' ' || line[j-1] == '\t')) j--;
        if (j >= 2 && line[j-1] == '/' && line[j-2] == '/')
        {
            return 1;
        }
    }
    return 0;
}

static int enable_mocks_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    const char* content = file->content;
    size_t len = file->content_length;
    int violations = 0;
    int define_count = 0;
    int undef_count = 0;

    // Process line by line
    const char* line_start = content;
    int line_num = 1;

    for (size_t i = 0; i <= len; i++)
    {
        if (i == len || content[i] == '\n')
        {
            size_t line_len = (size_t)(&content[i] - line_start);
            // Strip \r if present
            if (line_len > 0 && line_start[line_len - 1] == '\r') line_len--;

            if (line_len > 0 && !has_force_comment(line_start, line_len))
            {
                if (is_define_enable_mocks(line_start, line_len))
                {
                    define_count++;
                }
                else if (is_undef_enable_mocks(line_start, line_len))
                {
                    undef_count++;
                }
            }

            line_start = &content[i + 1];
            line_num++;
        }
    }

    violations = define_count + undef_count;

    if (violations > 0)
    {
        if (config->fix_mode)
        {
            // Rebuild file content with replacements
            // Allocate generous buffer
            size_t new_capacity = len + (size_t)violations * 128;
            char* new_content = (char*)malloc(new_capacity);
            if (!new_content) return violations;

            size_t out_pos = 0;
            line_start = content;

            for (size_t i = 0; i <= len; i++)
            {
                if (i == len || content[i] == '\n')
                {
                    size_t line_len = (size_t)(&content[i] - line_start);
                    size_t raw_line_len = line_len;
                    // Strip \r for checking
                    if (line_len > 0 && line_start[line_len - 1] == '\r') line_len--;

                    int replaced = 0;
                    if (line_len > 0 && !has_force_comment(line_start, line_len))
                    {
                        if (is_define_enable_mocks(line_start, line_len))
                        {
                            const char* replacement = "#include \"umock_c/umock_c_ENABLE_MOCKS.h\" // ============================== ENABLE_MOCKS";
                            size_t rlen = strlen(replacement);
                            memcpy(new_content + out_pos, replacement, rlen);
                            out_pos += rlen;
                            replaced = 1;
                        }
                        else if (is_undef_enable_mocks(line_start, line_len))
                        {
                            const char* replacement = "#include \"umock_c/umock_c_DISABLE_MOCKS.h\" // ============================== DISABLE_MOCKS";
                            size_t rlen = strlen(replacement);
                            memcpy(new_content + out_pos, replacement, rlen);
                            out_pos += rlen;
                            replaced = 1;
                        }
                    }

                    if (!replaced)
                    {
                        memcpy(new_content + out_pos, line_start, raw_line_len);
                        out_pos += raw_line_len;
                    }
                    else
                    {
                        // Add \r before \n to maintain CRLF line endings
                        new_content[out_pos++] = '\r';
                    }

                    // Add the newline if not at end of file
                    if (i < len)
                    {
                        new_content[out_pos++] = '\n';
                    }

                    line_start = &content[i + 1];
                }
            }

            FILE* f = fopen(file->path, "wb");
            if (f)
            {
                fwrite(new_content, 1, out_pos, f);
                fclose(f);
                printf("  [FIXED] %s - replaced %d deprecated pattern(s)\n", file->relative_path, violations);
            }
            free(new_content);
        }
        else
        {
            printf("  [ERROR] %s - %d deprecated ENABLE_MOCKS pattern(s)", file->relative_path, violations);
            if (define_count > 0) printf(" (#define: %d)", define_count);
            if (undef_count > 0) printf(" (#undef: %d)", undef_count);
            printf("\n");
            enable_mocks_violations++;
        }
    }

    return violations > 0 ? 1 : 0;
}

static int enable_mocks_finalize(const VALIDATOR_CONFIG* config)
{
    (void)config;
    return enable_mocks_violations;
}

static void enable_mocks_cleanup(void)
{
    enable_mocks_violations = 0;
}

static const CHECK_DEFINITION check_enable_mocks_def =
{
    "enable_mocks",
    "Validates files use include-based ENABLE_MOCKS pattern",
    FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP,
    0,
    enable_mocks_init,
    enable_mocks_check_file,
    enable_mocks_finalize,
    enable_mocks_cleanup
};

const CHECK_DEFINITION* get_check_enable_mocks(void)
{
    return &check_enable_mocks_def;
}
