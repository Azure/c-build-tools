// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../repo_validator.h"

static int backticks_violations;

static int backticks_init(const VALIDATOR_CONFIG* config)
{
    (void)config;
    backticks_violations = 0;
    return 0;
}

// Find SRS tags with backticks in the bracketed text
// Pattern: SRS_<MODULE>_DD_DDD : [ text with ` backticks ` ]
// Returns count of matches found
static int find_srs_backticks(const char* content, size_t len)
{
    int count = 0;
    const char* p = content;
    const char* end = content + len;

    while (p < end - 4)
    {
        // Find "SRS_"
        const char* srs = (const char*)memchr(p, 'S', (size_t)(end - p));
        if (!srs || srs >= end - 4) break;

        if (srs[1] == 'R' && srs[2] == 'S' && srs[3] == '_')
        {
            // Found SRS_, now scan for colon
            const char* q = srs + 4;
            while (q < end && ((*q >= 'A' && *q <= 'Z') || (*q >= '0' && *q <= '9') || *q == '_')) q++;

            // Skip optional whitespace
            while (q < end && (*q == ' ' || *q == '\t')) q++;

            // Check for colon
            if (q < end && *q == ':')
            {
                q++;
                // Skip whitespace
                while (q < end && (*q == ' ' || *q == '\t')) q++;

                // Check for opening bracket
                if (q < end && *q == '[')
                {
                    q++;
                    // Scan to closing bracket, looking for backticks
                    int has_backtick = 0;
                    while (q < end && *q != ']')
                    {
                        if (*q == '`') has_backtick = 1;
                        q++;
                    }

                    if (has_backtick && q < end && *q == ']')
                    {
                        count++;
                    }
                }
            }
            p = q < end ? q : end;
        }
        else
        {
            p = srs + 1;
        }
    }

    return count;
}

// Fix: remove backticks from SRS bracketed text
static char* fix_srs_backticks(const char* content, size_t len, size_t* out_len)
{
    // Allocate same size (removing backticks can only shrink)
    char* result = (char*)malloc(len + 1);
    if (!result) return NULL;

    size_t out_pos = 0;
    const char* p = content;
    const char* end = content + len;

    while (p < end)
    {
        // Find "SRS_"
        if (end - p >= 4 && p[0] == 'S' && p[1] == 'R' && p[2] == 'S' && p[3] == '_')
        {
            // Copy "SRS_"
            const char* srs_start = p;
            result[out_pos++] = *p++; // S
            result[out_pos++] = *p++; // R
            result[out_pos++] = *p++; // S
            result[out_pos++] = *p++; // _

            // Copy module/tag chars
            while (p < end && ((*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') || *p == '_'))
            {
                result[out_pos++] = *p++;
            }

            // Copy whitespace
            while (p < end && (*p == ' ' || *p == '\t'))
            {
                result[out_pos++] = *p++;
            }

            // Check for colon
            if (p < end && *p == ':')
            {
                result[out_pos++] = *p++;

                // Copy whitespace
                while (p < end && (*p == ' ' || *p == '\t'))
                {
                    result[out_pos++] = *p++;
                }

                // Check for bracket
                if (p < end && *p == '[')
                {
                    result[out_pos++] = *p++;

                    // Inside bracket: copy everything except backticks until ]
                    while (p < end && *p != ']')
                    {
                        if (*p != '`')
                        {
                            result[out_pos++] = *p;
                        }
                        p++;
                    }

                    // Copy closing bracket if present
                    if (p < end && *p == ']')
                    {
                        result[out_pos++] = *p++;
                    }
                    continue;
                }
            }
            (void)srs_start;
            continue;
        }

        result[out_pos++] = *p++;
    }

    result[out_pos] = '\0';
    *out_len = out_pos;
    return result;
}

static int backticks_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    int match_count = find_srs_backticks(file->content, file->content_length);

    if (match_count > 0)
    {
        if (config->fix_mode)
        {
            size_t new_len;
            char* fixed = fix_srs_backticks(file->content, file->content_length, &new_len);
            if (fixed)
            {
                FILE* f = fopen(file->path, "wb");
                if (f)
                {
                    fwrite(fixed, 1, new_len, f);
                    fclose(f);
                    printf("  [FIXED] %s - removed backticks from %d SRS requirement(s)\n",
                           file->relative_path, match_count);
                }
                free(fixed);
            }
        }
        else
        {
            printf("  [ERROR] %s - %d SRS requirement(s) contain backticks\n",
                   file->relative_path, match_count);
            backticks_violations++;
        }
        return 1;
    }

    return 0;
}

static int backticks_finalize(const VALIDATOR_CONFIG* config)
{
    (void)config;
    return backticks_violations;
}

static void backticks_cleanup(void)
{
    backticks_violations = 0;
}

static const CHECK_DEFINITION check_no_backticks_def =
{
    "no_backticks_in_srs",
    "Validates SRS comments do not contain markdown backticks",
    FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP | FILE_TYPE_HPP,
    0,
    backticks_init,
    backticks_check_file,
    backticks_finalize,
    backticks_cleanup
};

const CHECK_DEFINITION* get_check_no_backticks_in_srs(void)
{
    return &check_no_backticks_def;
}
