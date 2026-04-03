// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#ifndef REPO_VALIDATOR_H
#define REPO_VALIDATOR_H

#include <stddef.h>

#ifdef _WIN32
#define PATH_SEP '\\'
#define PATH_SEP_STR "\\"
#else
#define PATH_SEP '/'
#define PATH_SEP_STR "/"
#endif

#define MAX_PATH_LENGTH 4096
#define MAX_TAG_LENGTH 512

// File type classification bitmask
#define FILE_TYPE_C       0x0001
#define FILE_TYPE_H       0x0002
#define FILE_TYPE_CPP     0x0004
#define FILE_TYPE_HPP     0x0008
#define FILE_TYPE_CS      0x0010
#define FILE_TYPE_MD      0x0020
#define FILE_TYPE_TXT     0x0040

#define FILE_TYPE_C_SOURCE  (FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP | FILE_TYPE_HPP)
#define FILE_TYPE_ALL_CODE  (FILE_TYPE_C_SOURCE | FILE_TYPE_CS)

// File location flags
#define FILE_FLAG_IN_DEVDOC   0x0100
#define FILE_FLAG_IS_UT       0x0200

typedef struct file_info_tag
{
    char path[MAX_PATH_LENGTH];
    char relative_path[MAX_PATH_LENGTH];
    unsigned int type_flags;
    const char* content;
    size_t content_length;
} FILE_INFO;

typedef struct validator_config_tag
{
    const char* repo_root;
    size_t repo_root_length;
    const char** exclude_folders;
    int num_exclude_folders;
    int fix_mode;
    const char** enabled_checks;
    int num_enabled_checks;
} VALIDATOR_CONFIG;

// Check interface - each check implements these functions
typedef int (*CHECK_INIT_FN)(const VALIDATOR_CONFIG* config);
typedef int (*CHECK_FILE_FN)(const FILE_INFO* file, const VALIDATOR_CONFIG* config);
typedef int (*CHECK_FINALIZE_FN)(const VALIDATOR_CONFIG* config);
typedef void (*CHECK_CLEANUP_FN)(void);

typedef struct check_definition_tag
{
    const char* name;
    const char* description;
    unsigned int file_types;
    int requires_devdoc;
    CHECK_INIT_FN init;
    CHECK_FILE_FN check_file;
    CHECK_FINALIZE_FN finalize;
    CHECK_CLEANUP_FN cleanup;
} CHECK_DEFINITION;

// file_walker.c
int walk_repository(const VALIDATOR_CONFIG* config, const CHECK_DEFINITION** checks, int num_checks);

// Utility functions
int is_path_excluded(const char* relative_path, const char** exclude_folders, int num_excludes);
unsigned int classify_file_type(const char* filename);
int is_in_devdoc_directory(const char* path);
char* read_file_content(const char* path, size_t* out_length);
int compute_line_number(const char* content, size_t offset);

// Check declarations - Phase 1
const CHECK_DEFINITION* get_check_no_tabs(void);
const CHECK_DEFINITION* get_check_file_endings(void);
const CHECK_DEFINITION* get_check_requirements_naming(void);
const CHECK_DEFINITION* get_check_srs_uniqueness(void);

// Check declarations - Phase 2
const CHECK_DEFINITION* get_check_enable_mocks(void);
const CHECK_DEFINITION* get_check_no_vld_include(void);
const CHECK_DEFINITION* get_check_no_backticks_in_srs(void);
const CHECK_DEFINITION* get_check_test_spec_tags(void);

// Check declarations - Phase 3
const CHECK_DEFINITION* get_check_aaa_comments(void);
const CHECK_DEFINITION* get_check_srs_consistency(void);

#endif // REPO_VALIDATOR_H
