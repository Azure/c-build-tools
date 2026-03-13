// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "repo_validator.h"

#define MAX_CHECKS 32
#define MAX_EXCLUDES 64

static void print_usage(const char* program_name)
{
    printf("Usage: %s --repo-root <path> [options]\n\n", program_name);
    printf("Options:\n");
    printf("  --repo-root <path>        Repository root directory (required)\n");
    printf("  --exclude-folders <list>   Comma-separated list of folders to exclude\n");
    printf("  --fix                      Automatically fix validation errors\n");
    printf("  --check <name>             Run only the specified check (can be repeated)\n");
    printf("  --list-checks              List all available checks\n");
    printf("  --help                     Show this help message\n");
    printf("\nAvailable checks:\n");
    printf("  no_tabs                    Validates files contain no tab characters\n");
    printf("  file_endings               Validates files end with CRLF newline\n");
    printf("  requirements_naming        Validates requirement document naming\n");
    printf("  srs_uniqueness             Validates SRS tags are unique\n");
    printf("  enable_mocks               Validates ENABLE_MOCKS include pattern\n");
    printf("  no_vld_include             Validates files do not include vld.h\n");
    printf("  no_backticks_in_srs        Validates SRS comments have no backticks\n");
    printf("  test_spec_tags             Validates TEST_FUNCTION has spec tags\n");
}

static int is_check_enabled(const char* check_name, const char** enabled_checks, int num_enabled)
{
    if (num_enabled == 0) return 1; // all checks enabled by default

    for (int i = 0; i < num_enabled; i++)
    {
        if (strcmp(check_name, enabled_checks[i]) == 0) return 1;
    }
    return 0;
}

