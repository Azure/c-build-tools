# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# File Endings Validation Tests
#
# Tests the validate_file_endings.ps1 script to ensure it correctly detects files
# without proper CRLF endings and validates the fix functionality works properly.
#

set(VALIDATE_FILE_ENDINGS_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_file_endings.ps1")

# Test 1: Verify script detects missing CRLF endings
add_custom_target(test_validate_file_endings_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_FILE_ENDINGS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/missing_crlf"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing file ending detection on files missing CRLF"
)

# Test 2: Verify script passes on files with proper endings
add_custom_target(test_validate_file_endings_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_FILE_ENDINGS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/proper_crlf"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing file ending validation on files with proper CRLF"
)

# Test 3: Verify fix functionality works
add_custom_target(test_validate_file_endings_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/missing_crlf" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_FILE_ENDINGS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        -Fix
    # Verify CRLF endings were added (script should pass now)
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_FILE_ENDINGS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing file ending fix functionality"
)

# Master target for all file ending validation tests
add_custom_target(test_validate_file_endings
    COMMENT "Running all file ending validation tests"
)

# Add dependencies - clean test should pass, fix test validates fix functionality
add_dependencies(test_validate_file_endings 
    test_validate_file_endings_clean
    test_validate_file_endings_fix
)

# Note: We don't add test_validate_file_endings_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Instead, it's available to run manually to verify detection works.