// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../repo_validator.h"

static int test_spec_violations;
static int total_test_functions;
static int tests_with_tags;
static int exempted_tests;

static int test_spec_init(const VALIDATOR_CONFIG* config)
{
    (void)config;
    test_spec_violations = 0;
    total_test_functions = 0;
    tests_with_tags = 0;
    exempted_tests = 0;
    return 0;
}

// Line index for efficient line-by-line access without rescanning
typedef struct line_index_tag
{
    const char** starts;
    size_t* lengths;
    int count;
} LINE_INDEX;

static LINE_INDEX* build_line_index(const char* content, size_t content_len)
{
    // Count lines
    int count = 0;
    if (content_len > 0)
    {
        count = 1;
        for (size_t i = 0; i < content_len; i++)
        {
            if (content[i] == '\n') count++;
        }
    }

    LINE_INDEX* idx = (LINE_INDEX*)malloc(sizeof(LINE_INDEX));
    if (!idx) return NULL;
    idx->starts = (const char**)malloc((size_t)count * sizeof(const char*));
    idx->lengths = (size_t*)malloc((size_t)count * sizeof(size_t));
    if (!idx->starts || !idx->lengths)
    {
        free(idx->starts);
        free(idx->lengths);
        free(idx);
        return NULL;
    }
    idx->count = count;

    int li = 0;
    const char* line_start = content;
    for (size_t i = 0; i <= content_len; i++)
    {
        if (i == content_len || content[i] == '\n')
        {
            size_t len = (size_t)(&content[i] - line_start);
            if (len > 0 && line_start[len - 1] == '\r') len--;
            idx->starts[li] = line_start;
            idx->lengths[li] = len;
            li++;
            line_start = &content[i + 1];
        }
    }
    idx->count = li;
    return idx;
}

static void free_line_index(LINE_INDEX* idx)
{
    if (idx)
    {
        free(idx->starts);
        free(idx->lengths);
        free(idx);
    }
}

// Check if line starts with TEST_FUNCTION(
static int is_test_function_line(const char* line, size_t len)
{
    const char* p = line;
    const char* end = line + len;

    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (end - p < 14) return 0;
    return (strncmp(p, "TEST_FUNCTION", 13) == 0 && (p[13] == '(' || p[13] == ' ' || p[13] == '\t'));
}

// Extract test function name from TEST_FUNCTION(name) line
static void extract_test_name(const char* line, size_t len, char* name_buf, size_t buf_size)
{
    name_buf[0] = '\0';
    const char* open = (const char*)memchr(line, '(', len);
    if (!open) return;
    open++;
    const char* close = (const char*)memchr(open, ')', (size_t)((line + len) - open));
    if (!close) return;

    // Trim whitespace
    while (open < close && (*open == ' ' || *open == '\t')) open++;
    while (close > open && (close[-1] == ' ' || close[-1] == '\t')) close--;

    size_t name_len = (size_t)(close - open);
    if (name_len >= buf_size) name_len = buf_size - 1;
    memcpy(name_buf, open, name_len);
    name_buf[name_len] = '\0';
}

// Check if line contains "// no-srs" or "/* no-srs */" (case-insensitive)
static int has_no_srs_exemption(const char* line, size_t len)
{
    // Search for "no-srs" (case-insensitive) then verify it's in a comment
    for (size_t i = 0; i + 5 < len; i++)
    {
        if ((line[i] == 'n' || line[i] == 'N') &&
            (line[i+1] == 'o' || line[i+1] == 'O') &&
            line[i+2] == '-' &&
            (line[i+3] == 's' || line[i+3] == 'S') &&
            (line[i+4] == 'r' || line[i+4] == 'R') &&
            (line[i+5] == 's' || line[i+5] == 'S'))
        {
            // Scan backwards from 'n' to find "//" or "/*"
            if (i >= 2)
            {
                size_t j = i;
                while (j > 0)
                {
                    j--;
                    if (j > 0 && line[j] == '/' && line[j-1] == '/')
                    {
                        return 1; // found //
                    }
                    if (line[j] == '*' && j > 0 && line[j-1] == '/')
                    {
                        return 1; // found /*
                    }
                    // Skip whitespace and * characters
                    if (line[j] != ' ' && line[j] != '\t' && line[j] != '*' && line[j] != '/')
                    {
                        break;
                    }
                }
            }
        }
    }
    return 0;
}

