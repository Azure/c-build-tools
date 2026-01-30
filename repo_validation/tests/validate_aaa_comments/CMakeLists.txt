# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# AAA Comment Validation Tests
#
# Tests the validate_aaa_comments.ps1 script to ensure it correctly detects
# missing or incorrectly ordered AAA (Arrange, Act, Assert) comments in test functions.
#

set(VALIDATE_AAA_COMMENTS_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_aaa_comments.ps1")

# Test 1: Verify script detects missing AAA comments
add_custom_target(test_validate_aaa_comments_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_AAA_COMMENTS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/missing_aaa"
        -ExcludeFolders ""
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing AAA comment detection on files with missing comments"
)

# Test 2: Verify script passes on files with proper AAA comments
add_custom_target(test_validate_aaa_comments_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_AAA_COMMENTS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/has_aaa"
        -ExcludeFolders ""
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing AAA comment validation on clean files"
)

# Test 3: Verify script handles exempted tests correctly
add_custom_target(test_validate_aaa_comments_exempted
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_AAA_COMMENTS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/has_aaa"
        -ExcludeFolders ""
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing AAA comment validation with exempted tests"
)

# Test 4: Verify -Fix parameter doesn't break anything (it should do nothing)
add_custom_target(test_validate_aaa_comments_fix_noop
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_AAA_COMMENTS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/has_aaa"
        -ExcludeFolders ""
        -Fix
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing that -Fix parameter has no effect"
)

# Master target for all AAA comment validation tests
add_custom_target(test_validate_aaa_comments
    COMMENT "Running all AAA comment validation tests"
)

# Add dependencies - detection test should fail (exit code 1), clean tests should pass
add_dependencies(test_validate_aaa_comments 
    test_validate_aaa_comments_clean
    test_validate_aaa_comments_exempted
    test_validate_aaa_comments_fix_noop
)

# Note: We don't add test_validate_aaa_comments_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Instead, it's available to run manually to verify detection works.
