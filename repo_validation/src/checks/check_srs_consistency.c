// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../repo_validator.h"

#define SRSC_HASH_SIZE 65537
#define MAX_SRS_TEXT 4096
#define MAX_ORIGINAL_MATCH 8192
#define MAX_C_TAGS 16384

// Markdown requirement entry
typedef struct md_req_entry_tag
{
    char tag[MAX_TAG_LENGTH];
    char clean_text[MAX_SRS_TEXT];
    char file_path[MAX_PATH_LENGTH];
    struct md_req_entry_tag* next;
} MD_REQ_ENTRY;

// Collected C tag
typedef struct collected_c_tag_tag
{
    char tag[MAX_TAG_LENGTH];
    char prefix[8]; // "Codes" or "Tests"
    char text[MAX_SRS_TEXT];
    char* original_match;
    size_t match_index;
    int has_duplication;
    int is_incomplete;
    char c_file_path[MAX_PATH_LENGTH];
    char c_file_relative[MAX_PATH_LENGTH];
} COLLECTED_C_TAG;

// Placement violation
typedef struct placement_violation_tag
{
    char file_path[MAX_PATH_LENGTH];
    char full_tag[MAX_TAG_LENGTH];
    char violation[256];
    struct placement_violation_tag* next;
} PLACEMENT_VIOLATION;

// Inconsistency record
typedef struct inconsistency_record_tag
{
    char tag[MAX_TAG_LENGTH];
    char c_file[MAX_PATH_LENGTH];
    char c_text[MAX_SRS_TEXT];
    char md_text[MAX_SRS_TEXT];
    char* original_match;
    size_t match_index;
    struct inconsistency_record_tag* next;
} INCONSISTENCY_RECORD;

static MD_REQ_ENTRY* md_hash_table[SRSC_HASH_SIZE];
static COLLECTED_C_TAG* c_tags_array;
static int c_tags_count;
static int c_tags_capacity;
static PLACEMENT_VIOLATION* placement_violations;
static int total_md_requirements;
static int c_files_scanned;

static unsigned int hash_tag(const char* s)
{
    unsigned int h = 5381;
    while (*s)
    {
        h = ((h << 5) + h) + (unsigned char)*s++;
    }
    return h % SRSC_HASH_SIZE;
}

static MD_REQ_ENTRY* find_md_req(const char* tag)
{
    unsigned int idx = hash_tag(tag);
    MD_REQ_ENTRY* e = md_hash_table[idx];
    while (e != NULL && strcmp(e->tag, tag) != 0)
    {
        e = e->next;
    }
    return e;
}

static void insert_md_req(const char* tag, const char* clean_text, const char* file_path)
{
    unsigned int idx = hash_tag(tag);
    MD_REQ_ENTRY* e = (MD_REQ_ENTRY*)malloc(sizeof(MD_REQ_ENTRY));
    if (!e)
    {
        /* do nothing */
    }
    else
    {
        (void)strncpy(e->tag, tag, MAX_TAG_LENGTH - 1);
        e->tag[MAX_TAG_LENGTH - 1] = '\0';
        (void)strncpy(e->clean_text, clean_text, MAX_SRS_TEXT - 1);
        e->clean_text[MAX_SRS_TEXT - 1] = '\0';
        (void)strncpy(e->file_path, file_path, MAX_PATH_LENGTH - 1);
        e->file_path[MAX_PATH_LENGTH - 1] = '\0';
        e->next = md_hash_table[idx];
        md_hash_table[idx] = e;
    }
}

static void add_c_tag(const COLLECTED_C_TAG* ctag)
{
    if (c_tags_count >= c_tags_capacity)
    {
        int new_capacity = (c_tags_capacity == 0) ? 256 : c_tags_capacity * 2;
        COLLECTED_C_TAG* new_arr = (COLLECTED_C_TAG*)realloc(c_tags_array, (size_t)new_capacity * sizeof(COLLECTED_C_TAG));
        if (!new_arr)
        {
            return;
        }
        else
        {
            c_tags_array = new_arr;
            c_tags_capacity = new_capacity;
        }
    }
    else
    {
        /* do nothing */
    }
    c_tags_array[c_tags_count] = *ctag;
    c_tags_count++;
}

static void add_placement_violation(const char* file_path, const char* full_tag, const char* violation)
{
    PLACEMENT_VIOLATION* v = (PLACEMENT_VIOLATION*)malloc(sizeof(PLACEMENT_VIOLATION));
    if (!v)
    {
        /* do nothing */
    }
    else
    {
        (void)strncpy(v->file_path, file_path, MAX_PATH_LENGTH - 1);
        v->file_path[MAX_PATH_LENGTH - 1] = '\0';
        (void)strncpy(v->full_tag, full_tag, MAX_TAG_LENGTH - 1);
        v->full_tag[MAX_TAG_LENGTH - 1] = '\0';
        (void)strncpy(v->violation, violation, sizeof(v->violation) - 1);
        v->violation[sizeof(v->violation) - 1] = '\0';
        v->next = placement_violations;
        placement_violations = v;
    }
}

static int is_srs_tag_char(char c)
{
    int result;
    result = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
    return result;
}

static int validate_srs_tag_format(const char* tag, size_t tag_len)
{
    int result;
    // SRS_ + at least 1 char module + _DD_DDD = 11+
    if (tag_len < 11)
    {
        result = 0;
    }
    else if (!isdigit((unsigned char)tag[tag_len - 1]) ||
             !isdigit((unsigned char)tag[tag_len - 2]) ||
             !isdigit((unsigned char)tag[tag_len - 3]) ||
             tag[tag_len - 4] != '_' ||
             !isdigit((unsigned char)tag[tag_len - 5]) ||
             !isdigit((unsigned char)tag[tag_len - 6]) ||
             tag[tag_len - 7] != '_')
    {
        result = 0;
    }
    else
    {
        result = 1;
    }
    return result;
}

