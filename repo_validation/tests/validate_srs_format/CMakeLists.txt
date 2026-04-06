# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# SRS Format Validation Tests
#
# Tests the repo_validator srs_format check to ensure it correctly detects
# malformed SRS requirement tag formatting in markdown files.
#

# Test 1: Verify tool detects malformed SRS tags
add_custom_target(test_validate_srs_format_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_violations" --check srs_format
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing srs_format detection in markdown files (should fail)"
    DEPENDS repo_validator_rs
)

# Test 2: Verify tool passes on files with properly formatted SRS tags
add_custom_target(test_validate_srs_format_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/no_violations" --check srs_format
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing srs_format validation on clean files (should pass)"
    DEPENDS repo_validator_rs
)

# Master target for all srs_format validation tests
add_custom_target(test_validate_srs_format
    COMMENT "Running all SRS format validation tests"
)

# Add dependencies - clean test should pass
add_dependencies(test_validate_srs_format
    test_validate_srs_format_clean
)

# Master target for all expected-failure tests
add_custom_target(test_validate_srs_format_failures
    COMMENT "Running all srs_format failure detection tests"
)
add_dependencies(test_validate_srs_format_failures
    test_validate_srs_format_detection
)
