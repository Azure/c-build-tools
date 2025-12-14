# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# Test Spec Tag Validation Tests
#
# Tests the validate_test_spec_tags.ps1 script to ensure it correctly detects
# unit tests that are missing Tests_SRS_* specification tags.
#

set(VALIDATE_TEST_SPEC_TAGS_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_test_spec_tags.ps1")

# Test 1: Verify script detects violations in files with missing spec tags
add_custom_target(test_validate_test_spec_tags_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_TEST_SPEC_TAGS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/has_violations"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing spec tag detection on files with missing tags"
)

# Test 2: Verify script passes on files where all tests have spec tags
add_custom_target(test_validate_test_spec_tags_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_TEST_SPEC_TAGS_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/no_violations"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing spec tag validation on clean files"
)

# Test 3: Verify that -Fix option still fails (since fix is not supported)
# This ensures the script reports violations even in fix mode
add_custom_target(test_validate_test_spec_tags_fix_still_fails
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -Command "& { & '${VALIDATE_TEST_SPEC_TAGS_SCRIPT}' -RepoRoot '${CMAKE_CURRENT_SOURCE_DIR}/has_violations' -Fix; if ($$LASTEXITCODE -eq 0) { exit 1 } else { exit 0 } }"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing that -Fix mode still reports violations (fix not supported)"
)

# Master target for all test spec tag validation tests
add_custom_target(test_validate_test_spec_tags
    COMMENT "Running all test spec tag validation tests"
)

# Add dependencies - detection test should fail (exit code 1), clean test should pass
add_dependencies(test_validate_test_spec_tags 
    test_validate_test_spec_tags_clean
    test_validate_test_spec_tags_fix_still_fails
)

# Note: We don't add test_validate_test_spec_tags_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Instead, it's available to run manually to verify detection works.
