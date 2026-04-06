# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# c-build-tools Ref Validation Tests
#
# Tests the repo_validator_rs c_build_tools_ref check to ensure it correctly validates
# that pipeline YAML files reference the correct c-build-tools commit SHA or master.
#
# Test SHA used across test data: aabbccdd00112233445566778899aabbccddeeff
#

set(TEST_SHA "aabbccdd00112233445566778899aabbccddeeff")

# Test 1: Verify tool passes when ref is refs/heads/master
add_custom_target(test_validate_c_build_tools_ref_clean_master
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/valid_master_ref"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref validation with refs/heads/master (should pass)"
    DEPENDS repo_validator_rs
)

# Test 2: Verify tool passes when ref matches the submodule SHA
add_custom_target(test_validate_c_build_tools_ref_clean_sha
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/valid_sha_ref"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref validation with matching SHA (should pass)"
    DEPENDS repo_validator_rs
)

# Test 3: Verify tool passes (skips) when there is no c-build-tools submodule
add_custom_target(test_validate_c_build_tools_ref_no_submodule
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/no_submodule"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref validation with no submodule (should skip/pass)"
    DEPENDS repo_validator_rs
)

# Test 4: Verify tool detects invalid SHA ref (exit code 1)
add_custom_target(test_validate_c_build_tools_ref_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/invalid_sha_ref"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref detection of invalid SHA (should fail)"
    DEPENDS repo_validator_rs
)

# Test 5: Verify fix functionality works (copy test files to temp directory first)
add_custom_target(test_validate_c_build_tools_ref_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/invalid_sha_ref"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}" --fix
    # Verify the fix worked (tool should pass now)
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref fix functionality"
    DEPENDS repo_validator_rs
)

# Test 6: Verify tool handles multiple files correctly (mix of valid and invalid)
# multiple_files/ has: devops_gated.yml (master=valid), devops_gated_docs.yml (correct SHA=valid),
# devops_gated_passthrough.yml (wrong SHA=invalid) → should FAIL overall
add_custom_target(test_validate_c_build_tools_ref_multiple_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/multiple_files"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref validation with multiple files (should fail on wrong SHA)"
    DEPENDS repo_validator_rs
)

# Test 7: Verify fix on multiple files only fixes the invalid one
add_custom_target(test_validate_c_build_tools_ref_multiple_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/multiple_files"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}" --fix
    # Verify the fix worked (tool should pass now)
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref fix on multiple files"
    DEPENDS repo_validator_rs
)

# Master target for all c-build-tools ref validation tests
add_custom_target(test_validate_c_build_tools_ref
    COMMENT "Running all c-build-tools ref validation tests"
)

# Add dependencies - detection tests should fail (exit code 1), so not included as dependencies
add_dependencies(test_validate_c_build_tools_ref
    test_validate_c_build_tools_ref_clean_master
    test_validate_c_build_tools_ref_clean_sha
    test_validate_c_build_tools_ref_no_submodule
    test_validate_c_build_tools_ref_fix
    test_validate_c_build_tools_ref_multiple_fix
)

# Master target for all expected-failure tests
add_custom_target(test_validate_c_build_tools_ref_failures
    COMMENT "Running all c_build_tools_ref failure detection tests"
)
add_dependencies(test_validate_c_build_tools_ref_failures
    test_validate_c_build_tools_ref_detection
    test_validate_c_build_tools_ref_multiple_detection
)
