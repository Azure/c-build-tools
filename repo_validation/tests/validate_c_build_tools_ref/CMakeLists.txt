# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

set(TEST_SHA "aabbccdd00112233445566778899aabbccddeeff")

add_custom_target(test_validate_c_build_tools_ref
    COMMENT "Running c-build-tools GitHub Actions ref validation tests"
)
add_custom_target(test_validate_c_build_tools_ref_failures
    COMMENT "Running expected-failure c-build-tools ref detection tests"
)

# Azure DevOps resource refs are intentionally outside this check's scope.
foreach(FIXTURE valid_sha_ref invalid_sha_ref invalid_branch_ref multiple_files no_submodule_no_ref valid_github_refs)
    add_custom_target(test_validate_c_build_tools_ref_clean_${FIXTURE}
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/${FIXTURE}"
            --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
        DEPENDS repo_validator_rs
        VERBATIM
    )
    add_dependencies(test_validate_c_build_tools_ref test_validate_c_build_tools_ref_clean_${FIXTURE})
endforeach()

foreach(FIXTURE invalid_github_refs missing_submodule)
    add_custom_target(test_validate_c_build_tools_ref_${FIXTURE}_detection
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/${FIXTURE}"
            --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
        DEPENDS repo_validator_rs
        VERBATIM
    )
    add_dependencies(test_validate_c_build_tools_ref_failures test_validate_c_build_tools_ref_${FIXTURE}_detection)
    add_test(NAME validate_c_build_tools_ref_${FIXTURE}_detection
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/${FIXTURE}"
            --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    )
    set_tests_properties(validate_c_build_tools_ref_${FIXTURE}_detection PROPERTIES WILL_FAIL TRUE)
endforeach()

add_custom_target(test_validate_c_build_tools_ref_unit
    COMMAND "${CARGO_EXECUTABLE}" test --manifest-path "${CMAKE_CURRENT_LIST_DIR}/../../src_rust/Cargo.toml"
        c_build_tools_ref
    DEPENDS repo_validator_rs
    VERBATIM
)
add_dependencies(test_validate_c_build_tools_ref test_validate_c_build_tools_ref_unit)

add_custom_target(test_validate_c_build_tools_ref_fix
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${CMAKE_CURRENT_BINARY_DIR}/temp_github_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/invalid_github_refs"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_github_fix_test"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_github_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}" --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_github_fix_test"
        --check c_build_tools_ref --submodule-sha "${TEST_SHA}"
    DEPENDS repo_validator_rs
    VERBATIM
)
add_dependencies(test_validate_c_build_tools_ref test_validate_c_build_tools_ref_fix)

find_program(POWERSHELL_EXECUTABLE NAMES pwsh)
if(POWERSHELL_EXECUTABLE)
    add_custom_target(test_update_c_build_tools_github_refs
        COMMAND "${POWERSHELL_EXECUTABLE}" -NoLogo -NoProfile -NonInteractive
            -ExecutionPolicy Bypass -Command
            "& '${CMAKE_CURRENT_LIST_DIR}/../../../update_deps/tests/test_update_c_build_tools_github_refs.ps1' -ValidatorExe '${REPO_VALIDATOR_RS_EXE}'"
        DEPENDS repo_validator_rs
        COMMENT "Testing real gitlink validation and propagated GitHub Actions pins"
        VERBATIM
    )
    add_dependencies(test_validate_c_build_tools_ref test_update_c_build_tools_github_refs)
endif()
