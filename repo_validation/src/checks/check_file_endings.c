// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../repo_validator.h"

static int file_endings_violations;

static int file_endings_init(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    file_endings_violations = 0;
    result = 0;
    return result;
}

static int file_endings_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    int result;

    if (file->content_length == 0)
    {
        result = 0;
    }
    else
    {
        unsigned char last_byte = (unsigned char)file->content[file->content_length - 1];
        unsigned char second_last = (file->content_length >= 2) ? (unsigned char)file->content[file->content_length - 2] : 0;

        int is_valid = 0;
        const char* issue = NULL;

        if (last_byte == '\n' && second_last == '\r')
        {
            // Proper CRLF ending
            is_valid = 1;
        }
        else if (last_byte == '\n')
        {
            issue = "ends with LF only (expected CRLF)";
        }
        else if (last_byte == '\r')
        {
            issue = "ends with CR only (expected CRLF)";
        }
        else
        {
            issue = "missing newline at end of file";
        }

        if (!is_valid)
        {
            if (config->fix_mode)
            {
                FILE* f = fopen(file->path, "ab");
                if (!f)
                {
                    /* do nothing */
                }
                else if (last_byte == '\n')
                {
                    // LF only - need to insert CR before LF; re-read, replace last byte
                    (void)fclose(f);
                    f = fopen(file->path, "rb");
                    if (!f)
                    {
                        /* do nothing */
                    }
                    else
                    {
                        char* content = (char*)malloc(file->content_length);
                        if (!content)
                        {
                            (void)fclose(f);
                        }
                        else
                        {
                            size_t read_count = fread(content, 1, file->content_length, f);
                            (void)fclose(f);
                            f = fopen(file->path, "wb");
                            if (!f)
                            {
                                /* do nothing */
                            }
                            else
                            {
                                // Write everything except last byte, then CRLF
                                (void)fwrite(content, 1, read_count - 1, f);
                                (void)fwrite("\r\n", 1, 2, f);
                                (void)fclose(f);
                                (void)printf("  [FIXED] %s - converted LF to CRLF at end of file\n", file->relative_path);
                            }
                            free(content);
                        }
                    }
                }
                else if (last_byte == '\r')
                {
                    // CR only - append LF
                    (void)fwrite("\n", 1, 1, f);
                    (void)fclose(f);
                    (void)printf("  [FIXED] %s - appended LF after CR at end of file\n", file->relative_path);
                }
                else
                {
                    // No newline - append CRLF
                    (void)fwrite("\r\n", 1, 2, f);
                    (void)fclose(f);
                    (void)printf("  [FIXED] %s - appended CRLF at end of file\n", file->relative_path);
                }
            }
            else
            {
                (void)printf("  [ERROR] %s - %s\n", file->relative_path, issue);
                file_endings_violations++;
            }
            result = 1;
        }
        else
        {
            result = 0;
        }
    }

    return result;
}

static int file_endings_finalize(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    result = file_endings_violations;
    return result;
}

static void file_endings_cleanup(void)
{
    file_endings_violations = 0;
}

static const CHECK_DEFINITION check_file_endings_def =
{
    "file_endings",
    "Validates that source files end with a CRLF newline",
    FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP | FILE_TYPE_HPP | FILE_TYPE_CS,
    0,
    file_endings_init,
    file_endings_check_file,
    file_endings_finalize,
    file_endings_cleanup
};

const CHECK_DEFINITION* get_check_file_endings(void)
{
    return &check_file_endings_def;
}