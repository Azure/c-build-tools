// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../repo_validator.h"

#define AAA_HASH_SIZE 4096
#define MAX_FUNC_NAME 256
#define MAX_HELPERS 1024

static int aaa_violations;
static int aaa_total_test_functions;
static int aaa_exempted_tests;

static int aaa_init(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    aaa_violations = 0;
    aaa_total_test_functions = 0;
    aaa_exempted_tests = 0;
    result = 0;
    return result;
}

// Test macro definitions
static const char* const TEST_MACROS[] =
{
    "TEST_FUNCTION",
    "TEST_METHOD",
    "CTEST_FUNCTION",
    "PARAMETERIZED_TEST_FUNCTION",
};
static const int NUM_TEST_MACROS = 4;

// Keywords/macros excluded from helper function detection
static const char* const EXCLUDED_NAMES[] =
{
    "TEST_FUNCTION",
    "TEST_METHOD",
    "CTEST_FUNCTION",
    "PARAMETERIZED_TEST_FUNCTION",
    "if",
    "while",
    "for",
    "switch",
    "else",
    "do",
    "TEST_DEFINE_ENUM_TYPE",
    "TEST_SUITE_INITIALIZE",
    "TEST_SUITE_CLEANUP",
    "TEST_FUNCTION_INITIALIZE",
    "TEST_FUNCTION_CLEANUP",
};
static const int NUM_EXCLUDED_NAMES = 15;

// C return type keywords for helper function detection
static const char* const RETURN_TYPES[] =
{
    "void", "int", "bool", "char", "unsigned", "signed", "long",
    "short", "float", "double", "size_t",
};
static const int NUM_RETURN_TYPES = 11;

static int is_ident_char(char c)
{
    int result;
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')
    {
        result = 1;
    }
    else
    {
        result = 0;
    }
    return result;
}

typedef struct test_func_match_tag
{
    char macro_name[64];
    char test_name[MAX_FUNC_NAME];
    size_t match_pos;
    size_t match_end;
} TEST_FUNC_MATCH;

typedef struct helper_func_tag
{
    char name[MAX_FUNC_NAME];
    size_t brace_pos;
} HELPER_FUNC;

