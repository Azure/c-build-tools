// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../repo_validator.h"

static int no_tabs_violations;

static int no_tabs_init(const VALIDATOR_CONFIG* config)
{
    (void)config;
    no_tabs_violations = 0;
    return 0;
}

static int no_tabs_check_file(const FILE_INFO* file, const VALIDATOR_CONFIG* config)
{
    int tab_count = 0;
    int first_tab_line = -1;
    int current_line = 1;

    for (size_t i = 0; i < file->content_length; i++)
    {
        if (file->content[i] == '\t')
        {
            tab_count++;
            if (first_tab_line < 0)
            {
                first_tab_line = current_line;
            }
        }
        if (file->content[i] == '\n')
        {
            current_line++;
        }
    }

    if (tab_count > 0)
    {
        if (config->fix_mode)
        {
            // Replace tabs with 4 spaces
            // Count total size needed
            size_t new_size = file->content_length;
            for (size_t i = 0; i < file->content_length; i++)
            {
                if (file->content[i] == '\t') new_size += 3; // tab -> 4 spaces = 3 extra
            }

            char* new_content = (char*)malloc(new_size + 1);
            if (new_content)
            {
                size_t j = 0;
                for (size_t i = 0; i < file->content_length; i++)
                {
                    if (file->content[i] == '\t')
                    {
                        new_content[j++] = ' ';
                        new_content[j++] = ' ';
                        new_content[j++] = ' ';
                        new_content[j++] = ' ';
                    }
                    else
                    {
                        new_content[j++] = file->content[i];
                    }
                }
                new_content[j] = '\0';

                FILE* f = fopen(file->path, "wb");
                if (f)
                {
                    fwrite(new_content, 1, j, f);
                    fclose(f);
                    printf("  [FIXED] %s - replaced %d tab(s) with spaces\n", file->relative_path, tab_count);
                }

                free(new_content);
            }
        }
        else
        {
            printf("  [ERROR] %s - contains %d tab(s), first at line %d\n", file->relative_path, tab_count, first_tab_line);
            no_tabs_violations++;
        }
        return 1;
    }

    return 0;
}

static int no_tabs_finalize(const VALIDATOR_CONFIG* config)
{
    (void)config;
    return no_tabs_violations;
}

static void no_tabs_cleanup(void)
{
    no_tabs_violations = 0;
}

static const CHECK_DEFINITION check_no_tabs_def =
{
    "no_tabs",
    "Validates that source files do not contain tab characters",
    FILE_TYPE_C | FILE_TYPE_H | FILE_TYPE_CPP | FILE_TYPE_HPP | FILE_TYPE_CS | FILE_TYPE_MD,
    0,
    no_tabs_init,
    no_tabs_check_file,
    no_tabs_finalize,
    no_tabs_cleanup
};

const CHECK_DEFINITION* get_check_no_tabs(void)
{
    return &check_no_tabs_def;
}
