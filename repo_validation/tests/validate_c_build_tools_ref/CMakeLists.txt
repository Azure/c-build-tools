# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# c-build-tools Ref Validation Tests
#
# Tests that Azure DevOps pipeline refs and GitHub Actions uses refs match the
# repository's c-build-tools submodule SHA.
#

set(TEST_SHA "aabbccdd00112233445566778899aabbccddeeff")

add_custom_target(test_validate_c_build_tools_ref_clean_sha
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/valid_sha_ref"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing matching Azure DevOps c-build-tools SHA"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_no_submodule_no_ref
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/no_submodule_no_ref"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing repo without c-build-tools submodule or references"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_clean_github
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/valid_github_refs"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing matching GitHub Actions c-build-tools refs"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_branch_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/invalid_branch_ref"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing branch ref detection"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_missing_submodule_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/missing_submodule"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing c-build-tools reference without submodule"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/invalid_sha_ref"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing mismatched Azure DevOps SHA detection"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_github_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/invalid_github_refs"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing invalid GitHub Actions ref detection"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_fix
    COMMAND ${CMAKE_COMMAND} -E remove_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/invalid_sha_ref"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}" --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing Azure DevOps ref fix"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_github_fix
    COMMAND ${CMAKE_COMMAND} -E remove_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_github_fix_test"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_github_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/invalid_github_refs"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_github_fix_test"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_github_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}" --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_github_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing GitHub Actions uses ref fixes"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_multiple_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/multiple_files"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing multiple mismatched c-build-tools refs"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_c_build_tools_ref_multiple_fix
    COMMAND ${CMAKE_COMMAND} -E remove_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/multiple_files"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}" --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_multi_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing multiple c-build-tools ref fixes"
    DEPENDS repo_validator_rs
)

if(WIN32)
    find_program(POWERSHELL_EXECUTABLE NAMES pwsh powershell REQUIRED)
    add_custom_target(test_update_c_build_tools_github_refs
        COMMAND "${POWERSHELL_EXECUTABLE}" -NoLogo -NoProfile -NonInteractive
            -ExecutionPolicy Bypass -File
            "${CMAKE_CURRENT_LIST_DIR}/../../../update_deps/tests/test_update_c_build_tools_github_refs.ps1"
        COMMENT "Testing propagation updates GitHub Actions c-build-tools refs"
    )
endif()

add_custom_target(test_validate_c_build_tools_ref
    COMMENT "Running all c-build-tools ref validation tests"
)

add_dependencies(test_validate_c_build_tools_ref
    test_validate_c_build_tools_ref_clean_sha
    test_validate_c_build_tools_ref_no_submodule_no_ref
    test_validate_c_build_tools_ref_clean_github
    test_validate_c_build_tools_ref_fix
    test_validate_c_build_tools_ref_github_fix
    test_validate_c_build_tools_ref_multiple_fix
)

if(TARGET test_update_c_build_tools_github_refs)
    add_dependencies(test_validate_c_build_tools_ref test_update_c_build_tools_github_refs)
endif()

add_custom_target(test_validate_c_build_tools_ref_failures
    COMMENT "Running all c_build_tools_ref failure detection tests"
)
add_dependencies(test_validate_c_build_tools_ref_failures
    test_validate_c_build_tools_ref_branch_detection
    test_validate_c_build_tools_ref_missing_submodule_detection
    test_validate_c_build_tools_ref_detection
    test_validate_c_build_tools_ref_github_detection
    test_validate_c_build_tools_ref_multiple_detection
)
