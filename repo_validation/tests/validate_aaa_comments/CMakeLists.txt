# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# AAA Comment Validation Tests
#
# Tests the repo_validator aaa_comments check to ensure it correctly detects
# missing or incorrectly ordered AAA (Arrange, Act, Assert) comments in test functions.
#

# Test 1: Verify tool detects missing AAA comments
add_custom_target(test_validate_aaa_comments_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/missing_aaa" --check aaa_comments
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing AAA comment detection on files with missing comments"
    DEPENDS repo_validator_rs
)

# Test 2: Verify tool passes on files with proper AAA comments
add_custom_target(test_validate_aaa_comments_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_aaa" --check aaa_comments
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing AAA comment validation on clean files"
    DEPENDS repo_validator_rs
)

# Test 3: Verify tool handles exempted tests correctly
add_custom_target(test_validate_aaa_comments_exempted
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_aaa" --check aaa_comments
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing AAA comment validation with exempted tests"
    DEPENDS repo_validator_rs
)

# Test 4: Verify --fix parameter doesn't break anything (it should do nothing)
add_custom_target(test_validate_aaa_comments_fix_noop
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_aaa" --check aaa_comments --fix
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing that --fix parameter has no effect"
    DEPENDS repo_validator_rs
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

# Test 5: Verify tool detects missing AAA in PARAMETERIZED_TEST_FUNCTION
add_custom_target(test_validate_aaa_comments_parameterized_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/missing_aaa_parameterized" --check aaa_comments
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing AAA comment detection on parameterized tests with missing comments"
    DEPENDS repo_validator_rs
)

# Master target for all expected-failure tests
add_custom_target(test_validate_aaa_comments_failures
    COMMENT "Running all aaa_comments failure detection tests"
)
add_dependencies(test_validate_aaa_comments_failures
    test_validate_aaa_comments_detection
    test_validate_aaa_comments_parameterized_detection
)
