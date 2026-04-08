# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# SRS Backticks Validation Tests
#
# Tests the repo_validator no_backticks_in_srs check to ensure it correctly detects
# raw backticks in SRS requirements and validates the fix functionality works properly.
#

# Test 1: Verify tool detects backticks in SRS requirements (C/H files)
add_custom_target(test_validate_no_backticks_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_backticks" --check no_backticks_in_srs
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing backticks detection in C/H SRS requirements (should fail)"
    DEPENDS repo_validator_rs
)

# Test 1b: Verify tool detects backticks in C# SRS requirements
add_custom_target(test_validate_no_backticks_detection_cs
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_backticks_cs" --check no_backticks_in_srs
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing backticks detection in C# SRS requirements (should fail)"
    DEPENDS repo_validator_rs
)

# Test 2: Verify tool passes on files without backticks in SRS requirements
add_custom_target(test_validate_no_backticks_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/no_backticks" --check no_backticks_in_srs
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing backticks validation on clean files (should pass)"
    DEPENDS repo_validator_rs
)

# Test 3: Verify fix functionality works
add_custom_target(test_validate_no_backticks_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy 
        "${CMAKE_CURRENT_SOURCE_DIR}/has_backticks/sample_with_backticks.c" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test/"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check no_backticks_in_srs --fix
    # Verify fixed file now passes validation (run without --fix)
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check no_backticks_in_srs
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing backticks fix functionality"
    DEPENDS repo_validator_rs
)

# Master target for all backticks validation tests
add_custom_target(test_validate_no_backticks_in_srs
    COMMENT "Running all SRS backticks validation tests"
)

# Add dependencies - clean test and fix test should pass
add_dependencies(test_validate_no_backticks_in_srs 
    test_validate_no_backticks_clean
    test_validate_no_backticks_fix
)

# Master target for all expected-failure tests
add_custom_target(test_validate_no_backticks_in_srs_failures
    COMMENT "Running all no_backticks_in_srs failure detection tests"
)
add_dependencies(test_validate_no_backticks_in_srs_failures
    test_validate_no_backticks_detection
    test_validate_no_backticks_detection_cs
)
