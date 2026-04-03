// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../repo_validator.h"

static int srs_format_violations;

static int srs_format_init(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    srs_format_violations = 0;
    result = 0;
    return result;
}

// Search for needle in a bounded region [start, start+len)
static const char* find_in_range(const char* start, size_t len, const char* needle, size_t needle_len)
{
    const char* result = NULL;

    if (needle_len > len)
    {
        /* do nothing */
    }
    else
    {
        for (size_t i = 0; i <= len - needle_len; i++)
        {
            if (memcmp(start + i, needle, needle_len) == 0)
            {
                result = start + i;
                break;
            }
            else
            {
                /* do nothing */
            }
        }
    }

    return result;
}

// Check if a tag has valid SRS suffix pattern _DD_DDD
static int has_valid_srs_suffix(const char* tag, size_t tag_len)
{
    int result;

    if (tag_len < 11)
    {
        result = 0;
    }
    else
    {
        const char* suffix = tag + tag_len - 7;
        if (suffix[0] == '_' &&
            isdigit((unsigned char)suffix[1]) && isdigit((unsigned char)suffix[2]) &&
            suffix[3] == '_' &&
            isdigit((unsigned char)suffix[4]) && isdigit((unsigned char)suffix[5]) && isdigit((unsigned char)suffix[6]))
        {
            result = 1;
        }
        else
        {
            result = 0;
        }
    }

    return result;
}

// Process a single line, checking for malformed SRS tags
static void check_line(const char* line_start, size_t line_len, int line_num, const char* relative_path)
{
    const char* p = line_start;
    size_t remaining = line_len;

    // Skip leading whitespace
    while (remaining > 0 && (*p == ' ' || *p == '\t'))
    {
        p++;
        remaining--;
    }

    // Skip optional list markers: "* " or "- "
    if (remaining >= 2 && (p[0] == '*' || p[0] == '-') && p[1] == ' ')
    {
        p += 2;
        remaining -= 2;

        // Skip additional whitespace after marker
        while (remaining > 0 && (*p == ' ' || *p == '\t'))
        {
            p++;
            remaining--;
        }
    }
    else
    {
        /* do nothing */
    }

    // Check for "**SRS_" prefix
    if (remaining < 6 || memcmp(p, "**SRS_", 6) != 0)
    {
        /* do nothing */
    }
    else
    {
        // Extract tag name starting after "**"
        const char* tag_start = p + 2;
        size_t max_tag_len = remaining - 2;
        size_t tag_len = 0;

        while (tag_len < max_tag_len &&
               ((tag_start[tag_len] >= 'A' && tag_start[tag_len] <= 'Z') ||
                (tag_start[tag_len] >= '0' && tag_start[tag_len] <= '9') ||
                tag_start[tag_len] == '_'))
        {
            tag_len++;
        }

        // Validate tag has SRS_ prefix and _DD_DDD suffix
        if (tag_len < 4 || memcmp(tag_start, "SRS_", 4) != 0 || !has_valid_srs_suffix(tag_start, tag_len))
        {
            /* do nothing */
        }
        else
        {
            int has_bold_open = (find_in_range(line_start, line_len, "[**", 3) != NULL) ? 1 : 0;
            int has_bold_close = (find_in_range(line_start, line_len, "**]**", 5) != NULL) ? 1 : 0;

            if (!has_bold_open)
            {
                (void)printf("  [ERROR] %s:%d %.*s - missing bold opening bracket [**\n",
                    relative_path, line_num, (int)tag_len, tag_start);
                srs_format_violations++;
            }
            else
            {
                /* do nothing */
            }

            if (!has_bold_close)
            {
                if (find_in_range(line_start, line_len, "]*/", 3) != NULL)
                {
                    (void)printf("  [ERROR] %s:%d %.*s - C-comment-style closing ]*/ (should be **]**)\n",
                        relative_path, line_num, (int)tag_len, tag_start);
                }
                else if (find_in_range(line_start, line_len, "**]", 3) != NULL)
                {
                    (void)printf("  [ERROR] %s:%d %.*s - missing trailing ** after **]\n",
                        relative_path, line_num, (int)tag_len, tag_start);
                }
                else
                {
                    (void)printf("  [ERROR] %s:%d %.*s - missing closing **]**\n",
                        relative_path, line_num, (int)tag_len, tag_start);
                }
                srs_format_violations++;
            }
            else
            {
                /* do nothing */
            }
        }
    }
}

static int srs_format_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;

    if (file->content == NULL || file->content_length == 0)
    {
        result = 0;
    }
    else
    {
        const char* p = file->content;
        const char* end = p + file->content_length;
        int line_num = 1;
        const char* line_start = p;

        while (p <= end)
        {
            if (p == end || *p == '\n')
            {
                size_t line_len = (size_t)(p - line_start);

                // Remove trailing \r
                if (line_len > 0 && line_start[line_len - 1] == '\r')
                {
                    line_len--;
                }
                else
                {
                    /* do nothing */
                }

                check_line(line_start, line_len, line_num, file->relative_path);

                line_num++;
                line_start = p + 1;
            }
            else
            {
                /* do nothing */
            }
            p++;
        }

        result = 0;
    }

    return result;
}

static int srs_format_finalize(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    result = srs_format_violations;
    return result;
}

static void srs_format_cleanup(void)
{
    srs_format_violations = 0;
}

static const CHECK_DEFINITION check_srs_format_def =
{
    "srs_format",
    "Validates SRS requirement tag formatting in markdown files",
    FILE_TYPE_MD,
    1,
    srs_format_init,
    srs_format_check_file,
    srs_format_finalize,
    srs_format_cleanup
};

const CHECK_DEFINITION* get_check_srs_format(void)
{
    return &check_srs_format_def;
}