// Check if line contains a Tests_ spec tag: Tests_<something>_DD_DDD
static int has_tests_spec_tag(const char* line, size_t len)
{
    for (size_t i = 0; i + 6 < len; i++)
    {
        if (line[i] == 'T' && line[i+1] == 'e' && line[i+2] == 's' &&
            line[i+3] == 't' && line[i+4] == 's' && line[i+5] == '_')
        {
            // Found "Tests_", now look for _DD_DDD pattern after module name
            const char* p = line + i + 6;
            const char* end = line + len;

            while (p < end && ((*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') || *p == '_')) p++;

            // Check backwards for _DD_DDD pattern
            if (p - (line + i + 6) >= 7)
            {
                // Minimum: X_DD_DDD = 7 chars of module+tag
                const char* tag_end = p;
                if (tag_end >= line + i + 13 && // Tests_X_DD_DDD = at least 13 chars
                    isdigit((unsigned char)tag_end[-1]) && isdigit((unsigned char)tag_end[-2]) && isdigit((unsigned char)tag_end[-3]) &&
                    tag_end[-4] == '_' &&
                    isdigit((unsigned char)tag_end[-5]) && isdigit((unsigned char)tag_end[-6]) &&
                    tag_end[-7] == '_')
                {
                    return 1;
                }
            }
        }
    }
    return 0;
}

// Check if line is blank
static int is_blank_line(const char* line, size_t len)
{
    for (size_t i = 0; i < len; i++)
    {
        if (line[i] != ' ' && line[i] != '\t') return 0;
    }
    return 1;
}

// Check if line looks like it's part of a comment (starts with /*, */, *, //)
static int is_comment_line(const char* line, size_t len)
{
    const char* p = line;
    const char* end = line + len;

    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end) return 1; // blank = continue searching

    if (p + 1 < end && p[0] == '/' && p[1] == '*') return 1;
    if (p[0] == '*') return 1;
    if (p + 1 < end && p[0] == '/' && p[1] == '/') return 1;

    // Check if line ends with */
    const char* q = line + len;
    while (q > p && (q[-1] == ' ' || q[-1] == '\t')) q--;
    if (q - p >= 2 && q[-2] == '*' && q[-1] == '/') return 1;

    return 0;
}

static int test_spec_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    (void)config;

    // Only process _ut.c files
    if (!(file->type_flags & FILE_TYPE_C)) return 0;

    // Check filename ends with _ut.c
    const char* fname = strrchr(file->path, PATH_SEP);
#ifdef _WIN32
    if (!fname) fname = strrchr(file->path, '/');
#endif
    if (fname) fname++;
    else fname = file->path;

    size_t fname_len = strlen(fname);
    if (fname_len < 5 || strcmp(fname + fname_len - 5, "_ut.c") != 0) return 0;

    LINE_INDEX* lines = build_line_index(file->content, file->content_length);
    if (!lines) return 0;

    int file_violations = 0;

    for (int i = 0; i < lines->count; i++)
    {
        const char* line = lines->starts[i];
        size_t line_len = lines->lengths[i];

        if (!is_test_function_line(line, line_len)) continue;

        total_test_functions++;

        // Check for no-srs exemption
        if (has_no_srs_exemption(line, line_len))
        {
            exempted_tests++;
            tests_with_tags++;
            continue;
        }

        // Search backwards for Tests_ spec tag
        int found_tag = 0;
        int search_idx = i - 1;
        int in_multiline_comment = 0;

        while (search_idx >= 0)
        {
            const char* prev = lines->starts[search_idx];
            size_t prev_len = lines->lengths[search_idx];

            // Check for spec tag
            if (has_tests_spec_tag(prev, prev_len))
            {
                found_tag = 1;
            }

            // Blank line - continue searching
            if (is_blank_line(prev, prev_len))
            {
                search_idx--;
                continue;
            }

            // Track multi-line comment state (searching backwards)
            int has_start = 0;
            int has_end = 0;
            for (size_t k = 0; k + 1 < prev_len; k++)
            {
                if (prev[k] == '/' && prev[k+1] == '*') has_start = 1;
                if (prev[k] == '*' && prev[k+1] == '/') has_end = 1;
            }

            if (has_start && has_end)
            {
                // Single-line block comment
            }
            else if (has_start)
            {
                in_multiline_comment = 0;
            }
            else if (has_end)
            {
                in_multiline_comment = 1;
            }

            if (in_multiline_comment)
            {
                search_idx--;
                continue;
            }

            // If it's a comment line, continue
            if (is_comment_line(prev, prev_len))
            {
                search_idx--;
                continue;
            }

            // Hit non-comment code, stop searching
            break;
        }

        if (found_tag)
        {
            tests_with_tags++;
        }
        else
        {
            char test_name[256];
            extract_test_name(line, line_len, test_name, sizeof(test_name));
            printf("  [ERROR] %s:%d TEST_FUNCTION(%s) - missing spec tag\n",
                   file->relative_path, i + 1, test_name);
            file_violations++;
            test_spec_violations++;
        }
    }

    free_line_index(lines);
    return file_violations;
}

static int test_spec_finalize(const VALIDATOR_CONFIG* config)
{
    (void)config;

    printf("\n  Unit test files: TEST_FUNCTION declarations: %d, with tags: %d, exempted: %d, missing: %d\n",
           total_test_functions, tests_with_tags, exempted_tests, test_spec_violations);

    return test_spec_violations;
}

static void test_spec_cleanup(void)
{
    test_spec_violations = 0;
    total_test_functions = 0;
    tests_with_tags = 0;
    exempted_tests = 0;
}

static const CHECK_DEFINITION check_test_spec_tags_def =
{
    "test_spec_tags",
    "Validates TEST_FUNCTION declarations have preceding spec tags",
    FILE_TYPE_C,
    0,
    test_spec_init,
    test_spec_check_file,
    test_spec_finalize,
    test_spec_cleanup
};

const CHECK_DEFINITION* get_check_test_spec_tags(void)
{
    return &check_test_spec_tags_def;
}
