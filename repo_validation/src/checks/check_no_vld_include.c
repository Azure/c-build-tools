// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../repo_validator.h"

static int no_vld_violations;

static int no_vld_init(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    no_vld_violations = 0;
    result = 0;
    return result;
}

// Check if line matches #include "vld.h" or #include <vld.h>
static int is_vld_include(const char* line, size_t len)
{
    int result;
    const char* p = line;
    const char* end = line + len;

    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end || *p != '#')
    {
        result = 0;
    }
    else
    {
        p++;
        while (p < end && (*p == ' ' || *p == '\t')) p++;
        if (end - p < 7 || strncmp(p, "include", 7) != 0)
        {
            result = 0;
        }
        else
        {
            p += 7;
            while (p < end && (*p == ' ' || *p == '\t')) p++;
            if (p >= end)
            {
                result = 0;
            }
            else if (*p == '"')
            {
                p++;
                if (end - p >= 5 && strncmp(p, "vld.h", 5) == 0)
                {
                    p += 5;
                    if (p < end && *p == '"')
                    {
                        result = 1;
                    }
                    else
                    {
                        result = 0;
                    }
                }
                else
                {
                    result = 0;
                }
            }
            else if (*p == '<')
            {
                p++;
                if (end - p >= 5 && strncmp(p, "vld.h", 5) == 0)
                {
                    p += 5;
                    if (p < end && *p == '>')
                    {
                        result = 1;
                    }
                    else
                    {
                        result = 0;
                    }
                }
                else
                {
                    result = 0;
                }
            }
            else
            {
                result = 0;
            }
        }
    }

    return result;
}

// Check if line ends with "// force" (case-insensitive)
static int line_has_force_comment(const char* line, size_t len)
{
    int result;

    if (len < 8)
    {
        result = 0;
    }
    else
    {
        size_t end = len;
        while (end > 0 && (line[end - 1] == ' ' || line[end - 1] == '\t')) end--;
        if (end < 8)
        {
            result = 0;
        }
        else
        {
            if ((line[end-5] == 'f' || line[end-5] == 'F') &&
                (line[end-4] == 'o' || line[end-4] == 'O') &&
                (line[end-3] == 'r' || line[end-3] == 'R') &&
                (line[end-2] == 'c' || line[end-2] == 'C') &&
                (line[end-1] == 'e' || line[end-1] == 'E'))
            {
                size_t j = end - 5;
                while (j > 0 && (line[j-1] == ' ' || line[j-1] == '\t')) j--;
                if (j >= 2 && line[j-1] == '/' && line[j-2] == '/')
                {
                    result = 1;
                }
                else
                {
                    result = 0;
                }
            }
            else
            {
                result = 0;
            }
        }
    }

    return result;
}

// Check if line matches "#ifdef USE_VLD"
static int is_ifdef_use_vld(const char* line, size_t len)
{
    int result;
    const char* p = line;
    const char* end = line + len;

    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end || *p != '#')
    {
        result = 0;
    }
    else
    {
        p++;
        while (p < end && (*p == ' ' || *p == '\t')) p++;
        if (end - p < 5 || strncmp(p, "ifdef", 5) != 0)
        {
            result = 0;
        }
        else
        {
            p += 5;
            if (p >= end || (*p != ' ' && *p != '\t'))
            {
                result = 0;
            }
            else
            {
                while (p < end && (*p == ' ' || *p == '\t')) p++;
                if (end - p < 7 || strncmp(p, "USE_VLD", 7) != 0)
                {
                    result = 0;
                }
                else
                {
                    p += 7;
                    while (p < end && (*p == ' ' || *p == '\t')) p++;
                    if (p >= end)
                    {
                        result = 1;
                    }
                    else
                    {
                        result = 0;
                    }
                }
            }
        }
    }

    return result;
}

// Check if line matches "#endif" (with optional comment)
static int is_endif(const char* line, size_t len)
{
    int result;
    const char* p = line;
    const char* end = line + len;

    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end || *p != '#')
    {
        result = 0;
    }
    else
    {
        p++;
        while (p < end && (*p == ' ' || *p == '\t')) p++;
        if (end - p < 5 || strncmp(p, "endif", 5) != 0)
        {
            result = 0;
        }
        else
        {
            // Allow optional whitespace/comments after endif
            result = 1;
        }
    }

    return result;
}

// Check if line is blank or a comment-only line
static int is_blank_or_comment(const char* line, size_t len)
{
    int result;
    const char* p = line;
    const char* end = line + len;

    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end)
    {
        result = 1; // blank
    }
    else if (p + 1 < end && p[0] == '/' && p[1] == '/')
    {
        result = 1; // line comment
    }
    else
    {
        result = 0;
    }

    return result;
}

// Represents a line in the file for fix mode processing
typedef struct line_info_tag
{
    const char* start;
    size_t length;     // length without \r\n
    size_t raw_length; // length including \r\n
} LINE_INFO;

