// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../repo_validator.h"

static int requirements_naming_violations;

static int requirements_naming_init(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    requirements_naming_violations = 0;
    result = 0;
    return result;
}

// Check if content contains an SRS tag pattern: SRS_XXXXXX_DD_DDD
static int content_has_srs_tag(const char* content, size_t length)
{
    int result;
    result = 0;

    for (size_t i = 0; i + 15 < length && result == 0; i++)
    {
        if (content[i] == 'S' && content[i + 1] == 'R' && content[i + 2] == 'S' && content[i + 3] == '_')
        {
            const char* p = content + i + 4;
            const char* end = content + length;
            int found_upper = 0;

            while (p < end - 6)
            {
                if (*p >= 'A' && *p <= 'Z')
                {
                    found_upper = 1;
                }
                else
                {
                    /* do nothing */
                }
                if (found_upper && *p == '_' && isdigit((unsigned char)p[1]) && isdigit((unsigned char)p[2]) &&
                    p[3] == '_' && isdigit((unsigned char)p[4]) && isdigit((unsigned char)p[5]) && isdigit((unsigned char)p[6]))
                {
                    result = 1;
                    break;
                }
                else
                {
                    if (!(*p >= 'A' && *p <= 'Z') && !(*p >= '0' && *p <= '9') && *p != '_')
                    {
                        break;
                    }
                    else
                    {
                        p++;
                    }
                }
            }
        }
        else
        {
            /* do nothing */
        }
    }

    return result;
}

static int requirements_naming_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    int result;

    if (!(file->type_flags & FILE_TYPE_MD))
    {
        result = 0;
    }
    else if (!(file->type_flags & FILE_FLAG_IN_DEVDOC))
    {
        result = 0;
    }
    else if (!content_has_srs_tag(file->content, file->content_length))
    {
        result = 0;
    }
    else
    {
        // Check if filename ends with _requirements.md
        const char* filename = strrchr(file->path, PATH_SEP);
#ifdef _WIN32
        if (!filename)
        {
            filename = strrchr(file->path, '/');
        }
        else
        {
            /* do nothing */
        }
#endif
        if (filename)
        {
            filename++;
        }
        else
        {
            filename = file->path;
        }

        size_t name_len = strlen(filename);
        const char* suffix = "_requirements.md";
        size_t suffix_len = strlen(suffix);

        if (name_len >= suffix_len && strcmp(filename + name_len - suffix_len, suffix) == 0)
        {
            result = 0; // Already has correct naming
        }
        else
        {
            if (config->fix_mode)
            {
                // Rename: strip .md, append _requirements.md
                char new_path[MAX_PATH_LENGTH];
                size_t path_len = strlen(file->path);
                if (path_len < 3 || path_len >= MAX_PATH_LENGTH - 20)
                {
                    result = 1;
                }
                else
                {
                    (void)strncpy(new_path, file->path, path_len - 3);
                    new_path[path_len - 3] = '\0';
                    (void)strcat(new_path, "_requirements.md");

                    if (rename(file->path, new_path) == 0)
                    {
                        (void)printf("  [FIXED] %s -> %s\n", file->relative_path, strrchr(new_path, PATH_SEP) + 1);
                    }
                    else
                    {
                        (void)printf("  [ERROR] Failed to rename %s\n", file->relative_path);
                        requirements_naming_violations++;
                    }
                    result = 1;
                }
            }
            else
            {
                (void)printf("  [ERROR] %s - requirement file should be named with '_requirements.md' suffix\n", file->relative_path);
                requirements_naming_violations++;
                result = 1;
            }
        }
    }

    return result;
}

static int requirements_naming_finalize(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    result = requirements_naming_violations;
    return result;
}

static void requirements_naming_cleanup(void)
{
    requirements_naming_violations = 0;
}

static const CHECK_DEFINITION check_requirements_naming_def =
{
    "requirements_naming",
    "Validates that requirement documents follow naming conventions",
    FILE_TYPE_MD,
    1, // requires devdoc
    requirements_naming_init,
    requirements_naming_check_file,
    requirements_naming_finalize,
    requirements_naming_cleanup
};

const CHECK_DEFINITION* get_check_requirements_naming(void)
{
    return &check_requirements_naming_def;
}