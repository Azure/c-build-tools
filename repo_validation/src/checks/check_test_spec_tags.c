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
    int result;
    (void)config;
    test_spec_violations = 0;
    total_test_functions = 0;
    tests_with_tags = 0;
    exempted_tests = 0;
    result = 0;
    return result;
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
    LINE_INDEX* result = NULL;
    int count = 0;

    if (content_len > 0)
    {
        count = 1;
        for (size_t i = 0; i < content_len; i++)
        {
            if (content[i] == '\n')
            {
                count++;
            }
            else
            {
                /* do nothing */
            }
        }
    }
    else
    {
        /* do nothing */
    }

    LINE_INDEX* idx = (LINE_INDEX*)malloc(sizeof(LINE_INDEX));
    if (!idx)
    {
        /* do nothing - result stays NULL */
    }
    else
    {
        idx->starts = (const char**)malloc((size_t)count * sizeof(const char*));
        idx->lengths = (size_t*)malloc((size_t)count * sizeof(size_t));
        if (!idx->starts || !idx->lengths)
        {
            free(idx->starts);
            free(idx->lengths);
            free(idx);
            /* result stays NULL */
        }
        else
        {
            idx->count = count;

            int li = 0;
            const char* line_start = content;
            for (size_t i = 0; i <= content_len; i++)
            {
                if (i == content_len || content[i] == '\n')
                {
                    size_t len = (size_t)(&content[i] - line_start);
                    if (len > 0 && line_start[len - 1] == '\r')
                    {
                        len--;
                    }
                    else
                    {
                        /* do nothing */
                    }
                    idx->starts[li] = line_start;
                    idx->lengths[li] = len;
                    li++;
                    line_start = &content[i + 1];
                }
                else
                {
                    /* do nothing */
                }
            }
            idx->count = li;
            result = idx;
        }
    }

    return result;
}

static void free_line_index(LINE_INDEX* idx)
{
    if (!idx)
    {
        /* do nothing */
    }
    else
    {
        free(idx->starts);
        free(idx->lengths);
        free(idx);
    }
}

// Check if line starts with TEST_FUNCTION( or PARAMETERIZED_TEST_FUNCTION(
// Returns: 0 = not a test function, 1 = TEST_FUNCTION, 2 = PARAMETERIZED_TEST_FUNCTION
static int is_test_function_line(const char* line, size_t len)
{
    int result;
    const char* p = line;
    const char* end = line + len;

    while (p < end && (*p == ' ' || *p == '\t')) p++;

    if ((size_t)(end - p) >= 31 &&
        strncmp(p, "PARAMETERIZED_TEST_FUNCTION", 27) == 0 &&
        (p[27] == '(' || p[27] == ' ' || p[27] == '\t'))
    {
        result = 2;
    }
    else if ((size_t)(end - p) >= 14 &&
        strncmp(p, "TEST_FUNCTION", 13) == 0 &&
        (p[13] == '(' || p[13] == ' ' || p[13] == '\t'))
    {
        result = 1;
    }
    else
    {
        result = 0;
    }

    return result;
}

// Extract test function name from TEST_FUNCTION(name) or PARAMETERIZED_TEST_FUNCTION(name, ...) line
// For PARAMETERIZED_TEST_FUNCTION, extract up to the first comma (not closing paren)
static void extract_test_name(const char* line, size_t len, char* name_buf, size_t buf_size, int macro_type)
{
    name_buf[0] = '\0';
    const char* open = (const char*)memchr(line, '(', len);
    if (!open)
    {
        /* do nothing */
    }
    else
    {
        open++;
        const char* end_delim;
        if (macro_type == 2)
        {
            // PARAMETERIZED_TEST_FUNCTION: name ends at first comma
            end_delim = (const char*)memchr(open, ',', (size_t)((line + len) - open));
            if (!end_delim)
            {
                end_delim = (const char*)memchr(open, ')', (size_t)((line + len) - open));
            }
            else
            {
                /* do nothing */
            }
        }
        else
        {
            end_delim = (const char*)memchr(open, ')', (size_t)((line + len) - open));
        }

        if (!end_delim)
        {
            /* do nothing */
        }
        else
        {
            // Trim whitespace
            while (open < end_delim && (*open == ' ' || *open == '\t')) open++;
            while (end_delim > open && (end_delim[-1] == ' ' || end_delim[-1] == '\t')) end_delim--;

            size_t name_len = (size_t)(end_delim - open);
            if (name_len >= buf_size)
            {
                name_len = buf_size - 1;
            }
            else
            {
                /* do nothing */
            }
            (void)memcpy(name_buf, open, name_len);
            name_buf[name_len] = '\0';
        }
    }
}

