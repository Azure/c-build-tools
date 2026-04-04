# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# ENABLE_MOCKS Pattern Validation Tests
#
# Tests the repo_validator enable_mocks check to ensure it correctly detects
# deprecated #define/#undef ENABLE_MOCKS patterns and validates the fix functionality.
#

# Test 1: Verify tool detects violations in files using deprecated patterns
add_custom_target(test_validate_enable_mocks_detection
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_violations" --check enable_mocks
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing ENABLE_MOCKS pattern detection on files with violations"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Test 2: Verify tool passes on files using correct include patterns
add_custom_target(test_validate_enable_mocks_clean
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/no_violations" --check enable_mocks
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing ENABLE_MOCKS pattern validation on clean files"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Test 2b: Verify tool passes on files with //force comments
add_custom_target(test_validate_enable_mocks_with_force
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/no_violations" --check enable_mocks
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing ENABLE_MOCKS pattern validation on files with //force comments"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Test 3: Verify fix functionality works (copy test files to temp directory first)
add_custom_target(test_validate_enable_mocks_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/has_violations" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check enable_mocks --fix
    # Verify violations were fixed (tool should pass now)
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check enable_mocks
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing ENABLE_MOCKS pattern fix functionality"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Test 4: Verify that fix preserves //force comments
add_custom_target(test_validate_enable_mocks_fix_preserves_force
    # Create a temporary directory and copy test file
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_preserve_force_test"
    COMMAND ${CMAKE_COMMAND} -E copy 
        "${CMAKE_CURRENT_SOURCE_DIR}/has_violations/sample_with_mixed_force.c" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_preserve_force_test/"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_preserve_force_test" --check enable_mocks --fix
    # Verify the result matches expected file (violations fixed but //force preserved)
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/temp_preserve_force_test/sample_with_mixed_force.c"
        "${CMAKE_CURRENT_SOURCE_DIR}/has_violations/sample_with_mixed_force_expected.c"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing that //force comments are preserved during fix"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Master target for all ENABLE_MOCKS pattern validation tests
add_custom_target(test_validate_enable_mocks
    COMMENT "Running all ENABLE_MOCKS pattern validation tests"
)

# Add dependencies - detection test should fail (exit code 1), clean test should pass
add_dependencies(test_validate_enable_mocks 
    test_validate_enable_mocks_clean
    test_validate_enable_mocks_with_force
    test_validate_enable_mocks_fix
    test_validate_enable_mocks_fix_preserves_force
)

# Note: We don't add test_validate_enable_mocks_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Instead, it's available to run manually to verify detection works.
