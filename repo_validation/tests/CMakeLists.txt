# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# Repository Validation Testing Framework
#
# This CMake file defines test targets for validating the repository validation scripts.
# Each validation script has corresponding test cases that verify correct detection of issues.
#

# Test configuration
set(POWERSHELL_EXECUTABLE "powershell.exe")
set(VALIDATION_SCRIPTS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../scripts")

# Set the validator executable name based on which validator is being used
# Child test CMakeLists should use REPO_VALIDATOR_EXE and REPO_VALIDATOR_TARGET
if(use_c_repo_validator)
    set(REPO_VALIDATOR_EXE repo_validator)
    set(REPO_VALIDATOR_TARGET repo_validator)
else()
    set(REPO_VALIDATOR_EXE "${REPO_VALIDATOR_RS_EXE}")
    set(REPO_VALIDATOR_TARGET repo_validator_rs)
endif()

# Add test targets for each validation script
add_subdirectory(validate_no_tabs)
add_subdirectory(validate_file_endings)
add_subdirectory(validate_srs_consistency)
add_subdirectory(validate_srs_uniqueness)
add_subdirectory(validate_requirements_naming)
add_subdirectory(validate_no_vld_include)
add_subdirectory(validate_enable_mocks_pattern)
add_subdirectory(validate_test_spec_tags)
add_subdirectory(validate_aaa_comments)
add_subdirectory(validate_no_backticks_in_srs)
add_subdirectory(validate_c_build_tools_ref)
add_subdirectory(validate_srs_format)

if(run_unittests)
    enable_testing()
    
    # Add each test to CTest
    add_test(NAME validate_no_tabs_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_no_tabs
    )
    
    add_test(NAME validate_file_endings_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_file_endings
    )
    
    add_test(NAME validate_srs_consistency_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_srs_consistency
    )

    add_test(NAME validate_srs_uniqueness_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_srs_uniqueness
    )

    add_test(NAME validate_requirements_naming_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_requirements_naming
    )

    add_test(NAME validate_no_vld_include_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_no_vld_include
    )

    add_test(NAME validate_enable_mocks_pattern_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_enable_mocks
    )

    add_test(NAME validate_test_spec_tags_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_test_spec_tags
    )

    add_test(NAME validate_aaa_comments_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_aaa_comments
    )

    add_test(NAME validate_no_backticks_in_srs_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_no_backticks_in_srs
    )

    add_test(NAME validate_c_build_tools_ref_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_c_build_tools_ref
    )

    add_test(NAME validate_srs_format_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_srs_format
    )
endif()