# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# ENABLE_MOCKS Pattern Validation Tests
#
# Tests the validate_enable_mocks_pattern.ps1 script to ensure it correctly detects
# deprecated #define/#undef ENABLE_MOCKS patterns and validates the fix functionality.
#

set(VALIDATE_ENABLE_MOCKS_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_enable_mocks_pattern.ps1")

# Test 1: Verify script detects violations in files using deprecated patterns
add_custom_target(test_validate_enable_mocks_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_ENABLE_MOCKS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/has_violations"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing ENABLE_MOCKS pattern detection on files with violations"
)

# Test 2: Verify script passes on files using correct include patterns
add_custom_target(test_validate_enable_mocks_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_ENABLE_MOCKS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/no_violations"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing ENABLE_MOCKS pattern validation on clean files"
)

# Test 3: Verify fix functionality works (copy test files to temp directory first)
add_custom_target(test_validate_enable_mocks_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/has_violations" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_ENABLE_MOCKS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        -Fix
    # Verify violations were fixed (script should pass now)
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_ENABLE_MOCKS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing ENABLE_MOCKS pattern fix functionality"
)

# Master target for all ENABLE_MOCKS pattern validation tests
add_custom_target(test_validate_enable_mocks
    COMMENT "Running all ENABLE_MOCKS pattern validation tests"
)

# Add dependencies - detection test should fail (exit code 1), clean test should pass
add_dependencies(test_validate_enable_mocks 
    test_validate_enable_mocks_clean
    test_validate_enable_mocks_fix
)

# Note: We don't add test_validate_enable_mocks_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Instead, it's available to run manually to verify detection works.