// Check if line contains "// no-srs" or "/* no-srs */" (case-insensitive)
static int has_no_srs_exemption(const char* line, size_t len)
{
    int result;
    result = 0;

    // Search for "no-srs" (case-insensitive) then verify it's in a comment
    for (size_t i = 0; i + 5 < len && result == 0; i++)
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
                int found_comment = 0;
                int keep_scanning = 1;

                while (j > 0 && !found_comment && keep_scanning)
                {
                    j--;
                    if (j > 0 && line[j] == '/' && line[j-1] == '/')
                    {
                        found_comment = 1; // found //
                    }
                    else if (line[j] == '*' && j > 0 && line[j-1] == '/')
                    {
                        found_comment = 1; // found /*
                    }
                    else if (line[j] != ' ' && line[j] != '\t' && line[j] != '*' && line[j] != '/')
                    {
                        keep_scanning = 0;
                    }
                    else
                    {
                        /* do nothing */
                    }
                }

                if (found_comment)
                {
                    result = 1;
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
        }
        else
        {
            /* do nothing */
        }
    }

    return result;
}

// Check if line contains a Tests_ spec tag: Tests_<something>_DD_DDD
static int has_tests_spec_tag(const char* line, size_t len)
{
    int result;
    result = 0;

    for (size_t i = 0; i + 6 < len && result == 0; i++)
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
                    result = 1;
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
        }
        else
        {
            /* do nothing */
        }
    }

    return result;
}

// Check if line is blank
static int is_blank_line(const char* line, size_t len)
{
    int result;
    result = 1;

    for (size_t i = 0; i < len && result == 1; i++)
    {
        if (line[i] != ' ' && line[i] != '\t')
        {
            result = 0;
        }
        else
        {
            /* do nothing */
        }
    }

    return result;
}