// Find all test macro invocations in content
static int find_test_functions(const char* content, size_t len, TEST_FUNC_MATCH* matches, int max_matches)
{
    int count = 0;
    size_t pos = 0;

    while (pos < len && count < max_matches)
    {
        size_t match_start = pos;

        // Skip leading whitespace
        while (pos < len && (content[pos] == ' ' || content[pos] == '\t'))
        {
            pos++;
        }

        if (pos >= len)
        {
            break;
        }
        else
        {
            /* do nothing */
        }

        int matched = 0;
        for (int m = 0; m < NUM_TEST_MACROS && !matched; m++)
        {
            size_t mlen = strlen(TEST_MACROS[m]);
            if (pos + mlen <= len && strncmp(&content[pos], TEST_MACROS[m], mlen) == 0)
            {
                size_t p = pos + mlen;
                // Skip optional whitespace then expect '('
                while (p < len && (content[p] == ' ' || content[p] == '\t'))
                {
                    p++;
                }
                if (p < len && content[p] == '(')
                {
                    p++;
                    // Skip whitespace
                    while (p < len && (content[p] == ' ' || content[p] == '\t'))
                    {
                        p++;
                    }
                    // Extract identifier
                    size_t name_start = p;
                    while (p < len && is_ident_char(content[p]))
                    {
                        p++;
                    }
                    if (p > name_start)
                    {
                        size_t name_len = p - name_start;
                        if (name_len >= MAX_FUNC_NAME)
                        {
                            name_len = MAX_FUNC_NAME - 1;
                        }
                        else
                        {
                            /* do nothing */
                        }
                        (void)memcpy(matches[count].test_name, &content[name_start], name_len);
                        matches[count].test_name[name_len] = '\0';

                        // Skip to closing paren
                        while (p < len && content[p] != ')')
                        {
                            p++;
                        }
                        if (p < len)
                        {
                            p++;
                        }
                        else
                        {
                            /* do nothing */
                        }

                        (void)strncpy(matches[count].macro_name, TEST_MACROS[m], sizeof(matches[count].macro_name) - 1);
                        matches[count].macro_name[sizeof(matches[count].macro_name) - 1] = '\0';
                        matches[count].match_pos = match_start;
                        matches[count].match_end = p;
                        count++;
                        matched = 1;

                        // Skip to end of line
                        while (p < len && content[p] != '\n')
                        {
                            p++;
                        }
                        if (p < len)
                        {
                            p++;
                        }
                        else
                        {
                            /* do nothing */
                        }
                        pos = p;
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

        if (!matched)
        {
            // Skip to next line
            while (pos < len && content[pos] != '\n')
            {
                pos++;
            }
            if (pos < len)
            {
                pos++;
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

    return count;
}

// Extract function body starting from start_index
// Finds the opening '{' then counts braces, skipping string/char literals
// Returns body length (0 if not found), sets body_start
static size_t extract_function_body(const char* content, size_t content_len, size_t start_index, size_t* body_start)
{
    size_t result_len = 0;

    // Find opening brace
    size_t brace_start = start_index;
    while (brace_start < content_len && content[brace_start] != '{')
    {
        brace_start++;
    }

    if (brace_start >= content_len)
    {
        /* result_len stays 0 */
    }
    else
    {
        int brace_count = 1;
        size_t pos = brace_start + 1;

        while (brace_count > 0 && pos < content_len)
        {
            char ch = content[pos];

            // Skip string literals
            if (ch == '"')
            {
                pos++;
                while (pos < content_len)
                {
                    if (content[pos] == '\\' && pos + 1 < content_len)
                    {
                        pos += 2;
                    }
                    else if (content[pos] == '"')
                    {
                        pos++;
                        break;
                    }
                    else
                    {
                        pos++;
                    }
                }
            }
            // Skip character literals
            else if (ch == '\'')
            {
                pos++;
                while (pos < content_len)
                {
                    if (content[pos] == '\\' && pos + 1 < content_len)
                    {
                        pos += 2;
                    }
                    else if (content[pos] == '\'')
                    {
                        pos++;
                        break;
                    }
                    else
                    {
                        pos++;
                    }
                }
            }
            else
            {
                if (ch == '{')
                {
                    brace_count++;
                }
                else if (ch == '}')
                {
                    brace_count--;
                }
                else
                {
                    /* do nothing */
                }
                pos++;
            }
        }

        if (brace_count == 0)
        {
            *body_start = brace_start;
            result_len = pos - brace_start;
        }
        else
        {
            /* result_len stays 0 */
        }
    }

    return result_len;
}

static int eq_ignore_case_n(const char* a, const char* b, size_t n)
{
    int result;
    result = 1;
    for (size_t i = 0; i < n && result == 1; i++)
    {
        if (tolower((unsigned char)a[i]) != tolower((unsigned char)b[i]))
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

// Find AAA marker positions in body. positions[0]=arrange, [1]=act, [2]=assert
// Value >= 0 means found, -1 means not found
static void find_aaa_positions(const char* body, size_t body_len, long long positions[3])
{
    static const char* keywords[] = { "arrange", "act", "assert" };
    static const size_t keyword_lens[] = { 7, 3, 6 };

    positions[0] = -1;
    positions[1] = -1;
    positions[2] = -1;

    for (int ki = 0; ki < 3; ki++)
    {
        size_t klen = keyword_lens[ki];
        size_t p = 0;

        while (p + klen <= body_len)
        {
            // Look for "//" or "/*"
            if (p + 1 < body_len && body[p] == '/' && (body[p + 1] == '/' || body[p + 1] == '*'))
            {
                int is_block = (body[p + 1] == '*');
                size_t comment_start = p;
                size_t q = p + 2;

                // For line comments, skip additional '/' chars
                if (!is_block)
                {
                    while (q < body_len && body[q] == '/')
                    {
                        q++;
                    }
                }
                else
                {
                    /* do nothing */
                }

                // Skip whitespace
                while (q < body_len && (body[q] == ' ' || body[q] == '\t'))
                {
                    q++;
                }

                // Check keyword (case-insensitive)
                if (q + klen <= body_len && eq_ignore_case_n(&body[q], keywords[ki], klen))
                {
                    // Word boundary check
                    size_t after = q + klen;
                    if (after >= body_len || !is_ident_char(body[after]))
                    {
                        if (positions[ki] < 0)
                        {
                            positions[ki] = (long long)comment_start;
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

                // Skip rest of comment
                if (is_block)
                {
                    while (q < body_len)
                    {
                        if (q + 1 < body_len && body[q] == '*' && body[q + 1] == '/')
                        {
                            q += 2;
                            break;
                        }
                        else
                        {
                            q++;
                        }
                    }
                    p = q;
                }
                else
                {
                    while (q < body_len && body[q] != '\n')
                    {
                        q++;
                    }
                    p = q;
                }
            }
            else
            {
                p++;
            }
        }
    }
}

// Get line containing match_end, for checking no-aaa exemption
static void get_line_at(const char* content, size_t content_len, size_t match_end, const char** line_out, size_t* line_len_out)
{
    size_t line_start;
    if (match_end > 0)
    {
        line_start = match_end - 1;
    }
    else
    {
        line_start = 0;
    }

    while (line_start > 0 && content[line_start] != '\n')
    {
        line_start--;
    }
    if (content[line_start] == '\n')
    {
        line_start++;
    }
    else
    {
        /* do nothing */
    }
    while (line_start < content_len && content[line_start] == '\r')
    {
        line_start++;
    }

    size_t line_end = match_end;
    while (line_end < content_len && content[line_end] != '\n')
    {
        line_end++;
    }

    *line_out = &content[line_start];
    *line_len_out = line_end - line_start;
}

// Check if a line contains "no-aaa" in a comment
static int has_no_aaa_exemption(const char* line, size_t len)
{
    int result;
    result = 0;

    if (len < 6)
    {
        /* result stays 0 */
    }
    else
    {
        for (size_t i = 0; i + 5 < len && result == 0; i++)
        {
            if (eq_ignore_case_n(&line[i], "no-aaa", 6))
            {
                // Verify it's in a comment: scan backwards for // or /*
                if (i >= 2)
                {
                    size_t j = i;
                    int found_comment = 0;
                    while (j > 0 && !found_comment)
                    {
                        j--;
                        if (j > 0 && line[j] == '/' && line[j - 1] == '/')
                        {
                            found_comment = 1;
                        }
                        else if (line[j] == '*' && j > 0 && line[j - 1] == '/')
                        {
                            found_comment = 1;
                        }
                        else if (line[j] != ' ' && line[j] != '\t' && line[j] != '*' && line[j] != '/')
                        {
                            break;
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
    }

    return result;
}

static int is_return_type_prefix(const char* word, size_t word_len)
{
    int result;
    result = 0;

    for (int i = 0; i < NUM_RETURN_TYPES && result == 0; i++)
    {
        if (word_len == strlen(RETURN_TYPES[i]) && strncmp(word, RETURN_TYPES[i], word_len) == 0)
        {
            result = 1;
        }
        else
        {
            /* do nothing */
        }
    }

    // uint*_t, int*_t patterns
    if (result == 0 && word_len >= 5 && word[word_len - 2] == '_' && word[word_len - 1] == 't')
    {
        if (word_len >= 7 && strncmp(word, "uint", 4) == 0)
        {
            int all_digits = 1;
            for (size_t k = 4; k < word_len - 2; k++)
            {
                if (!isdigit((unsigned char)word[k]))
                {
                    all_digits = 0;
                }
                else
                {
                    /* do nothing */
                }
            }
            if (all_digits && word_len - 2 > 4)
            {
                result = 1;
            }
            else
            {
                /* do nothing */
            }
        }
        else if (word_len >= 6 && strncmp(word, "int", 3) == 0)
        {
            int all_digits = 1;
            for (size_t k = 3; k < word_len - 2; k++)
            {
                if (!isdigit((unsigned char)word[k]))
                {
                    all_digits = 0;
                }
                else
                {
                    /* do nothing */
                }
            }
            if (all_digits && word_len - 2 > 3)
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

    // THANDLE(...)
    if (result == 0 && word_len >= 7 && strncmp(word, "THANDLE", 7) == 0)
    {
        result = 1;
    }
    else
    {
        /* do nothing */
    }

    return result;
}

static int is_excluded_name(const char* name, size_t name_len)
{
    int result;
    result = 0;
    for (int i = 0; i < NUM_EXCLUDED_NAMES && result == 0; i++)
    {
        if (name_len == strlen(EXCLUDED_NAMES[i]) && strncmp(name, EXCLUDED_NAMES[i], name_len) == 0)
        {
            result = 1;
        }
        else
        {
            /* do nothing */
        }
    }
    return result;
}

// Find helper function definitions in the file content
static int find_helper_functions(const char* content, size_t content_len, HELPER_FUNC* helpers, int max_helpers)
{
    int count = 0;
    size_t pos = 0;
    while (pos < content_len && count < max_helpers)
    {
        // Skip whitespace
        size_t p = pos;
        while (p < content_len && (content[p] == ' ' || content[p] == '\t'))
        {
            p++;
        }

        if (p >= content_len)
        {
            break;
        }
        else
        {
            /* do nothing */
        }

        // Check for "static " prefix
        size_t scan = p;
        if (scan + 7 <= content_len && strncmp(&content[scan], "static", 6) == 0 &&
            (content[scan + 6] == ' ' || content[scan + 6] == '\t'))
        {
            scan += 6;
            while (scan < content_len && (content[scan] == ' ' || content[scan] == '\t'))
            {
                scan++;
            }
        }
        else
        {
            /* do nothing */
        }

        // Handle THANDLE(...) specially
        if (scan + 7 <= content_len && strncmp(&content[scan], "THANDLE", 7) == 0)
        {
            while (scan < content_len && content[scan] != '(')
            {
                scan++;
            }
            if (scan < content_len)
            {
                int paren_depth = 1;
                scan++;
                while (scan < content_len && paren_depth > 0)
                {
                    if (content[scan] == '(')
                    {
                        paren_depth++;
                    }
                    else if (content[scan] == ')')
                    {
                        paren_depth--;
                    }
                    else
                    {
                        /* do nothing */
                    }
                    scan++;
                }
            }
            else
            {
                /* do nothing */
            }
        }
        else
        {
            // Read type word
            size_t word_start = scan;
            while (scan < content_len && is_ident_char(content[scan]))
            {
                scan++;
            }
            if (scan == word_start || !is_return_type_prefix(&content[word_start], scan - word_start))
            {
                // Not a recognized return type, skip line
                while (pos < content_len && content[pos] != '\n')
                {
                    pos++;
                }
                if (pos < content_len)
                {
                    pos++;
                }
                else
                {
                    /* do nothing */
                }
                continue;
            }
            else
            {
                /* do nothing */
            }
        }
        while (scan < content_len && (content[scan] == ' ' || content[scan] == '\t'))
        {
            scan++;
        }
        if (scan < content_len && content[scan] == '*')
        {
            scan++;
        }
        else
        {
            /* do nothing */
        }
        while (scan < content_len && (content[scan] == ' ' || content[scan] == '\t'))
        {
            scan++;
        }

        // Read function name
        size_t name_start = scan;
        while (scan < content_len && is_ident_char(content[scan]))
        {
            scan++;
        }
        if (scan > name_start)
        {
            size_t name_len = scan - name_start;

            if (!is_excluded_name(&content[name_start], name_len))
            {
                // Skip whitespace, expect '('
                while (scan < content_len && (content[scan] == ' ' || content[scan] == '\t'))
                {
                    scan++;
                }

                if (scan < content_len && content[scan] == '(')
                {
                    int paren_count = 1;
                    scan++;
                    while (scan < content_len && paren_count > 0)
                    {
                        if (content[scan] == '(')
                        {
                            paren_count++;
                        }
                        else if (content[scan] == ')')
                        {
                            paren_count--;
                        }
                        else
                        {
                            /* do nothing */
                        }
                        scan++;
                    }

                    if (paren_count == 0)
                    {
                        // Skip whitespace/newlines, look for '{'
                        while (scan < content_len && (content[scan] == ' ' || content[scan] == '\t' || content[scan] == '\r' || content[scan] == '\n'))
                        {
                            scan++;
                        }

                        if (scan < content_len && content[scan] == '{')
                        {
                            if (name_len >= MAX_FUNC_NAME)
                            {
                                name_len = MAX_FUNC_NAME - 1;
                            }
                            else
                            {
                                /* do nothing */
                            }
                            (void)memcpy(helpers[count].name, &content[name_start], name_len);
                            helpers[count].name[name_len] = '\0';
                            helpers[count].brace_pos = scan;
                            count++;
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
            else
            {
                /* do nothing */
            }
        }
        else
        {
            /* do nothing */
        }

        // Skip to next line from original position
        while (pos < content_len && content[pos] != '\n')
        {
            pos++;
        }
        if (pos < content_len)
        {
            pos++;
        }
        else
        {
            /* do nothing */
        }
    }

    return count;
}

// Find all function calls in a body
static int find_called_functions(const char* body, size_t body_len, char calls[][MAX_FUNC_NAME], int max_calls)
{
    int count = 0;
    size_t p = 0;

    while (p < body_len && count < max_calls)
    {
        if (is_ident_char(body[p]) && (p == 0 || !is_ident_char(body[p - 1])))
        {
            size_t name_start = p;
            while (p < body_len && is_ident_char(body[p]))
            {
                p++;
            }
            size_t name_len = p - name_start;

            // Skip whitespace
            while (p < body_len && (body[p] == ' ' || body[p] == '\t'))
            {
                p++;
            }
            if (p < body_len && body[p] == '(')
            {
                if (name_len >= MAX_FUNC_NAME)
                {
                    name_len = MAX_FUNC_NAME - 1;
                }
                else
                {
                    /* do nothing */
                }
                (void)memcpy(calls[count], &body[name_start], name_len);
                calls[count][name_len] = '\0';
                count++;
            }
            else
            {
                /* do nothing */
            }
        }
        else
        {
            p++;
        }
    }

    return count;
}

static int aaa_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
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
            const char* content = file->content;
            size_t content_len = file->content_length;

            if (content_len == 0)
            {
                result = 0;
            }
            else
            {
                // Find test functions
                TEST_FUNC_MATCH* test_funcs = (TEST_FUNC_MATCH*)malloc(4096 * sizeof(TEST_FUNC_MATCH));
                if (!test_funcs)
                {
                    result = 0;
                }
                else
                {
                    int num_tests = find_test_functions(content, content_len, test_funcs, 4096);
                    if (num_tests == 0)
                    {
                        result = 0;
                    }
                    else
                    {
                        int file_violations = 0;

                        // Lazy-init helper functions
                        HELPER_FUNC* helpers = NULL;
                        int num_helpers = 0;
                        int helpers_initialized = 0;

                        // Cache for helper AAA positions
                        typedef struct helper_cache_tag
                        {
                            char name[MAX_FUNC_NAME];
                            long long positions[3];
                        } HELPER_CACHE;
                        HELPER_CACHE* helper_cache = NULL;
                        int cache_count = 0;

                        for (int ti = 0; ti < num_tests; ti++)
                        {
                            aaa_total_test_functions++;

                            // Check for no-aaa exemption
                            const char* test_line;
                            size_t test_line_len;
                            get_line_at(content, content_len, test_funcs[ti].match_end, &test_line, &test_line_len);

                            if (has_no_aaa_exemption(test_line, test_line_len))
                            {
                                aaa_exempted_tests++;
                            }
                            else
                            {
                                // Extract function body
                                size_t body_start = 0;
                                size_t body_len = extract_function_body(content, content_len, test_funcs[ti].match_pos, &body_start);
                                if (body_len == 0)
                                {
                                    /* do nothing - skip if no body */
                                }
                                else
                                {
                                    const char* body = &content[body_start];

                                    // Check AAA in body
                                    long long positions[3];
                                    find_aaa_positions(body, body_len, positions);
                                    int all_found = (positions[0] >= 0 && positions[1] >= 0 && positions[2] >= 0);
                                    if (all_found)
                                    {
                                        // Check order
                                        if (positions[0] < positions[1] && positions[1] < positions[2])
                                        {
                                            /* valid - do nothing */
                                        }
                                        else
                                        {
                                            // Wrong order
                                            int line_num = compute_line_number(content, test_funcs[ti].match_pos);
                                            (void)printf("  [ERROR] %s:%d %s(%s) - AAA comments are not in correct order (should be: arrange, act, assert)\n",
                                                file->relative_path, line_num, test_funcs[ti].macro_name, test_funcs[ti].test_name);
                                            file_violations++;
                                            aaa_violations++;
                                        }
                                    }
                                    else
                                    {
                                        // Not all found - check helper functions
                                        if (!helpers_initialized)
                                        {
                                            helpers = (HELPER_FUNC*)malloc(MAX_HELPERS * sizeof(HELPER_FUNC));
                                            helper_cache = (HELPER_CACHE*)malloc(MAX_HELPERS * sizeof(HELPER_CACHE));
                                            if (helpers && helper_cache)
                                            {
                                                num_helpers = find_helper_functions(content, content_len, helpers, MAX_HELPERS);
                                            }
                                            else
                                            {
                                                /* do nothing */
                                            }
                                            helpers_initialized = 1;
                                        }
                                        else
                                        {
                                            /* do nothing */
                                        }

                                        if (helpers && helper_cache)
                                        {
                                            char(*called)[MAX_FUNC_NAME] = (char(*)[MAX_FUNC_NAME])malloc(1024 * MAX_FUNC_NAME);
                                            if (called)
                                            {
                                                int num_called = find_called_functions(body, body_len, called, 1024);
                                                for (int ci = 0; ci < num_called; ci++)
                                                {
                                                    if (positions[0] >= 0 && positions[1] >= 0 && positions[2] >= 0)
                                                    {
                                                        break;
                                                    }
                                                    else
                                                    {
                                                        /* do nothing */
                                                    }

                                                    // Find helper by name
                                                    int hi;
                                                    for (hi = 0; hi < num_helpers; hi++)
                                                    {
                                                        if (strcmp(called[ci], helpers[hi].name) == 0)
                                                        {
                                                            break;
                                                        }
                                                        else
                                                        {
                                                            /* do nothing */
                                                        }
                                                    }

                                                    if (hi < num_helpers)
                                                    {
                                                        // Check cache
                                                        int cached_idx = -1;
                                                        for (int cc = 0; cc < cache_count; cc++)
                                                        {
                                                            if (strcmp(helper_cache[cc].name, called[ci]) == 0)
                                                            {
                                                                cached_idx = cc;
                                                                break;
                                                            }
                                                            else
                                                            {
                                                                /* do nothing */
                                                            }
                                                        }

                                                        long long h_positions[3];
                                                        if (cached_idx >= 0)
                                                        {
                                                            h_positions[0] = helper_cache[cached_idx].positions[0];
                                                            h_positions[1] = helper_cache[cached_idx].positions[1];
                                                            h_positions[2] = helper_cache[cached_idx].positions[2];
                                                        }
                                                        else
                                                        {
                                                            size_t h_body_start = 0;
                                                            size_t h_body_len = extract_function_body(content, content_len, helpers[hi].brace_pos, &h_body_start);
                                                            if (h_body_len > 0)
                                                            {
                                                                find_aaa_positions(&content[h_body_start], h_body_len, h_positions);
                                                            }
                                                            else
                                                            {
                                                                h_positions[0] = -1;
                                                                h_positions[1] = -1;
                                                                h_positions[2] = -1;
                                                            }

                                                            if (cache_count < MAX_HELPERS)
                                                            {
                                                                (void)strncpy(helper_cache[cache_count].name, called[ci], MAX_FUNC_NAME - 1);
                                                                helper_cache[cache_count].name[MAX_FUNC_NAME - 1] = '\0';
                                                                helper_cache[cache_count].positions[0] = h_positions[0];
                                                                helper_cache[cache_count].positions[1] = h_positions[1];
                                                                helper_cache[cache_count].positions[2] = h_positions[2];
                                                                cache_count++;
                                                            }
                                                            else
                                                            {
                                                                /* do nothing */
                                                            }
                                                        }

                                                        if (h_positions[0] >= 0)
                                                        {
                                                            positions[0] = 0;
                                                        }
                                                        else
                                                        {
                                                            /* do nothing */
                                                        }
                                                        if (h_positions[1] >= 0)
                                                        {
                                                            positions[1] = 0;
                                                        }
                                                        else
                                                        {
                                                            /* do nothing */
                                                        }
                                                        if (h_positions[2] >= 0)
                                                        {
                                                            positions[2] = 0;
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
                                                free(called);
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

                                        // Report missing
                                        if (positions[0] < 0 || positions[1] < 0 || positions[2] < 0)
                                        {
                                            char missing_buf[64];
                                            missing_buf[0] = '\0';
                                            int first = 1;
                                            if (positions[0] < 0)
                                            {
                                                (void)strcat(missing_buf, "arrange");
                                                first = 0;
                                            }
                                            else
                                            {
                                                /* do nothing */
                                            }
                                            if (positions[1] < 0)
                                            {
                                                if (!first)
                                                {
                                                    (void)strcat(missing_buf, ", ");
                                                }
                                                else
                                                {
                                                    /* do nothing */
                                                }
                                                (void)strcat(missing_buf, "act");
                                                first = 0;
                                            }
                                            else
                                            {
                                                /* do nothing */
                                            }
                                            if (positions[2] < 0)
                                            {
                                                if (!first)
                                                {
                                                    (void)strcat(missing_buf, ", ");
                                                }
                                                else
                                                {
                                                    /* do nothing */
                                                }
                                                (void)strcat(missing_buf, "assert");
                                            }
                                            else
                                            {
                                                /* do nothing */
                                            }

                                            int line_num = compute_line_number(content, test_funcs[ti].match_pos);
                                            (void)printf("  [ERROR] %s:%d %s(%s) - missing AAA: %s\n",
                                                file->relative_path, line_num, test_funcs[ti].macro_name, test_funcs[ti].test_name, missing_buf);
                                            file_violations++;
                                            aaa_violations++;
                                        }
                                        else
                                        {
                                            /* do nothing */
                                        }
                                    }
                                }
                            }
                        }

                        free(helpers);
                        free(helper_cache);
                        result = file_violations;
                    }

                    free(test_funcs);
                }
            }
        }
    }

    return result;
}

static int aaa_finalize(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;

    (void)printf("\n  Test functions: %d, exempted: %d, violations: %d\n",
        aaa_total_test_functions, aaa_exempted_tests, aaa_violations);

    result = aaa_violations;
    return result;
}

static void aaa_cleanup(void)
{
    aaa_violations = 0;
    aaa_total_test_functions = 0;
    aaa_exempted_tests = 0;
}

static const CHECK_DEFINITION check_aaa_comments_def =
{
    "aaa_comments",
    "Validates test functions contain AAA (Arrange, Act, Assert) comments",
    FILE_TYPE_C,
    0,
    aaa_init,
    aaa_check_file,
    aaa_finalize,
    aaa_cleanup
};

const CHECK_DEFINITION* get_check_aaa_comments(void)
{
    return &check_aaa_comments_def;
}
