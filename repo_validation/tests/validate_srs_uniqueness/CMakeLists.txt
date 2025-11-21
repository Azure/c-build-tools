# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# SRS Uniqueness Validation Tests
#
# Tests the validate_srs_uniqueness.ps1 script to ensure it correctly detects
# duplicate SRS tags across requirement documents and validates the error functionality.
#

set(VALIDATE_SRS_UNIQUENESS_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_srs_uniqueness.ps1")

# Test 1: Verify script passes on unique SRS tags
add_custom_target(test_validate_srs_uniqueness_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_UNIQUENESS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/unique_srs"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS uniqueness validation on unique SRS tags"
)

# Test 2: Verify script detects duplicate SRS tags (this should fail)
add_custom_target(test_validate_srs_uniqueness_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_UNIQUENESS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/duplicate_srs"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS uniqueness detection on duplicate SRS tags (should fail)"
)

# Test 3: Verify script ignores -Fix parameter and still reports errors
add_custom_target(test_validate_srs_uniqueness_no_fix
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_UNIQUENESS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/duplicate_srs"
        -Fix
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS uniqueness script ignores -Fix parameter (should still fail)"
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