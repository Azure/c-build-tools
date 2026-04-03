#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

cmake_minimum_required(VERSION 3.18)

# Build the repo_validator executable when validation is enabled
if(run_repo_validation)
    add_subdirectory(src)
endif()

# Function to add repository validation target
# This function creates a custom target that runs validation scripts on the repository
# ONLY when called from a top-level repository (not from submodules/dependencies).
#
# Usage:
#   add_repo_validation(<project_name> [EXCLUDE_FOLDERS <folder1> <folder2> ...])
#
# Arguments:
#   project_name - The name of the project (used to create a unique target name)
#   EXCLUDE_FOLDERS - Optional list of directories to exclude from validation (default: cmake deps)
#
# CMake Options:
#   run_repo_validation - Set to ON to enable the validation target (default is OFF)
#   fix_repo_validation_errors - Set to ON to automatically fix validation errors (default is OFF)
#
# The function will create a target named <project_name>_repo_validation that runs
# the compiled repo_validator tool or falls back to PowerShell validation scripts
# for checks not yet migrated to the C tool.
# If fix_repo_validation_errors is ON, the tool will be called with --fix argument.
#
# Note: 
#   - The validation target is only created when this function is called from the top-level
#     repository (CMAKE_CURRENT_SOURCE_DIR == CMAKE_SOURCE_DIR). This prevents validation
#     targets from being created for dependencies/submodules.
#   - Validation scripts automatically exclude dependency directories (deps/, dependencies/)
#     to avoid modifying third-party code.
#
function(add_repo_validation project_name)
    # Parse optional arguments
    set(options "")
    set(oneValueArgs "")
    set(multiValueArgs EXCLUDE_FOLDERS)
    cmake_parse_arguments(REPO_VAL "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})
    
    # Set default exclude folders if not specified
    if(NOT REPO_VAL_EXCLUDE_FOLDERS)
        set(REPO_VAL_EXCLUDE_FOLDERS "cmake" "deps")
    endif()
    
    # Check if this is a top-level repository (not a submodule)
    # Only add the validation target if called from the top-level repo
    if(NOT "${CMAKE_CURRENT_SOURCE_DIR}" STREQUAL "${CMAKE_SOURCE_DIR}")
        return()
    endif()
    
    # Check if repo validation is enabled
    if(NOT run_repo_validation)
        message(STATUS "Repository validation disabled (run_repo_validation=OFF)")
        return()
    endif()
    
    # Get the absolute path to the validation scripts directory
    set(VALIDATION_SCRIPTS_DIR "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/scripts")
    
    # Get the repository root (assuming this is called from a project that includes c-build-tools)
    get_filename_component(REPO_ROOT "${CMAKE_SOURCE_DIR}" ABSOLUTE)
    
    # Create a list to hold all validation script commands
    set(VALIDATION_COMMANDS "")
    
    # Determine if we should fix errors
    set(FIX_ARG "")
    set(FIX_ARG_C "")
    if(fix_repo_validation_errors)
        set(FIX_ARG "-Fix")
        set(FIX_ARG_C "--fix")
        message(STATUS "Repository validation will attempt to fix errors (fix_repo_validation_errors=ON)")
    endif()
    
    # Build the exclude folders argument as comma-separated list
    string(REPLACE ";" "," EXCLUDE_FOLDERS_LIST "${REPO_VAL_EXCLUDE_FOLDERS}")

    # Checks migrated to compiled C tool (Phase 1 + Phase 2)
    set(C_CHECKS "no_tabs;file_endings;requirements_naming;srs_uniqueness;enable_mocks;no_vld_include;no_backticks_in_srs;test_spec_tags;aaa_comments;srs_consistency;srs_format")

    # Add compiled validator command for migrated checks
    list(APPEND VALIDATION_COMMANDS
        COMMAND ${CMAKE_COMMAND} -E echo "Running compiled validator (${C_CHECKS})"
        COMMAND repo_validator --repo-root "${REPO_ROOT}" --exclude-folders "${EXCLUDE_FOLDERS_LIST}" ${FIX_ARG_C}
            --check no_tabs --check file_endings --check requirements_naming --check srs_uniqueness
            --check enable_mocks --check no_vld_include --check no_backticks_in_srs --check test_spec_tags
            --check aaa_comments --check srs_consistency --check srs_format
    )

    # Find PowerShell validation scripts that have NOT been migrated
    file(GLOB VALIDATION_SCRIPTS "${VALIDATION_SCRIPTS_DIR}/*.ps1")

    # Scripts migrated to C - exclude from PowerShell execution
    set(MIGRATED_SCRIPTS
        "validate_no_tabs.ps1"
        "validate_file_endings.ps1"
        "validate_requirements_naming.ps1"
        "validate_srs_uniqueness.ps1"
        "validate_enable_mocks_pattern.ps1"
        "validate_no_vld_include.ps1"
        "validate_no_backticks_in_srs.ps1"
        "validate_test_spec_tags.ps1"
        "validate_aaa_comments.ps1"
        "validate_srs_consistency.ps1"
    )

    # Build the command list for remaining PowerShell scripts
    foreach(SCRIPT ${VALIDATION_SCRIPTS})
        get_filename_component(SCRIPT_NAME ${SCRIPT} NAME)
        
        # Skip scripts that have been migrated to C
        list(FIND MIGRATED_SCRIPTS "${SCRIPT_NAME}" MIGRATED_INDEX)
        if(MIGRATED_INDEX GREATER -1)
            continue()
        endif()

        list(APPEND VALIDATION_COMMANDS
            COMMAND ${CMAKE_COMMAND} -E echo "Running validation: ${SCRIPT_NAME}"
            COMMAND powershell -ExecutionPolicy Bypass -File "${SCRIPT}" -RepoRoot "${REPO_ROOT}" -ExcludeFolders "${EXCLUDE_FOLDERS_LIST}" ${FIX_ARG}
        )
    endforeach()
    
    # Create the validation target
    add_custom_target(${project_name}_repo_validation ALL
        ${VALIDATION_COMMANDS}
        WORKING_DIRECTORY ${REPO_ROOT}
        COMMENT "Running repository validation for ${project_name}"
        DEPENDS repo_validator
        VERBATIM
    )
    
    # Add a message to indicate the target was created
    message(STATUS "Added repository validation target: ${project_name}_repo_validation (excluding: ${REPO_VAL_EXCLUDE_FOLDERS})")
endfunction()

# Include testing framework if tests directory exists and testing is enabled
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/tests" AND run_unittests AND run_repo_validation)
    add_subdirectory(tests)
endif()

# Build Rust repo_validator_rs and its tests when enabled
option(run_repo_validation_rust "Build and test Rust repo_validator_rs alongside C version (default is OFF)" OFF)
if(run_repo_validation_rust AND run_repo_validation)
    add_subdirectory(src_rust)
    if(run_unittests)
        add_subdirectory(tests_rust)
    endif()
endif()