static int no_vld_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    int result;
    const char* content = file->content;
    size_t len = file->content_length;
    int violation_count = 0;

    // Parse into lines and count violations
    const char* line_start = content;
    int line_num = 1;

    for (size_t i = 0; i <= len; i++)
    {
        if (i == len || content[i] == '\n')
        {
            size_t line_len = (size_t)(&content[i] - line_start);
            if (line_len > 0 && line_start[line_len - 1] == '\r')
            {
                line_len--;
            }
            else
            {
                /* do nothing */
            }

            if (is_vld_include(line_start, line_len) && !line_has_force_comment(line_start, line_len))
            {
                violation_count++;
            }
            else
            {
                /* do nothing */
            }

            line_start = &content[i + 1];
            line_num++;
        }
        else
        {
            /* do nothing */
        }
    }

    if (violation_count > 0)
    {
        if (config->fix_mode)
        {
            // Build line array for processing
            int line_count = 0;
            for (size_t i = 0; i <= len; i++)
            {
                if (i == len || content[i] == '\n')
                {
                    line_count++;
                }
                else
                {
                    /* do nothing */
                }
            }

            LINE_INFO* lines = (LINE_INFO*)malloc((size_t)line_count * sizeof(LINE_INFO));
            if (!lines)
            {
                result = violation_count;
            }
            else
            {
                int li = 0;
                line_start = content;
                for (size_t i = 0; i <= len; i++)
                {
                    if (i == len || content[i] == '\n')
                    {
                        lines[li].start = line_start;
                        lines[li].raw_length = (size_t)(&content[i] - line_start) + (i < len ? 1 : 0);
                        lines[li].length = (size_t)(&content[i] - line_start);
                        if (lines[li].length > 0 && line_start[lines[li].length - 1] == '\r')
                        {
                            lines[li].length--;
                        }
                        else
                        {
                            /* do nothing */
                        }
                        li++;
                        line_start = &content[i + 1];
                    }
                    else
                    {
                        /* do nothing */
                    }
                }

                // Build output, skipping vld includes and #ifdef USE_VLD blocks
                char* new_content = (char*)malloc(len + 1);
                if (!new_content)
                {
                    free(lines);
                    result = violation_count;
                }
                else
                {
                    size_t out_pos = 0;
                    int removed = 0;

                    for (int idx = 0; idx < line_count; idx++)
                    {
                        int was_removed = 0;

                        // Check if this is an #ifdef USE_VLD block
                        if (is_ifdef_use_vld(lines[idx].start, lines[idx].length))
                        {
                            // Scan forward to check block contents
                            int j = idx + 1;
                            int found_vld = 0;
                            int found_endif = 0;
                            int only_vld = 1;
                            int scan_done = 0;

                            while (j < line_count && !scan_done)
                            {
                                if (is_vld_include(lines[j].start, lines[j].length))
                                {
                                    found_vld = 1;
                                    j++;
                                }
                                else if (is_endif(lines[j].start, lines[j].length))
                                {
                                    found_endif = 1;
                                    scan_done = 1;
                                }
                                else if (is_blank_or_comment(lines[j].start, lines[j].length))
                                {
                                    j++;
                                }
                                else
                                {
                                    only_vld = 0;
                                    scan_done = 1;
                                }
                            }

                            if (found_vld && found_endif && only_vld)
                            {
                                removed++;
                                idx = j; // skip past #endif
                                was_removed = 1;
                            }
                            else
                            {
                                /* do nothing */
                            }
                        }
                        else
                        {
                            /* do nothing */
                        }

                        if (!was_removed)
                        {
                            // Check if this is a standalone vld.h include
                            if (is_vld_include(lines[idx].start, lines[idx].length) &&
                                !line_has_force_comment(lines[idx].start, lines[idx].length))
                            {
                                removed++;
                            }
                            else
                            {
                                // Keep this line
                                (void)memcpy(new_content + out_pos, lines[idx].start, lines[idx].raw_length);
                                out_pos += lines[idx].raw_length;
                            }
                        }
                        else
                        {
                            /* do nothing */
                        }
                    }

                    // Ensure file ends with CRLF
                    if (out_pos >= 2 && (new_content[out_pos - 2] != '\r' || new_content[out_pos - 1] != '\n'))
                    {
                        if (out_pos >= 1 && new_content[out_pos - 1] == '\n')
                        {
                            // Has LF, insert CR before it
                            new_content[out_pos - 1] = '\r';
                            new_content[out_pos] = '\n';
                            out_pos++;
                        }
                        else
                        {
                            new_content[out_pos++] = '\r';
                            new_content[out_pos++] = '\n';
                        }
                    }
                    else
                    {
                        /* do nothing */
                    }

                    FILE* f = fopen(file->path, "wb");
                    if (!f)
                    {
                        /* do nothing */
                    }
                    else
                    {
                        (void)fwrite(new_content, 1, out_pos, f);
                        (void)fclose(f);
                        (void)printf("  [FIXED] %s - removed %d vld.h include(s)\n", file->relative_path, removed);
                    }

                    free(new_content);
                    free(lines);
                    result = 1;
                }
            }
        }
        else
        {
            (void)printf("  [ERROR] %s - contains %d vld.h include(s)\n", file->relative_path, violation_count);
            no_vld_violations++;
            result = 1;
        }
    }
    else
    {
        result = 0;
    }

    return result;
}

static int no_vld_finalize(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    result = no_vld_violations;
    return result;
}

static void no_vld_cleanup(void)
{
    no_vld_violations = 0;
}

static const CHECK_DEFINITION check_no_vld_include_def =
{
    "no_vld_include",
    "Validates files do not explicitly include vld.h",
    FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP | FILE_TYPE_HPP | FILE_TYPE_TXT,
    0,
    no_vld_init,
    no_vld_check_file,
    no_vld_finalize,
    no_vld_cleanup
};

const CHECK_DEFINITION* get_check_no_vld_include(void)
{
    return &check_no_vld_include_def;
}