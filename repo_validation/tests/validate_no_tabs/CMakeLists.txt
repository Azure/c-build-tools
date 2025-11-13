# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# Tab Validation Tests
#
# Tests the validate_no_tabs.ps1 script to ensure it correctly detects tab characters
# and validates the fix functionality works properly.
#

set(VALIDATE_NO_TABS_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_no_tabs.ps1")

# Test 1: Verify script detects tabs in files that have them
add_custom_target(test_validate_no_tabs_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_NO_TABS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/has_tabs"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tab detection on files with tabs"
)

# Test 2: Verify script passes on files without tabs
add_custom_target(test_validate_no_tabs_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_NO_TABS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/no_tabs"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tab validation on clean files"
)

# Test 3: Verify fix functionality works (copy test files to temp directory first)
add_custom_target(test_validate_no_tabs_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/has_tabs" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_NO_TABS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        -Fix
    # Verify tabs were removed (script should pass now)
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_NO_TABS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tab fix functionality"
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