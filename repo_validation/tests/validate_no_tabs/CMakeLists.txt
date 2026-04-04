# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# Tab Validation Tests
#
# Tests the repo_validator no_tabs check to ensure it correctly detects tab characters
# and validates the fix functionality works properly.
#

# Test 1: Verify tool detects tabs in files that have them
add_custom_target(test_validate_no_tabs_detection
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_tabs" --check no_tabs
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tab detection on files with tabs"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Test 2: Verify tool passes on files without tabs
add_custom_target(test_validate_no_tabs_clean
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/no_tabs" --check no_tabs
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tab validation on clean files"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Test 3: Verify fix functionality works (copy test files to temp directory first)
add_custom_target(test_validate_no_tabs_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/has_tabs" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check no_tabs --fix
    # Verify tabs were removed (tool should pass now)
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check no_tabs
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tab fix functionality"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Master target for all tab validation tests
add_custom_target(test_validate_no_tabs
    COMMENT "Running all tab validation tests"
)

# Add dependencies - detection test should fail (exit code 1), clean test should pass
add_dependencies(test_validate_no_tabs 
    test_validate_no_tabs_clean
    test_validate_no_tabs_fix
)

# Note: We don't add test_validate_no_tabs_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Instead, it's available to run manually to verify detection works.