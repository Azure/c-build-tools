# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# SRS Uniqueness Validation Tests
#
# Tests the repo_validator srs_uniqueness check to ensure it correctly detects
# duplicate SRS tags across requirement documents.
#

# Test 1: Verify tool passes on unique SRS tags
add_custom_target(test_validate_srs_uniqueness_clean
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/unique_srs" --check srs_uniqueness
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS uniqueness validation on unique SRS tags"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Test 2: Verify tool detects duplicate SRS tags (this should fail)
add_custom_target(test_validate_srs_uniqueness_detection
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/duplicate_srs" --check srs_uniqueness
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS uniqueness detection on duplicate SRS tags (should fail)"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Test 3: Verify tool ignores --fix parameter and still reports errors
add_custom_target(test_validate_srs_uniqueness_no_fix
    COMMAND "${REPO_VALIDATOR_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/duplicate_srs" --check srs_uniqueness --fix
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS uniqueness tool ignores --fix parameter (should still fail)"
    DEPENDS ${REPO_VALIDATOR_TARGET}
)

# Master target for all SRS uniqueness validation tests
add_custom_target(test_validate_srs_uniqueness
    COMMENT "Running SRS uniqueness validation tests"
)

# Add dependencies - only the clean test should pass
add_dependencies(test_validate_srs_uniqueness
    test_validate_srs_uniqueness_clean
)

# Note: We don't add test_validate_srs_uniqueness_detection and test_validate_srs_uniqueness_no_fix
# as dependencies because they should fail with exit code 1 (which would fail the build).
# Instead, they are available to run manually to verify detection works.