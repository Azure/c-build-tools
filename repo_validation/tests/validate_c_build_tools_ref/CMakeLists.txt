# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# c-build-tools Ref Validation Tests
#
# Tests the validate_c_build_tools_ref.ps1 script to ensure it correctly validates
# that pipeline YAML files reference the correct c-build-tools commit SHA or master.
#
# Test SHA used across test data: aabbccdd00112233445566778899aabbccddeeff
#

set(VALIDATE_CBT_REF_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_c_build_tools_ref.ps1")
set(TEST_SHA "aabbccdd00112233445566778899aabbccddeeff")

# Test 1: Verify script passes when ref is refs/heads/master
add_custom_target(test_validate_c_build_tools_ref_clean_master
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_CBT_REF_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/valid_master_ref"
        -SubmoduleSha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref validation with refs/heads/master (should pass)"
)

# Test 2: Verify script passes when ref matches the submodule SHA
add_custom_target(test_validate_c_build_tools_ref_clean_sha
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_CBT_REF_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/valid_sha_ref"
        -SubmoduleSha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref validation with matching SHA (should pass)"
)

# Test 3: Verify script passes (skips) when there is no c-build-tools submodule
add_custom_target(test_validate_c_build_tools_ref_no_submodule
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_CBT_REF_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/no_submodule"
        -SubmoduleSha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref validation with no submodule (should skip/pass)"
)

# Test 4: Verify script detects invalid SHA ref (exit code 1)
add_custom_target(test_validate_c_build_tools_ref_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_CBT_REF_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/invalid_sha_ref"
        -SubmoduleSha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref detection of invalid SHA (should fail)"
)

# Test 5: Verify fix functionality works (copy test files to temp directory first)
add_custom_target(test_validate_c_build_tools_ref_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/invalid_sha_ref"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_CBT_REF_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        -SubmoduleSha "${TEST_SHA}"
        -Fix
    # Verify the fix worked (script should pass now)
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_CBT_REF_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        -SubmoduleSha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref fix functionality"
)

# Test 6: Verify script handles multiple files correctly (mix of valid and invalid)
# multiple_files/ has: devops_gated.yml (master=valid), devops_gated_docs.yml (correct SHA=valid),
# devops_gated_passthrough.yml (wrong SHA=invalid) → should FAIL overall
add_custom_target(test_validate_c_build_tools_ref_multiple_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_CBT_REF_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/multiple_files"
        -SubmoduleSha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref validation with multiple files (should fail on wrong SHA)"
)

# Test 7: Verify fix on multiple files only fixes the invalid one
add_custom_target(test_validate_c_build_tools_ref_multiple_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/multiple_files"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_CBT_REF_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
        -SubmoduleSha "${TEST_SHA}"
        -Fix
    # Verify the fix worked (script should pass now)
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_CBT_REF_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
        -SubmoduleSha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools ref fix on multiple files"
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

# Note: test_validate_c_build_tools_ref_detection and test_validate_c_build_tools_ref_multiple_detection
# are not added as dependencies because they should fail with exit code 1 (which would fail the build).
# They are available to run manually to verify detection works.
