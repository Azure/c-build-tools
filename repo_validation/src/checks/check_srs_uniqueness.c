// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "../repo_validator.h"

#define SRS_HASH_SIZE 65537
#define MAX_SRS_TAG_LEN 256

typedef struct srs_entry_tag
{
    char tag[MAX_SRS_TAG_LEN];
    char file_path[MAX_PATH_LENGTH];
    int line_number;
    struct srs_entry_tag* next;
} SRS_ENTRY;

static SRS_ENTRY* srs_hash_table[SRS_HASH_SIZE];
static int srs_total_tags;
static int srs_duplicate_found;
static int srs_files_scanned;

static unsigned int hash_srs_tag(const char* s)
{
    unsigned int h = 5381;
    while (*s)
    {
        h = ((h << 5) + h) + (unsigned char)*s++;
    }
    return h % SRS_HASH_SIZE;
}

static SRS_ENTRY* find_srs_tag(const char* tag)
{
    unsigned int idx = hash_srs_tag(tag);
    SRS_ENTRY* e = srs_hash_table[idx];
    while (e)
    {
        if (strcmp(e->tag, tag) == 0) return e;
        e = e->next;
    }
    return NULL;
}

static void insert_srs_tag(const char* tag, const char* file_path, int line)
{
    unsigned int idx = hash_srs_tag(tag);
    SRS_ENTRY* e = (SRS_ENTRY*)malloc(sizeof(SRS_ENTRY));
    if (!e) return;

    strncpy(e->tag, tag, MAX_SRS_TAG_LEN - 1);
    e->tag[MAX_SRS_TAG_LEN - 1] = '\0';
    strncpy(e->file_path, file_path, MAX_PATH_LENGTH - 1);
    e->file_path[MAX_PATH_LENGTH - 1] = '\0';
    e->line_number = line;
    e->next = srs_hash_table[idx];
    srs_hash_table[idx] = e;
}

static int is_srs_module_char(char c)
{
    return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

static int srs_uniqueness_init(const VALIDATOR_CONFIG* config)
{
    (void)config;
    memset(srs_hash_table, 0, sizeof(srs_hash_table));
    srs_total_tags = 0;
    srs_duplicate_found = 0;
    srs_files_scanned = 0;
    return 0;
}

static int srs_uniqueness_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    (void)config;

    // Only process .md files in devdoc directories
    if (!(file->type_flags & FILE_TYPE_MD)) return 0;
    if (!(file->type_flags & FILE_FLAG_IN_DEVDOC)) return 0;

    srs_files_scanned++;

    const char* p = file->content;
    const char* end = file->content + file->content_length;

    while (p < end - 6)
    {
        // Find "**SRS_"
        const char* star = (const char*)memchr(p, '*', (size_t)(end - p));
        if (!star || star >= end - 6) break;

        if (star[1] == '*' && star[2] == 'S' && star[3] == 'R' && star[4] == 'S' && star[5] == '_')
        {
            const char* tag_start = star + 2; // 'S' of SRS
            const char* q = star + 6; // after "**SRS_"

            // Scan forward to find ':' (end of tag)
            const char* colon = q;
            while (colon < end && *colon != ':' && *colon != '\n' && *colon != '\r')
            {
                if (is_srs_module_char(*colon))
                {
                    colon++;
                }
                else
                {
                    break;
                }
            }

            if (colon >= end || *colon != ':')
            {
                p = star + 2;
                continue;
            }

            // Validate tag ends with _DD_DDD by checking backwards from colon
            size_t tag_len = (size_t)(colon - tag_start);
            if (tag_len < 11) // minimum: SRS_X_DD_DDD
            {
                p = star + 2;
                continue;
            }

            if (!isdigit((unsigned char)colon[-1]) || !isdigit((unsigned char)colon[-2]) || !isdigit((unsigned char)colon[-3]) ||
                colon[-4] != '_' ||
                !isdigit((unsigned char)colon[-5]) || !isdigit((unsigned char)colon[-6]) ||
                colon[-7] != '_')
            {
                p = star + 2;
                continue;
            }

            // Ensure there's at least one module char before _DD_DDD
            if (colon - 7 <= q)
            {
                p = star + 2;
                continue;
            }

            if (tag_len >= MAX_SRS_TAG_LEN)
            {
                p = star + 2;
                continue;
            }

            char tag[MAX_SRS_TAG_LEN];
            memcpy(tag, tag_start, tag_len);
            tag[tag_len] = '\0';

            int line = compute_line_number(file->content, (size_t)(star - file->content));
            srs_total_tags++;

            SRS_ENTRY* existing = find_srs_tag(tag);
            if (existing)
            {
                srs_duplicate_found = 1;

                const char* fname1 = strrchr(existing->file_path, PATH_SEP);
#ifdef _WIN32
                if (!fname1) fname1 = strrchr(existing->file_path, '/');
#endif
                if (fname1) fname1++;
                else fname1 = existing->file_path;

                const char* fname2 = strrchr(file->path, PATH_SEP);
#ifdef _WIN32
                if (!fname2) fname2 = strrchr(file->path, '/');
#endif
                if (fname2) fname2++;
                else fname2 = file->path;

                printf("  [ERROR] Duplicate SRS tag: %s\n", tag);
                printf("          First occurrence: %s:%d\n", fname1, existing->line_number);
                printf("          Duplicate found in: %s:%d\n", fname2, line);
            }
            else
            {
                insert_srs_tag(tag, file->path, line);
            }

            p = colon + 1;
        }
        else
        {
            p = star + 1;
        }
    }

    return 0;
}

static int srs_uniqueness_finalize(const VALIDATOR_CONFIG* config)
{
    (void)config;

    printf("\n  Requirement documents scanned: %d\n", srs_files_scanned);
    printf("  Total SRS tags found: %d\n", srs_total_tags);

    return srs_duplicate_found ? 1 : 0;
}

static void srs_uniqueness_cleanup(void)
{
    for (int i = 0; i < SRS_HASH_SIZE; i++)
    {
        SRS_ENTRY* e = srs_hash_table[i];
        while (e)
        {
            SRS_ENTRY* next = e->next;
            free(e);
            e = next;
        }
        srs_hash_table[i] = NULL;
    }
    srs_total_tags = 0;
    srs_duplicate_found = 0;
    srs_files_scanned = 0;
}

static const CHECK_DEFINITION check_srs_uniqueness_def =
{
    "srs_uniqueness",
    "Validates that SRS tags are unique across requirement documents",
    FILE_TYPE_MD,
    1, // requires devdoc
    srs_uniqueness_init,
    srs_uniqueness_check_file,
    srs_uniqueness_finalize,
    srs_uniqueness_cleanup
};

const CHECK_DEFINITION* get_check_srs_uniqueness(void)
{
    return &check_srs_uniqueness_def;
}