int main(int argc, char* argv[])
{
    const char* repo_root = NULL;
    const char* exclude_str = "";
    int fix_mode = 0;
    const char* enabled_check_names[MAX_CHECKS];
    int num_enabled_checks = 0;
    int list_checks = 0;

    // Parse arguments
    for (int i = 1; i < argc; i++)
    {
        if (strcmp(argv[i], "--repo-root") == 0 && i + 1 < argc)
        {
            repo_root = argv[++i];
        }
        else if (strcmp(argv[i], "--exclude-folders") == 0 && i + 1 < argc)
        {
            exclude_str = argv[++i];
        }
        else if (strcmp(argv[i], "--fix") == 0)
        {
            fix_mode = 1;
        }
        else if (strcmp(argv[i], "--check") == 0 && i + 1 < argc)
        {
            if (num_enabled_checks < MAX_CHECKS)
            {
                enabled_check_names[num_enabled_checks++] = argv[++i];
            }
        }
        else if (strcmp(argv[i], "--list-checks") == 0)
        {
            list_checks = 1;
        }
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0)
        {
            print_usage(argv[0]);
            return 0;
        }
        // Support PowerShell-style arguments for compatibility
        else if (strcmp(argv[i], "-RepoRoot") == 0 && i + 1 < argc)
        {
            repo_root = argv[++i];
        }
        else if (strcmp(argv[i], "-ExcludeFolders") == 0 && i + 1 < argc)
        {
            exclude_str = argv[++i];
        }
        else if (strcmp(argv[i], "-Fix") == 0)
        {
            fix_mode = 1;
        }
    }

    // Register all available checks
    const CHECK_DEFINITION* all_checks[] =
    {
        get_check_no_tabs(),
        get_check_file_endings(),
        get_check_requirements_naming(),
        get_check_srs_uniqueness(),
        get_check_enable_mocks(),
        get_check_no_vld_include(),
        get_check_no_backticks_in_srs(),
        get_check_test_spec_tags(),
    };
    int total_available_checks = (int)(sizeof(all_checks) / sizeof(all_checks[0]));

    if (list_checks)
    {
        printf("Available checks:\n");
        for (int i = 0; i < total_available_checks; i++)
        {
            printf("  %-25s %s\n", all_checks[i]->name, all_checks[i]->description);
        }
        return 0;
    }

    if (!repo_root)
    {
        fprintf(stderr, "Error: --repo-root is required\n\n");
        print_usage(argv[0]);
        return 1;
    }

    // Parse exclude folders
    const char* exclude_folders[MAX_EXCLUDES];
    int num_excludes = 0;

    // Default exclusions
    exclude_folders[num_excludes++] = "deps";
    exclude_folders[num_excludes++] = "cmake";

    // Parse additional exclusions from comma-separated string
    static char exclude_buf[4096];
    if (exclude_str[0] != '\0')
    {
        strncpy(exclude_buf, exclude_str, sizeof(exclude_buf) - 1);
        exclude_buf[sizeof(exclude_buf) - 1] = '\0';

        char* tok = strtok(exclude_buf, ",");
        while (tok && num_excludes < MAX_EXCLUDES)
        {
            // Trim whitespace
            while (*tok == ' ') tok++;
            char* end = tok + strlen(tok) - 1;
            while (end > tok && *end == ' ') *end-- = '\0';

            if (*tok && strcmp(tok, "deps") != 0 && strcmp(tok, "cmake") != 0)
            {
                exclude_folders[num_excludes++] = tok;
            }
            tok = strtok(NULL, ",");
        }
    }

    // Build config
    VALIDATOR_CONFIG config;
    memset(&config, 0, sizeof(config));
    config.repo_root = repo_root;
    config.repo_root_length = strlen(repo_root);
    config.exclude_folders = exclude_folders;
    config.num_exclude_folders = num_excludes;
    config.fix_mode = fix_mode;
    config.enabled_checks = enabled_check_names;
    config.num_enabled_checks = num_enabled_checks;

    // Select active checks
    const CHECK_DEFINITION* active_checks[MAX_CHECKS];
    int num_active = 0;

    for (int i = 0; i < total_available_checks; i++)
    {
        if (is_check_enabled(all_checks[i]->name, enabled_check_names, num_enabled_checks))
        {
            active_checks[num_active++] = all_checks[i];
        }
    }

    if (num_active == 0)
    {
        fprintf(stderr, "Error: no matching checks found\n");
        return 1;
    }

    // Print header
    printf("========================================\n");
    printf("Repository Validator\n");
    printf("========================================\n");
    printf("Repository Root: %s\n", repo_root);
    printf("Fix Mode: %s\n", fix_mode ? "ON" : "OFF");
    printf("Excluded folders: ");
    for (int i = 0; i < num_excludes; i++)
    {
        printf("%s%s", exclude_folders[i], (i < num_excludes - 1) ? ", " : "");
    }
    printf("\n");
    printf("Active checks: ");
    for (int i = 0; i < num_active; i++)
    {
        printf("%s%s", active_checks[i]->name, (i < num_active - 1) ? ", " : "");
    }
    printf("\n\n");

    // Initialize checks
    for (int i = 0; i < num_active; i++)
    {
        if (active_checks[i]->init)
        {
            active_checks[i]->init(&config);
        }
    }

    // Walk repository and run checks
    printf("Scanning repository...\n");
    int walk_violations = walk_repository(&config, active_checks, num_active);

    // Finalize checks
    int total_violations = 0;
    printf("\n========================================\n");
    printf("Validation Summary\n");
    printf("========================================\n");

    for (int i = 0; i < num_active; i++)
    {
        int check_result = 0;
        if (active_checks[i]->finalize)
        {
            check_result = active_checks[i]->finalize(&config);
        }

        const char* status = (check_result == 0) ? "PASSED" : "FAILED";
        printf("  %-25s [%s]\n", active_checks[i]->name, status);

        if (check_result > 0)
        {
            total_violations += check_result;
        }
    }

    // Cleanup
    for (int i = 0; i < num_active; i++)
    {
        if (active_checks[i]->cleanup)
        {
            active_checks[i]->cleanup();
        }
    }

    (void)walk_violations;

    printf("\n");
    if (total_violations > 0)
    {
        printf("[VALIDATION FAILED]\n");
        return 1;
    }
    else
    {
        printf("[VALIDATION PASSED]\n");
        return 0;
    }
}