// Check if line looks like it's part of a comment (starts with /*, */, *, //)
static int is_comment_line(const char* line, size_t len)
{
    int result;
    const char* p = line;
    const char* end = line + len;

    while (p < end && (*p == ' ' || *p == '\t')) p++;
    if (p >= end)
    {
        result = 1; // blank = continue searching
    }
    else if (p + 1 < end && p[0] == '/' && p[1] == '*')
    {
        result = 1;
    }
    else if (p[0] == '*')
    {
        result = 1;
    }
    else if (p + 1 < end && p[0] == '/' && p[1] == '/')
    {
        result = 1;
    }
    else
    {
        // Check if line ends with */
        const char* q = line + len;
        while (q > p && (q[-1] == ' ' || q[-1] == '\t')) q--;
        if (q - p >= 2 && q[-2] == '*' && q[-1] == '/')
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

static int test_spec_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;

    if (!(file->type_flags & FILE_TYPE_C))
    {
        result = 0;
    }
    else
    {
        // Check filename ends with _ut.c
        const char* fname = strrchr(file->path, PATH_SEP);
#ifdef _WIN32
        if (!fname)
        {
            fname = strrchr(file->path, '/');
        }
        else
        {
            /* do nothing */
        }
#endif
        if (fname)
        {
            fname++;
        }
        else
        {
            fname = file->path;
        }

        size_t fname_len = strlen(fname);
        if (fname_len < 5 || strcmp(fname + fname_len - 5, "_ut.c") != 0)
        {
            result = 0;
        }
        else
        {
            LINE_INDEX* lines = build_line_index(file->content, file->content_length);
            if (!lines)
            {
                result = 0;
            }
            else
            {
                int file_violations = 0;

                for (int i = 0; i < lines->count; i++)
                {
                    const char* line = lines->starts[i];
                    size_t line_len = lines->lengths[i];

                    int macro_type = is_test_function_line(line, line_len);
                    if (macro_type != 0)
                    {
                        total_test_functions++;

                        // Check for no-srs exemption
                        if (has_no_srs_exemption(line, line_len))
                        {
                            exempted_tests++;
                            tests_with_tags++;
                        }
                        else
                        {
                            // Search backwards for Tests_ spec tag
                            int found_tag = 0;
                            int search_idx = i - 1;
                            int in_multiline_comment = 0;
                            int keep_searching = 1;

                            while (search_idx >= 0 && keep_searching)
                            {
                                const char* prev = lines->starts[search_idx];
                                size_t prev_len = lines->lengths[search_idx];

                                // Check for spec tag
                                if (has_tests_spec_tag(prev, prev_len))
                                {
                                    found_tag = 1;
                                }
                                else
                                {
                                    /* do nothing */
                                }

                                if (is_blank_line(prev, prev_len))
                                {
                                    search_idx--;
                                }
                                else
                                {
                                    // Track multi-line comment state (searching backwards)
                                    int has_start = 0;
                                    int has_end = 0;
                                    for (size_t k = 0; k + 1 < prev_len; k++)
                                    {
                                        if (prev[k] == '/' && prev[k+1] == '*')
                                        {
                                            has_start = 1;
                                        }
                                        else
                                        {
                                            /* do nothing */
                                        }
                                        if (prev[k] == '*' && prev[k+1] == '/')
                                        {
                                            has_end = 1;
                                        }
                                        else
                                        {
                                            /* do nothing */
                                        }
                                    }

                                    if (has_start && has_end)
                                    {
                                        // Single-line block comment - do nothing special
                                    }
                                    else if (has_start)
                                    {
                                        in_multiline_comment = 0;
                                    }
                                    else if (has_end)
                                    {
                                        in_multiline_comment = 1;
                                    }
                                    else
                                    {
                                        /* do nothing */
                                    }

                                    if (in_multiline_comment)
                                    {
                                        search_idx--;
                                    }
                                    else if (is_comment_line(prev, prev_len))
                                    {
                                        search_idx--;
                                    }
                                    else
                                    {
                                        // Hit non-comment code, stop searching
                                        keep_searching = 0;
                                    }
                                }
                            }

                            if (found_tag)
                            {
                                tests_with_tags++;
                            }
                            else
                            {
                                char test_name[256];
                                const char* macro_name = (macro_type == 2) ? "PARAMETERIZED_TEST_FUNCTION" : "TEST_FUNCTION";
                                extract_test_name(line, line_len, test_name, sizeof(test_name), macro_type);
                                (void)printf("  [ERROR] %s:%d %s(%s) - missing spec tag\n",
                                       file->relative_path, i + 1, macro_name, test_name);
                                file_violations++;
                                test_spec_violations++;
                            }
                        }
                    }
                    else
                    {
                        /* do nothing */
                    }
                }

                free_line_index(lines);
                result = file_violations;
            }
        }
    }

    return result;
}

static int test_spec_finalize(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;

    (void)printf("\n  Unit test files: TEST_FUNCTION declarations: %d, with tags: %d, exempted: %d, missing: %d\n",
           total_test_functions, tests_with_tags, exempted_tests, test_spec_violations);

    result = test_spec_violations;
    return result;
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