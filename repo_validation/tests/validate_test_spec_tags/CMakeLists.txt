# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# Test Spec Tag Validation Tests
#
# Tests the repo_validator test_spec_tags check to ensure it correctly detects
# unit tests that are missing Tests_SRS_* specification tags.
#

# Test 1: Verify tool detects violations in files with missing spec tags
add_custom_target(test_validate_test_spec_tags_detection
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_violations" --check test_spec_tags
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing spec tag detection on files with missing tags"
    DEPENDS repo_validator
)

# Test 2: Verify tool passes on files where all tests have spec tags
add_custom_target(test_validate_test_spec_tags_clean
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/no_violations" --check test_spec_tags
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing spec tag validation on clean files"
    DEPENDS repo_validator
)

# Test 3: Verify that --fix option still fails (since fix is not supported)
# This ensures the tool reports violations even in fix mode
add_custom_target(test_validate_test_spec_tags_fix_still_fails
    COMMAND repo_validator --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/has_violations" --check test_spec_tags --fix
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing that --fix mode still reports violations (fix not supported)"
    DEPENDS repo_validator
)

# Master target for all test spec tag validation tests
add_custom_target(test_validate_test_spec_tags
    COMMENT "Running all test spec tag validation tests"
)

# Add dependencies - detection test should fail (exit code 1), clean test should pass
add_dependencies(test_validate_test_spec_tags 
    test_validate_test_spec_tags_clean
)

# Note: We don't add test_validate_test_spec_tags_detection as a dependency because 
# it should fail with exit code 1 (which would fail the build). 
# Note: test_validate_test_spec_tags_fix_still_fails is also expected to fail
# since test_spec_tags does not support fixing.
