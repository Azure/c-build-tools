# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# SRS Format Validation Tests
#
# Tests the repo_validator srs_format check to ensure it correctly detects
# malformed SRS requirement tag formatting in markdown files.
#
# Each violation type has its own fixture directory and detection target so
# a regression in one category cannot be masked by another.
#

# Passing test: Verify tool passes on files with properly formatted SRS tags
add_custom_target(test_validate_srs_format_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/no_violations" --check srs_format
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing srs_format validation on clean files (should pass)"
    DEPENDS repo_validator_rs
)

# Master target for all srs_format passing tests
add_custom_target(test_validate_srs_format
    COMMENT "Running all SRS format validation tests"
)
add_dependencies(test_validate_srs_format
    test_validate_srs_format_clean
)

# Detection: C-comment-style closing (]*/)
add_custom_target(test_validate_srs_format_c_comment_close
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/c_comment_close" --check srs_format
    COMMENT "Testing srs_format detection of ]*/ closing"
    DEPENDS repo_validator_rs
)

# Detection: Missing trailing ** (**] without **)
add_custom_target(test_validate_srs_format_missing_trailing_stars
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/missing_trailing_stars" --check srs_format
    COMMENT "Testing srs_format detection of missing trailing **"
    DEPENDS repo_validator_rs
)

# Detection: Missing bold opening bracket ([ without **)
add_custom_target(test_validate_srs_format_missing_bold_open
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/missing_bold_open" --check srs_format
    COMMENT "Testing srs_format detection of missing bold open"
    DEPENDS repo_validator_rs
)

# Detection: Gratuitous multi-line (blank line before **]**)
add_custom_target(test_validate_srs_format_gratuitous_multiline
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/gratuitous_multiline" --check srs_format
    COMMENT "Testing srs_format detection of gratuitous multi-line"
    DEPENDS repo_validator_rs
)

# Master target for all expected-failure detection tests
add_custom_target(test_validate_srs_format_failures
    COMMENT "Running all srs_format failure detection tests"
)
add_dependencies(test_validate_srs_format_failures
    test_validate_srs_format_c_comment_close
    test_validate_srs_format_missing_trailing_stars
    test_validate_srs_format_missing_bold_open
    test_validate_srs_format_gratuitous_multiline
)
