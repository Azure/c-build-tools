# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# File Endings Validation Tests
#
# Tests the repo_validator file_endings check to ensure it correctly detects files
# without proper CRLF endings and validates the fix functionality works properly.
#

# Test 1: Verify tool detects missing CRLF endings
add_custom_target(test_validate_file_endings_detection
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/missing_crlf" --check file_endings
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing file ending detection on files missing CRLF"
    DEPENDS repo_validator
)

# Test 2: Verify tool passes on files with proper endings
add_custom_target(test_validate_file_endings_clean
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/proper_crlf" --check file_endings
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing file ending validation on files with proper CRLF"
    DEPENDS repo_validator
)

# Test 3: Verify fix functionality works
add_custom_target(test_validate_file_endings_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory 
        "${CMAKE_CURRENT_SOURCE_DIR}/missing_crlf" 
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the tool with fix mode
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check file_endings --fix
    # Verify CRLF endings were added (tool should pass now)
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check file_endings
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing file ending fix functionality"
    DEPENDS repo_validator
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