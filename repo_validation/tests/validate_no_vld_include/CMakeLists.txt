# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# VLD Include Validation Tests
#
# Tests the validate_no_vld_include.ps1 script to ensure it correctly detects
# explicit vld.h includes and validates the fix functionality works properly.
#

set(VALIDATE_NO_VLD_INCLUDE_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_no_vld_include.ps1")

# Test 1: Verify script detects vld.h includes in files that have them
add_custom_target(test_validate_no_vld_include_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_NO_VLD_INCLUDE_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/has_vld_include"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing vld.h include detection on files with vld.h includes"
)

# Test 2: Verify script passes on files without vld.h includes
add_custom_target(test_validate_no_vld_include_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_NO_VLD_INCLUDE_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/no_vld_include"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing vld.h include validation on clean files"
)

# Test 3: Verify fix functionality works (copy test files to temp directory first)
add_custom_target(test_validate_no_vld_include_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/has_vld_include" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_NO_VLD_INCLUDE_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        -Fix
    # Verify vld.h includes were removed (script should pass now)
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_NO_VLD_INCLUDE_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing vld.h include fix functionality"
)

# Test 4: Verify that #ifdef blocks with other code are preserved correctly
add_custom_target(test_validate_no_vld_include_fix_preserves_other_code
    # Create a temporary directory and copy test file
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_preserve_test"
    COMMAND ${CMAKE_COMMAND} -E copy 
        "${CMAKE_CURRENT_SOURCE_DIR}/has_vld_include/sample_with_ifdef_other_code.c" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_preserve_test/"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_NO_VLD_INCLUDE_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_preserve_test"
        -Fix
    # Compare the result with the expected file
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/temp_preserve_test/sample_with_ifdef_other_code.c"
        "${CMAKE_CURRENT_SOURCE_DIR}/has_vld_include/sample_with_ifdef_other_code_expected.c"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing that #ifdef blocks with other code are preserved"
)

# Master target for all vld include validation tests
add_custom_target(test_validate_no_vld_include
    COMMENT "Running all vld.h include validation tests"
)

# Add dependencies - detection test should fail (exit code 1), clean test should pass
add_dependencies(test_validate_no_vld_include 
    test_validate_no_vld_include_clean
    test_validate_no_vld_include_fix
    test_validate_no_vld_include_fix_preserves_other_code
)

# Note: We don't add test_validate_no_vld_include_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Instead, it's available to run manually to verify detection works.