// Strip markdown formatting from text
static void strip_markdown_formatting(const char* text, char* out, size_t out_size)
{
    // Work with a mutable copy
    size_t text_len = strlen(text);
    char* buf = (char*)malloc(text_len + 1);
    if (!buf)
    {
        (void)strncpy(out, text, out_size - 1);
        out[out_size - 1] = '\0';
        return;
    }
    else
    {
        /* do nothing */
    }
    (void)memcpy(buf, text, text_len + 1);

    // Remove bold markers (**text**) - loop to handle nested
    {
        int changed = 1;
        while (changed)
        {
            changed = 0;
            char* start_ptr = strstr(buf, "**");
            if (start_ptr)
            {
                char* end_ptr = strstr(start_ptr + 2, "**");
                if (end_ptr)
                {
                    // Remove the two ** at start and the two ** at end
                    size_t inner_len = (size_t)(end_ptr - (start_ptr + 2));
                    size_t after_start = (size_t)(end_ptr + 2 - buf);
                    size_t after_len = strlen(buf + after_start);

                    (void)memmove(start_ptr, start_ptr + 2, inner_len);
                    (void)memmove(start_ptr + inner_len, buf + after_start, after_len + 1);
                    changed = 1;
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

    // Remove italics *word* - only match word boundaries (not C pointers)
    {
        size_t buf_len = strlen(buf);
        char* result_buf = (char*)malloc(buf_len + 1);
        if (result_buf)
        {
            size_t ri = 0;
            size_t i = 0;
            while (i < buf_len)
            {
                if (buf[i] == '*' && i + 1 < buf_len && isalnum((unsigned char)buf[i + 1]))
                {
                    // Look for closing * after word chars
                    size_t word_start = i + 1;
                    size_t j = word_start;
                    while (j < buf_len && (isalnum((unsigned char)buf[j]) || buf[j] == '_'))
                    {
                        j++;
                    }
                    if (j < buf_len && buf[j] == '*' && j > word_start)
                    {
                        // *word* pattern - copy without asterisks
                        (void)memcpy(&result_buf[ri], &buf[word_start], j - word_start);
                        ri += j - word_start;
                        i = j + 1;
                    }
                    else
                    {
                        result_buf[ri++] = buf[i++];
                    }
                }
                else
                {
                    result_buf[ri++] = buf[i++];
                }
            }
            result_buf[ri] = '\0';
            (void)strcpy(buf, result_buf);
            free(result_buf);
        }
        else
        {
            /* do nothing */
        }
    }

    // Remove backticks `text`
    {
        size_t buf_len = strlen(buf);
        char* result_buf = (char*)malloc(buf_len + 1);
        if (result_buf)
        {
            size_t ri = 0;
            size_t i = 0;
            while (i < buf_len)
            {
                if (buf[i] == '`')
                {
                    size_t start = i + 1;
                    size_t j = start;
                    while (j < buf_len && buf[j] != '`')
                    {
                        j++;
                    }
                    if (j < buf_len)
                    {
                        // Found matching backtick
                        (void)memcpy(&result_buf[ri], &buf[start], j - start);
                        ri += j - start;
                        i = j + 1;
                    }
                    else
                    {
                        result_buf[ri++] = buf[i++];
                    }
                }
                else
                {
                    result_buf[ri++] = buf[i++];
                }
            }
            result_buf[ri] = '\0';
            (void)strcpy(buf, result_buf);
            free(result_buf);
        }
        else
        {
            /* do nothing */
        }
    }

    // Unescape markdown: \X -> X for any character
    {
        size_t buf_len = strlen(buf);
        char* result_buf = (char*)malloc(buf_len + 1);
        if (result_buf)
        {
            size_t ri = 0;
            size_t i = 0;
            while (i < buf_len)
            {
                if (buf[i] == '\\' && i + 1 < buf_len)
                {
                    result_buf[ri++] = buf[i + 1];
                    i += 2;
                }
                else
                {
                    result_buf[ri++] = buf[i++];
                }
            }
            result_buf[ri] = '\0';
            (void)strcpy(buf, result_buf);
            free(result_buf);
        }
        else
        {
            /* do nothing */
        }
    }

    // Normalize whitespace
    {
        size_t buf_len = strlen(buf);
        size_t ri = 0;
        int in_space = 1; // skip leading
        for (size_t i = 0; i < buf_len; i++)
        {
            if (buf[i] == ' ' || buf[i] == '\t' || buf[i] == '\r' || buf[i] == '\n')
            {
                if (!in_space && ri < out_size - 1)
                {
                    out[ri++] = ' ';
                    in_space = 1;
                }
                else
                {
                    /* do nothing */
                }
            }
            else
            {
                if (ri < out_size - 1)
                {
                    out[ri++] = buf[i];
                }
                else
                {
                    /* do nothing */
                }
                in_space = 0;
            }
        }
        // Trim trailing space
        if (ri > 0 && out[ri - 1] == ' ')
        {
            ri--;
        }
        else
        {
            /* do nothing */
        }
        out[ri] = '\0';
    }

    free(buf);
}

// Normalize C text (just normalize whitespace)
static void normalize_c_text(const char* text, char* out, size_t out_size)
{
    size_t text_len = strlen(text);
    size_t ri = 0;
    int in_space = 1; // skip leading
    for (size_t i = 0; i < text_len; i++)
    {
        if (text[i] == ' ' || text[i] == '\t' || text[i] == '\r' || text[i] == '\n')
        {
            if (!in_space && ri < out_size - 1)
            {
                out[ri++] = ' ';
                in_space = 1;
            }
            else
            {
                /* do nothing */
            }
        }
        else
        {
            if (ri < out_size - 1)
            {
                out[ri++] = text[i];
            }
            else
            {
                /* do nothing */
            }
            in_space = 0;
        }
    }
    // Trim trailing space
    if (ri > 0 && out[ri - 1] == ' ')
    {
        ri--;
    }
    else
    {
        /* do nothing */
    }
    out[ri] = '\0';
}

// Determine if a file is a test file based on parent directory name
static int is_test_file(const char* relative_path)
{
    int result;
    result = 0;

    // Walk through path components (not the filename)
    const char* p = relative_path;
    while (*p && result == 0)
    {
        const char* sep = p;
        while (*sep && *sep != '/' && *sep != '\\')
        {
            sep++;
        }

        if (*sep == '\0')
        {
            // This is the filename, stop
            break;
        }
        else
        {
            size_t dir_len = (size_t)(sep - p);
            if (dir_len >= 3 && strncmp(sep - 3, "_ut", 3) == 0)
            {
                result = 1;
            }
            else if (dir_len >= 4 && strncmp(sep - 4, "_int", 4) == 0)
            {
                result = 1;
            }
            else
            {
                /* do nothing */
            }
            p = sep + 1;
        }
    }

    return result;
}

static size_t find_line_end(const char* content, size_t content_len, size_t start)
{
    size_t p = start;
    while (p < content_len && content[p] != '\n' && content[p] != '\r')
    {
        p++;
    }
    return p;
}

// Extract SRS tags from markdown content
static void extract_markdown_srs_tags(const char* content, size_t content_len, const char* file_path)
{
    size_t p = 0;

    while (p + 10 < content_len)
    {
        // Find "**SRS_"
        if (p + 6 < content_len &&
            content[p] == '*' && content[p + 1] == '*' &&
            content[p + 2] == 'S' && content[p + 3] == 'R' &&
            content[p + 4] == 'S' && content[p + 5] == '_')
        {
            size_t tag_start = p + 2; // Start of "SRS_"
            size_t q = p + 6;

            // Scan tag chars
            while (q < content_len && is_srs_tag_char(content[q]))
            {
                q++;
            }
            size_t tag_end = q;

            // Expect ':'
            if (q >= content_len || content[q] != ':')
            {
                p += 2;
            }
            else
            {
                // Validate tag format
                if (!validate_srs_tag_format(&content[tag_start], tag_end - tag_start))
                {
                    p += 2;
                }
                else
                {
                    q++; // skip ':'

                    // Skip bold close markers (**) and whitespace between ':' and '['
                    // Handles format: **SRS_TAG:** [** text **]**
                    while (q < content_len && (content[q] == '*' || content[q] == ' ' || content[q] == '\t'))
                    {
                        q++;
                    }

                    // Expect "[" then "**"
                    if (q >= content_len || content[q] != '[')
                    {
                        p += 2;
                    }
                    else
                    {
                        q++; // skip '['

                        // Skip '**' after '['
                        while (q < content_len && content[q] == '*')
                        {
                            q++;
                        }

                        // Skip whitespace after [**
                        while (q < content_len && (content[q] == ' ' || content[q] == '\t'))
                        {
                            q++;
                        }

                        // Find "**]**" ending - don't cross newlines
                        size_t text_start = q;
                        size_t text_end_found = 0;
                        size_t te = 0;

                        while (q + 5 <= content_len)
                        {
                            if (content[q] == '\n' || content[q] == '\r')
                            {
                                break;
                            }
                            else if (content[q] == '*' && content[q + 1] == '*' &&
                                     content[q + 2] == ']' && content[q + 3] == '*' && content[q + 4] == '*')
                            {
                                te = q;
                                text_end_found = 1;
                                break;
                            }
                            else
                            {
                                q++;
                            }
                        }

                        if (text_end_found)
                        {
                            // Trim trailing whitespace from text
                            size_t actual_end = te;
                            while (actual_end > text_start && (content[actual_end - 1] == ' ' || content[actual_end - 1] == '\t'))
                            {
                                actual_end--;
                            }

                            // Extract tag and text
                            size_t tag_len = tag_end - tag_start;
                            char tag[MAX_TAG_LENGTH];
                            if (tag_len >= MAX_TAG_LENGTH)
                            {
                                tag_len = MAX_TAG_LENGTH - 1;
                            }
                            else
                            {
                                /* do nothing */
                            }
                            (void)memcpy(tag, &content[tag_start], tag_len);
                            tag[tag_len] = '\0';

                            // Extract raw text
                            size_t raw_len = actual_end - text_start;
                            char* raw_text = (char*)malloc(raw_len + 1);
                            if (raw_text)
                            {
                                (void)memcpy(raw_text, &content[text_start], raw_len);
                                raw_text[raw_len] = '\0';

                                char clean_text[MAX_SRS_TEXT];
                                strip_markdown_formatting(raw_text, clean_text, sizeof(clean_text));
                                free(raw_text);

                                // Insert if not already present
                                if (!find_md_req(tag))
                                {
                                    insert_md_req(tag, clean_text, file_path);
                                    total_md_requirements++;
                                }
                                else
                                {
                                    /* do nothing - duplicate handled by srs_uniqueness check */
                                }
                            }
                            else
                            {
                                /* do nothing */
                            }

                            p = te + 5;
                        }
                        else
                        {
                            p += 2;
                        }
                    }
                }
            }
        }
        else
        {
            p++;
        }
    }
}

// Extract SRS tags from C code
static void extract_c_srs_tags(const char* content, size_t content_len, const char* file_path,
                                const char* relative_path, int file_is_test)
{
    // Track complete block comment ranges to avoid overlap with line comments
    typedef struct range_tag
    {
        size_t start;
        size_t end;
    } RANGE;

    RANGE* complete_ranges = NULL;
    int num_ranges = 0;
    int ranges_capacity = 0;

    // Phase 1: Find block comments
    {
        size_t p = 0;
        while (p + 2 < content_len)
        {
            if (content[p] == '/' && content[p + 1] == '*')
            {
                size_t comment_start = p;
                size_t q = p + 2;
                // Skip additional * chars
                while (q < content_len && content[q] == '*')
                {
                    q++;
                }
                // Skip whitespace
                while (q < content_len && (content[q] == ' ' || content[q] == '\t'))
                {
                    q++;
                }

                // Check for Codes_ or Tests_ prefix
                const char* prefix = NULL;
                if (q + 6 <= content_len && strncmp(&content[q], "Codes_", 6) == 0)
                {
                    prefix = "Codes";
                    q += 6;
                }
                else if (q + 6 <= content_len && strncmp(&content[q], "Tests_", 6) == 0)
                {
                    prefix = "Tests";
                    q += 6;
                }
                else
                {
                    p++;
                    continue;
                }

                // Expect "SRS_"
                if (q + 4 > content_len || strncmp(&content[q], "SRS_", 4) != 0)
                {
                    p++;
                    continue;
                }
                else
                {
                    /* do nothing */
                }
                size_t tag_start = q;
                q += 4;

                // Scan tag chars
                while (q < content_len && is_srs_tag_char(content[q]))
                {
                    q++;
                }
                size_t tag_end = q;

                if (!validate_srs_tag_format(&content[tag_start], tag_end - tag_start))
                {
                    p++;
                    continue;
                }
                else
                {
                    /* do nothing */
                }

                // Skip optional whitespace before colon
                while (q < content_len && (content[q] == ' ' || content[q] == '\t'))
                {
                    q++;
                }

                // Expect ':'
                if (q >= content_len || content[q] != ':')
                {
                    p++;
                    continue;
                }
                else
                {
                    /* do nothing */
                }
                q++;

                // Skip whitespace
                while (q < content_len && (content[q] == ' ' || content[q] == '\t'))
                {
                    q++;
                }

                // Expect '['
                if (q >= content_len || content[q] != '[')
                {
                    p++;
                    continue;
                }
                else
                {
                    /* do nothing */
                }
                q++;

                // Skip whitespace after [
                while (q < content_len && (content[q] == ' ' || content[q] == '\t'))
                {
                    q++;
                }
                size_t actual_text_start = q;

                // Scan for ]*/ (complete) or */ (incomplete) on same line
                size_t line_end = find_line_end(content, content_len, q);

                int found_complete = 0;
                int found_incomplete = 0;
                size_t text_end_pos = q;
                size_t comment_end_pos = q;

                // Search for ]*/
                {
                    size_t scan = q;
                    while (scan < line_end)
                    {
                        if (content[scan] == ']')
                        {
                            size_t after_bracket = scan + 1;
                            while (after_bracket < line_end && (content[after_bracket] == ' ' || content[after_bracket] == '\t'))
                            {
                                after_bracket++;
                            }
                            if (after_bracket + 1 < content_len && content[after_bracket] == '*' && content[after_bracket + 1] == '/')
                            {
                                text_end_pos = scan;
                                comment_end_pos = after_bracket + 2;
                                found_complete = 1;
                            }
                            else if (after_bracket + 2 < content_len && content[after_bracket] == '*' && content[after_bracket + 1] == '*' && content[after_bracket + 2] == '/')
                            {
                                text_end_pos = scan;
                                comment_end_pos = after_bracket + 3;
                                found_complete = 1;
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
                        scan++;
                    }
                }

                if (!found_complete)
                {
                    // Look for incomplete: text followed by */ without ]
                    size_t scan = q;
                    int has_bracket_in_text = 0;
                    while (scan + 1 < line_end)
                    {
                        if (content[scan] == ']')
                        {
                            has_bracket_in_text = 1;
                        }
                        else
                        {
                            /* do nothing */
                        }
                        if (content[scan] == '*' && content[scan + 1] == '/')
                        {
                            if (!has_bracket_in_text)
                            {
                                text_end_pos = scan;
                                comment_end_pos = scan + 2;
                                found_incomplete = 1;
                            }
                            else
                            {
                                /* do nothing */
                            }
                            break;
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

                if (found_complete || found_incomplete)
                {
                    char tag[MAX_TAG_LENGTH];
                    size_t tag_len = tag_end - tag_start;
                    if (tag_len >= MAX_TAG_LENGTH)
                    {
                        tag_len = MAX_TAG_LENGTH - 1;
                    }
                    else
                    {
                        /* do nothing */
                    }
                    (void)memcpy(tag, &content[tag_start], tag_len);
                    tag[tag_len] = '\0';

                    // Extract and normalize text
                    size_t raw_len = text_end_pos - actual_text_start;
                    char* raw_text = (char*)malloc(raw_len + 1);
                    if (raw_text)
                    {
                        (void)memcpy(raw_text, &content[actual_text_start], raw_len);
                        raw_text[raw_len] = '\0';

                        char clean_text[MAX_SRS_TEXT];
                        normalize_c_text(raw_text, clean_text, sizeof(clean_text));
                        free(raw_text);

                        // Extract original match
                        size_t orig_len = comment_end_pos - comment_start;
                        char* original = (char*)malloc(orig_len + 1);
                        if (original)
                        {
                            (void)memcpy(original, &content[comment_start], orig_len);
                            original[orig_len] = '\0';

                            // Check for duplication (multiple ]*/ in original)
                            int dup_count = 0;
                            {
                                const char* search = original;
                                while ((search = strstr(search, "]*/")) != NULL)
                                {
                                    dup_count++;
                                    search += 3;
                                }
                            }

                            // Tag placement check
                            if (file_is_test && strcmp(prefix, "Codes") == 0)
                            {
                                char full_tag[MAX_TAG_LENGTH];
                                (void)snprintf(full_tag, sizeof(full_tag), "%s_%s", prefix, tag);
                                add_placement_violation(relative_path, full_tag,
                                    "Codes_SRS_ tag found in test file (should use Tests_SRS_)");
                            }
                            else if (!file_is_test && strcmp(prefix, "Tests") == 0)
                            {
                                char full_tag[MAX_TAG_LENGTH];
                                (void)snprintf(full_tag, sizeof(full_tag), "%s_%s", prefix, tag);
                                add_placement_violation(relative_path, full_tag,
                                    "Tests_SRS_ tag found in production file (should use Codes_SRS_)");
                            }
                            else
                            {
                                /* do nothing */
                            }

                            // Store complete range
                            if (num_ranges >= ranges_capacity)
                            {
                                int new_cap = (ranges_capacity == 0) ? 64 : ranges_capacity * 2;
                                RANGE* new_ranges = (RANGE*)realloc(complete_ranges, (size_t)new_cap * sizeof(RANGE));
                                if (new_ranges)
                                {
                                    complete_ranges = new_ranges;
                                    ranges_capacity = new_cap;
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
                            if (num_ranges < ranges_capacity)
                            {
                                complete_ranges[num_ranges].start = comment_start;
                                complete_ranges[num_ranges].end = comment_end_pos;
                                num_ranges++;
                            }
                            else
                            {
                                /* do nothing */
                            }

                            COLLECTED_C_TAG ctag;
                            (void)memset(&ctag, 0, sizeof(ctag));
                            (void)strncpy(ctag.tag, tag, MAX_TAG_LENGTH - 1);
                            (void)strncpy(ctag.prefix, prefix, sizeof(ctag.prefix) - 1);
                            (void)strncpy(ctag.text, clean_text, MAX_SRS_TEXT - 1);
                            ctag.original_match = original;
                            ctag.match_index = comment_start;
                            ctag.has_duplication = (dup_count > 1) ? 1 : 0;
                            ctag.is_incomplete = (found_incomplete && !found_complete) ? 1 : 0;
                            (void)strncpy(ctag.c_file_path, file_path, MAX_PATH_LENGTH - 1);
                            (void)strncpy(ctag.c_file_relative, relative_path, MAX_PATH_LENGTH - 1);
                            add_c_tag(&ctag);
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

                    p = comment_end_pos;
                }
                else
                {
                    p++;
                }
            }
            else
            {
                p++;
            }
        }
    }

    // Phase 2: Find line comments
    {
        size_t p = 0;
        while (p + 2 < content_len)
        {
            if (content[p] == '/' && content[p + 1] == '/')
            {
                size_t comment_start = p;
                size_t q = p + 2;

                // Skip whitespace
                while (q < content_len && (content[q] == ' ' || content[q] == '\t'))
                {
                    q++;
                }

                // Check for Codes_ or Tests_ prefix
                const char* prefix = NULL;
                if (q + 6 <= content_len && strncmp(&content[q], "Codes_", 6) == 0)
                {
                    prefix = "Codes";
                    q += 6;
                }
                else if (q + 6 <= content_len && strncmp(&content[q], "Tests_", 6) == 0)
                {
                    prefix = "Tests";
                    q += 6;
                }
                else
                {
                    p++;
                    continue;
                }

                // Expect "SRS_"
                if (q + 4 > content_len || strncmp(&content[q], "SRS_", 4) != 0)
                {
                    p++;
                    continue;
                }
                else
                {
                    /* do nothing */
                }
                size_t tag_start = q;
                q += 4;

                // Scan tag chars
                while (q < content_len && is_srs_tag_char(content[q]))
                {
                    q++;
                }
                size_t tag_end = q;

                if (!validate_srs_tag_format(&content[tag_start], tag_end - tag_start))
                {
                    p++;
                    continue;
                }
                else
                {
                    /* do nothing */
                }

                // Skip optional whitespace before colon
                while (q < content_len && (content[q] == ' ' || content[q] == '\t'))
                {
                    q++;
                }

                // Expect ':'
                if (q >= content_len || content[q] != ':')
                {
                    p++;
                    continue;
                }
                else
                {
                    /* do nothing */
                }
                q++;

                // Skip whitespace
                while (q < content_len && (content[q] == ' ' || content[q] == '\t'))
                {
                    q++;
                }

                // Expect '['
                if (q >= content_len || content[q] != '[')
                {
                    p++;
                    continue;
                }
                else
                {
                    /* do nothing */
                }
                q++;

                // Skip whitespace
                while (q < content_len && (content[q] == ' ' || content[q] == '\t'))
                {
                    q++;
                }
                size_t text_start = q;

                // Find end of line
                size_t line_end = find_line_end(content, content_len, q);

                // Find the last ] on this line
                size_t last_bracket = 0;
                int has_bracket = 0;
                {
                    size_t i = line_end;
                    while (i > text_start)
                    {
                        i--;
                        if (content[i] == ']')
                        {
                            last_bracket = i;
                            has_bracket = 1;
                            break;
                        }
                        else
                        {
                            /* do nothing */
                        }
                    }
                }

                size_t text_end = has_bracket ? last_bracket : line_end;

                // Check overlap with block comment ranges
                int overlaps = 0;
                for (int ri = 0; ri < num_ranges && !overlaps; ri++)
                {
                    if (comment_start >= complete_ranges[ri].start && comment_start < complete_ranges[ri].end)
                    {
                        overlaps = 1;
                    }
                    else
                    {
                        /* do nothing */
                    }
                }

                if (overlaps)
                {
                    p++;
                }
                else
                {
                    char tag[MAX_TAG_LENGTH];
                    size_t tag_len = tag_end - tag_start;
                    if (tag_len >= MAX_TAG_LENGTH)
                    {
                        tag_len = MAX_TAG_LENGTH - 1;
                    }
                    else
                    {
                        /* do nothing */
                    }
                    (void)memcpy(tag, &content[tag_start], tag_len);
                    tag[tag_len] = '\0';

                    size_t raw_len = text_end - text_start;
                    char* raw_text = (char*)malloc(raw_len + 1);
                    if (raw_text)
                    {
                        (void)memcpy(raw_text, &content[text_start], raw_len);
                        raw_text[raw_len] = '\0';

                        char clean_text[MAX_SRS_TEXT];
                        normalize_c_text(raw_text, clean_text, sizeof(clean_text));
                        free(raw_text);

                        size_t original_end = has_bracket ? (text_end + 1) : line_end;
                        size_t orig_len = original_end - comment_start;
                        char* original = (char*)malloc(orig_len + 1);
                        if (original)
                        {
                            (void)memcpy(original, &content[comment_start], orig_len);
                            original[orig_len] = '\0';

                            // Tag placement check
                            if (file_is_test && strcmp(prefix, "Codes") == 0)
                            {
                                char full_tag[MAX_TAG_LENGTH];
                                (void)snprintf(full_tag, sizeof(full_tag), "%s_%s", prefix, tag);
                                add_placement_violation(relative_path, full_tag,
                                    "Codes_SRS_ tag found in test file (should use Tests_SRS_)");
                            }
                            else if (!file_is_test && strcmp(prefix, "Tests") == 0)
                            {
                                char full_tag[MAX_TAG_LENGTH];
                                (void)snprintf(full_tag, sizeof(full_tag), "%s_%s", prefix, tag);
                                add_placement_violation(relative_path, full_tag,
                                    "Tests_SRS_ tag found in production file (should use Codes_SRS_)");
                            }
                            else
                            {
                                /* do nothing */
                            }

                            COLLECTED_C_TAG ctag;
                            (void)memset(&ctag, 0, sizeof(ctag));
                            (void)strncpy(ctag.tag, tag, MAX_TAG_LENGTH - 1);
                            (void)strncpy(ctag.prefix, prefix, sizeof(ctag.prefix) - 1);
                            (void)strncpy(ctag.text, clean_text, MAX_SRS_TEXT - 1);
                            ctag.original_match = original;
                            ctag.match_index = comment_start;
                            ctag.has_duplication = 0;
                            ctag.is_incomplete = has_bracket ? 0 : 1;
                            (void)strncpy(ctag.c_file_path, file_path, MAX_PATH_LENGTH - 1);
                            (void)strncpy(ctag.c_file_relative, relative_path, MAX_PATH_LENGTH - 1);
                            add_c_tag(&ctag);
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

                    p = line_end;
                }
            }
            else
            {
                p++;
            }
        }
    }

    free(complete_ranges);
}

static int str_eq_ignore_case(const char* a, const char* b)
{
    int result;
    result = 1;
    size_t i = 0;
    while (a[i] && b[i] && result == 1)
    {
        if (tolower((unsigned char)a[i]) != tolower((unsigned char)b[i]))
        {
            result = 0;
        }
        else
        {
            i++;
        }
    }
    if (a[i] != '\0' || b[i] != '\0')
    {
        result = 0;
    }
    else
    {
        /* do nothing */
    }
    return result;
}

// Build a fixed comment by replacing text portion while preserving structure
static char* build_fixed_comment(const char* old_comment, const char* new_text)
{
    char* result = NULL;

    if (strlen(old_comment) >= 2 && old_comment[0] == '/' && old_comment[1] == '*')
    {
        // Block comment
        const char* bracket_open = strchr(old_comment, '[');
        if (bracket_open)
        {
            size_t bracket_pos = (size_t)(bracket_open - old_comment);

            // Find */ position (from end)
            const char* end_marker = NULL;
            {
                size_t olen = strlen(old_comment);
                for (size_t i = olen; i >= 2; i--)
                {
                    if (old_comment[i - 2] == '*' && old_comment[i - 1] == '/')
                    {
                        end_marker = &old_comment[i - 2];
                        break;
                    }
                    else
                    {
                        /* do nothing */
                    }
                }
            }

            if (end_marker)
            {
                // Find last ] before */
                const char* last_bracket = NULL;
                {
                    const char* search = bracket_open + 1;
                    while (search < end_marker)
                    {
                        if (*search == ']')
                        {
                            last_bracket = search;
                        }
                        else
                        {
                            /* do nothing */
                        }
                        search++;
                    }
                }

                size_t result_size = strlen(old_comment) + strlen(new_text) + 64;
                result = (char*)malloc(result_size);
                if (result)
                {
                    if (last_bracket)
                    {
                        // Complete comment: preserve [ws text ws] suffix
                        // Find whitespace after [
                        const char* ws_start = bracket_open + 1;
                        size_t ws_after_len = 0;
                        while (ws_start + ws_after_len < last_bracket &&
                               (ws_start[ws_after_len] == ' ' || ws_start[ws_after_len] == '\t'))
                        {
                            ws_after_len++;
                        }

                        // Find whitespace before ]
                        const char* before_bracket = last_bracket;
                        size_t ws_before_len = 0;
                        while (before_bracket - ws_before_len > bracket_open + 1 + ws_after_len &&
                               (before_bracket[-1 - (long long)ws_before_len] == ' ' || before_bracket[-1 - (long long)ws_before_len] == '\t'))
                        {
                            ws_before_len++;
                        }

                        // Build: prefix + [ + ws_after + new_text + ws_before + ] + suffix
                        size_t pos = 0;
                        (void)memcpy(result + pos, old_comment, bracket_pos + 1);
                        pos += bracket_pos + 1;
                        (void)memcpy(result + pos, ws_start, ws_after_len);
                        pos += ws_after_len;
                        size_t new_text_len = strlen(new_text);
                        (void)memcpy(result + pos, new_text, new_text_len);
                        pos += new_text_len;
                        (void)memcpy(result + pos, before_bracket - ws_before_len, ws_before_len);
                        pos += ws_before_len;
                        size_t suffix_len = strlen(last_bracket);
                        (void)memcpy(result + pos, last_bracket, suffix_len);
                        pos += suffix_len;
                        result[pos] = '\0';
                    }
                    else
                    {
                        // Incomplete comment - add closing bracket
                        // Find whitespace after [
                        const char* ws_start = bracket_open + 1;
                        size_t ws_after_len = 0;
                        while (ws_start + ws_after_len < end_marker &&
                               (ws_start[ws_after_len] == ' ' || ws_start[ws_after_len] == '\t'))
                        {
                            ws_after_len++;
                        }

                        size_t pos = 0;
                        (void)memcpy(result + pos, old_comment, bracket_pos + 1);
                        pos += bracket_pos + 1;
                        (void)memcpy(result + pos, ws_start, ws_after_len);
                        pos += ws_after_len;
                        size_t new_text_len = strlen(new_text);
                        (void)memcpy(result + pos, new_text, new_text_len);
                        pos += new_text_len;
                        result[pos++] = ' ';
                        result[pos++] = ']';
                        size_t end_len = strlen(end_marker);
                        (void)memcpy(result + pos, end_marker, end_len);
                        pos += end_len;
                        result[pos] = '\0';
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
    else if (strlen(old_comment) >= 2 && old_comment[0] == '/' && old_comment[1] == '/')
    {
        // Line comment
        const char* bracket_open = strchr(old_comment, '[');
        if (bracket_open)
        {
            size_t bracket_pos = (size_t)(bracket_open - old_comment);

            // Find last ] after [
            const char* last_bracket = NULL;
            {
                const char* search = bracket_open + 1;
                size_t remaining = strlen(search);
                for (size_t i = remaining; i > 0; i--)
                {
                    if (search[i - 1] == ']')
                    {
                        last_bracket = &search[i - 1];
                        break;
                    }
                    else
                    {
                        /* do nothing */
                    }
                }
            }

            size_t result_size = strlen(old_comment) + strlen(new_text) + 64;
            result = (char*)malloc(result_size);
            if (result)
            {
                if (last_bracket)
                {
                    // Find whitespace after [
                    const char* ws_start = bracket_open + 1;
                    size_t ws_after_len = 0;
                    while (ws_start + ws_after_len < last_bracket &&
                           (ws_start[ws_after_len] == ' ' || ws_start[ws_after_len] == '\t'))
                    {
                        ws_after_len++;
                    }

                    // Find whitespace before ]
                    size_t ws_before_len = 0;
                    while (last_bracket - ws_before_len > bracket_open + 1 + ws_after_len &&
                           (last_bracket[-1 - (long long)ws_before_len] == ' ' || last_bracket[-1 - (long long)ws_before_len] == '\t'))
                    {
                        ws_before_len++;
                    }

                    size_t pos = 0;
                    (void)memcpy(result + pos, old_comment, bracket_pos + 1);
                    pos += bracket_pos + 1;
                    (void)memcpy(result + pos, ws_start, ws_after_len);
                    pos += ws_after_len;
                    size_t new_text_len = strlen(new_text);
                    (void)memcpy(result + pos, new_text, new_text_len);
                    pos += new_text_len;
                    (void)memcpy(result + pos, last_bracket - ws_before_len, ws_before_len);
                    pos += ws_before_len;
                    result[pos++] = ']';
                    result[pos] = '\0';
                }
                else
                {
                    size_t pos = 0;
                    (void)memcpy(result + pos, old_comment, bracket_pos + 1);
                    pos += bracket_pos + 1;
                    result[pos++] = ' ';
                    size_t new_text_len = strlen(new_text);
                    (void)memcpy(result + pos, new_text, new_text_len);
                    pos += new_text_len;
                    result[pos++] = ' ';
                    result[pos++] = ']';
                    result[pos] = '\0';
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

    return result;
}

static int srs_consistency_init(const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;
    (void)memset(md_hash_table, 0, sizeof(md_hash_table));
    c_tags_array = NULL;
    c_tags_count = 0;
    c_tags_capacity = 0;
    placement_violations = NULL;
    total_md_requirements = 0;
    c_files_scanned = 0;
    result = 0;
    return result;
}

static int srs_consistency_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    int result;
    (void)config;

    // Collect markdown requirements from devdoc
    if ((file->type_flags & FILE_TYPE_MD) && (file->type_flags & FILE_FLAG_IN_DEVDOC))
    {
        extract_markdown_srs_tags(file->content, file->content_length, file->relative_path);
        result = 0;
    }
    // Collect C file tags
    else if (file->type_flags & FILE_TYPE_C)
    {
        c_files_scanned++;
        int file_is_test = is_test_file(file->relative_path);
        extract_c_srs_tags(file->content, file->content_length, file->path, file->relative_path, file_is_test);
        result = 0;
    }
    else
    {
        result = 0;
    }

    return result;
}

static int srs_consistency_finalize(const VALIDATOR_CONFIG* config)
{
    int result;

    // Compare C tags against markdown
    INCONSISTENCY_RECORD* inconsistencies = NULL;
    int inconsistency_count = 0;

    for (int i = 0; i < c_tags_count; i++)
    {
        MD_REQ_ENTRY* md_req = find_md_req(c_tags_array[i].tag);
        if (md_req)
        {
            int texts_match = str_eq_ignore_case(c_tags_array[i].text, md_req->clean_text);
            if (!texts_match || c_tags_array[i].has_duplication || c_tags_array[i].is_incomplete)
            {
                INCONSISTENCY_RECORD* inc = (INCONSISTENCY_RECORD*)malloc(sizeof(INCONSISTENCY_RECORD));
                if (inc)
                {
                    (void)strncpy(inc->tag, c_tags_array[i].tag, MAX_TAG_LENGTH - 1);
                    inc->tag[MAX_TAG_LENGTH - 1] = '\0';
                    (void)strncpy(inc->c_file, c_tags_array[i].c_file_path, MAX_PATH_LENGTH - 1);
                    inc->c_file[MAX_PATH_LENGTH - 1] = '\0';
                    (void)strncpy(inc->c_text, c_tags_array[i].text, MAX_SRS_TEXT - 1);
                    inc->c_text[MAX_SRS_TEXT - 1] = '\0';
                    (void)strncpy(inc->md_text, md_req->clean_text, MAX_SRS_TEXT - 1);
                    inc->md_text[MAX_SRS_TEXT - 1] = '\0';
                    if (c_tags_array[i].original_match)
                    {
                        inc->original_match = c_tags_array[i].original_match;
                        c_tags_array[i].original_match = NULL; // transfer ownership
                    }
                    else
                    {
                        inc->original_match = NULL;
                    }
                    inc->match_index = c_tags_array[i].match_index;
                    inc->next = inconsistencies;
                    inconsistencies = inc;
                    inconsistency_count++;
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

    // Count placement violations
    int placement_count = 0;
    {
        PLACEMENT_VIOLATION* v = placement_violations;
        while (v)
        {
            placement_count++;
            v = v->next;
        }
    }

    (void)printf("\n  SRS requirements in markdown: %d\n", total_md_requirements);
    (void)printf("  C source files scanned: %d\n", c_files_scanned);
    (void)printf("  Inconsistencies found: %d\n", inconsistency_count);
    (void)printf("  Tag placement violations: %d\n", placement_count);

    int unfixed = inconsistency_count;

    if (inconsistency_count > 0)
    {
        if (config->fix_mode)
        {
            // Fix mode: group by file and fix
            int fixed_count = 0;
            INCONSISTENCY_RECORD* inc = inconsistencies;
            while (inc)
            {
                if (inc->original_match)
                {
                    // Read file
                    size_t file_len = 0;
                    char* file_content = read_file_content(inc->c_file, &file_len);
                    if (file_content)
                    {
                        char* found = strstr(file_content, inc->original_match);
                        if (found)
                        {
                            char* new_comment = build_fixed_comment(inc->original_match, inc->md_text);
                            if (new_comment)
                            {
                                size_t old_len = strlen(inc->original_match);
                                size_t new_len = strlen(new_comment);
                                size_t before_len = (size_t)(found - file_content);
                                size_t after_len = file_len - before_len - old_len;
                                size_t new_file_len = before_len + new_len + after_len;
                                char* new_content = (char*)malloc(new_file_len + 1);
                                if (new_content)
                                {
                                    (void)memcpy(new_content, file_content, before_len);
                                    (void)memcpy(new_content + before_len, new_comment, new_len);
                                    (void)memcpy(new_content + before_len + new_len, found + old_len, after_len);
                                    new_content[new_file_len] = '\0';

                                    FILE* f = fopen(inc->c_file, "wb");
                                    if (f)
                                    {
                                        (void)fwrite(new_content, 1, new_file_len, f);
                                        (void)fclose(f);

                                        // Extract filename for output
                                        const char* fname = strrchr(inc->c_file, PATH_SEP);
#ifdef _WIN32
                                        if (!fname)
                                        {
                                            fname = strrchr(inc->c_file, '/');
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
                                            fname = inc->c_file;
                                        }
                                        (void)printf("  [FIXED] %s in %s\n", inc->tag, fname);
                                        fixed_count++;
                                    }
                                    else
                                    {
                                        /* do nothing */
                                    }
                                    free(new_content);
                                }
                                else
                                {
                                    /* do nothing */
                                }
                                free(new_comment);
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
                        free(file_content);
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
                inc = inc->next;
            }
            (void)printf("  Fixed %d inconsistencies\n", fixed_count);
            unfixed = 0;
        }
        else
        {
            INCONSISTENCY_RECORD* inc = inconsistencies;
            while (inc)
            {
                (void)printf("  [ERROR] %s\n", inc->tag);
                (void)printf("          C file: %s\n", inc->c_file);
                (void)printf("          C text:  '%s'\n", inc->c_text);
                (void)printf("          MD text: '%s'\n", inc->md_text);
                inc = inc->next;
            }
        }
    }
    else
    {
        /* do nothing */
    }

    if (placement_count > 0)
    {
        (void)printf("\n  Tag placement violations:\n");
        PLACEMENT_VIOLATION* v = placement_violations;
        while (v)
        {
            (void)printf("    [ERROR] %s: %s - %s\n", v->file_path, v->full_tag, v->violation);
            v = v->next;
        }
    }
    else
    {
        /* do nothing */
    }

    // Free inconsistency records
    {
        INCONSISTENCY_RECORD* inc = inconsistencies;
        while (inc)
        {
            INCONSISTENCY_RECORD* next = inc->next;
            free(inc->original_match);
            free(inc);
            inc = next;
        }
    }

    result = unfixed + placement_count;
    return result;
}

static void srs_consistency_cleanup(void)
{
    // Free MD hash table
    for (int i = 0; i < SRSC_HASH_SIZE; i++)
    {
        MD_REQ_ENTRY* e = md_hash_table[i];
        while (e)
        {
            MD_REQ_ENTRY* next = e->next;
            free(e);
            e = next;
        }
        md_hash_table[i] = NULL;
    }

    // Free C tags array
    if (c_tags_array)
    {
        for (int i = 0; i < c_tags_count; i++)
        {
            free(c_tags_array[i].original_match);
        }
        free(c_tags_array);
        c_tags_array = NULL;
    }
    else
    {
        /* do nothing */
    }
    c_tags_count = 0;
    c_tags_capacity = 0;

    // Free placement violations
    {
        PLACEMENT_VIOLATION* v = placement_violations;
        while (v)
        {
            PLACEMENT_VIOLATION* next = v->next;
            free(v);
            v = next;
        }
        placement_violations = NULL;
    }

    total_md_requirements = 0;
    c_files_scanned = 0;
}

static const CHECK_DEFINITION check_srs_consistency_def =
{
    "srs_consistency",
    "Validates SRS requirement consistency between markdown and C code",
    FILE_TYPE_MD | FILE_TYPE_C,
    0,
    srs_consistency_init,
    srs_consistency_check_file,
    srs_consistency_finalize,
    srs_consistency_cleanup
};

const CHECK_DEFINITION* get_check_srs_consistency(void)
{
    return &check_srs_consistency_def;
}
