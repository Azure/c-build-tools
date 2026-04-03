#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

cmake_minimum_required(VERSION 3.18)

add_executable(repo_validator
    main.c
    file_walker.c
    checks/check_no_tabs.c
    checks/check_file_endings.c
    checks/check_requirements_naming.c
    checks/check_srs_uniqueness.c
    checks/check_enable_mocks.c
    checks/check_no_vld_include.c
    checks/check_no_backticks_in_srs.c
    checks/check_test_spec_tags.c
    checks/check_aaa_comments.c
    checks/check_srs_consistency.c
)

target_include_directories(repo_validator PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_compile_definitions(repo_validator PRIVATE
    $<$<C_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
)

# Suppress specific warnings for this utility tool
if(MSVC)
    target_compile_options(repo_validator PRIVATE /W4)
else()
    target_compile_options(repo_validator PRIVATE -Wall -Wextra -Werror)
endif()
