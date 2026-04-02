#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# Rust Repository Validator Tests
#
# Runs the same test fixtures as the C tests but using the Rust repo_validator_rs binary.
# Test fixture directories are shared (repo_validation/tests/validate_*/).
#

# Path to shared test fixtures (same data used by C tests)
set(TEST_FIXTURES_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../tests")

# The Rust executable path is set by src_rust/CMakeLists.txt
# REPO_VALIDATOR_RS_EXE is set in parent scope by src_rust/CMakeLists.txt

# ============================================================
# no_tabs
# ============================================================
add_custom_target(test_validate_no_tabs_rs_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${TEST_FIXTURES_DIR}/validate_no_tabs/no_tabs" --check no_tabs
    COMMENT "[Rust] Testing no_tabs on clean files"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_no_tabs_rs_fix
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/no_tabs_fix"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${TEST_FIXTURES_DIR}/validate_no_tabs/has_tabs"
        "${CMAKE_CURRENT_BINARY_DIR}/no_tabs_fix"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/no_tabs_fix" --check no_tabs --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/no_tabs_fix" --check no_tabs
    COMMENT "[Rust] Testing no_tabs fix"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_no_tabs_rs
    COMMENT "[Rust] Running all no_tabs tests"
)
add_dependencies(test_validate_no_tabs_rs
    test_validate_no_tabs_rs_clean
    test_validate_no_tabs_rs_fix
)

# ============================================================
# file_endings
# ============================================================
add_custom_target(test_validate_file_endings_rs_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${TEST_FIXTURES_DIR}/validate_file_endings/proper_crlf" --check file_endings
    COMMENT "[Rust] Testing file_endings on clean files"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_file_endings_rs_fix
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/file_endings_fix"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${TEST_FIXTURES_DIR}/validate_file_endings/missing_crlf"
        "${CMAKE_CURRENT_BINARY_DIR}/file_endings_fix"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/file_endings_fix" --check file_endings --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/file_endings_fix" --check file_endings
    COMMENT "[Rust] Testing file_endings fix"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_file_endings_rs
    COMMENT "[Rust] Running all file_endings tests"
)
add_dependencies(test_validate_file_endings_rs
    test_validate_file_endings_rs_clean
    test_validate_file_endings_rs_fix
)

# ============================================================
# requirements_naming
# ============================================================
add_custom_target(test_validate_requirements_naming_rs_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${TEST_FIXTURES_DIR}/validate_requirements_naming/correct_naming" --check requirements_naming
    COMMENT "[Rust] Testing requirements_naming on clean files"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_requirements_naming_rs_fix
    COMMAND ${CMAKE_COMMAND} -E remove_directory "${CMAKE_CURRENT_BINARY_DIR}/requirements_naming_fix"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/requirements_naming_fix"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${TEST_FIXTURES_DIR}/validate_requirements_naming/incorrect_naming"
        "${CMAKE_CURRENT_BINARY_DIR}/requirements_naming_fix"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/requirements_naming_fix" --check requirements_naming --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/requirements_naming_fix" --check requirements_naming
    COMMENT "[Rust] Testing requirements_naming fix"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_requirements_naming_rs
    COMMENT "[Rust] Running all requirements_naming tests"
)
add_dependencies(test_validate_requirements_naming_rs
    test_validate_requirements_naming_rs_clean
    test_validate_requirements_naming_rs_fix
)

# ============================================================
# srs_uniqueness
# ============================================================
add_custom_target(test_validate_srs_uniqueness_rs_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${TEST_FIXTURES_DIR}/validate_srs_uniqueness/unique_srs" --check srs_uniqueness
    COMMENT "[Rust] Testing srs_uniqueness on unique tags"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_srs_uniqueness_rs
    COMMENT "[Rust] Running all srs_uniqueness tests"
)
add_dependencies(test_validate_srs_uniqueness_rs
    test_validate_srs_uniqueness_rs_clean
)

# ============================================================
# enable_mocks
# ============================================================
add_custom_target(test_validate_enable_mocks_rs_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${TEST_FIXTURES_DIR}/validate_enable_mocks_pattern/no_violations" --check enable_mocks
    COMMENT "[Rust] Testing enable_mocks on clean files"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_enable_mocks_rs_fix
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/enable_mocks_fix"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${TEST_FIXTURES_DIR}/validate_enable_mocks_pattern/has_violations"
        "${CMAKE_CURRENT_BINARY_DIR}/enable_mocks_fix"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/enable_mocks_fix" --check enable_mocks --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/enable_mocks_fix" --check enable_mocks
    COMMENT "[Rust] Testing enable_mocks fix"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_enable_mocks_rs_fix_preserves_force
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/enable_mocks_force"
    COMMAND ${CMAKE_COMMAND} -E copy
        "${TEST_FIXTURES_DIR}/validate_enable_mocks_pattern/has_violations/sample_with_mixed_force.c"
        "${CMAKE_CURRENT_BINARY_DIR}/enable_mocks_force/"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/enable_mocks_force" --check enable_mocks --fix
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/enable_mocks_force/sample_with_mixed_force.c"
        "${TEST_FIXTURES_DIR}/validate_enable_mocks_pattern/has_violations/sample_with_mixed_force_expected.c"
    COMMENT "[Rust] Testing enable_mocks fix preserves //force"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_enable_mocks_rs
    COMMENT "[Rust] Running all enable_mocks tests"
)
add_dependencies(test_validate_enable_mocks_rs
    test_validate_enable_mocks_rs_clean
    test_validate_enable_mocks_rs_fix
    test_validate_enable_mocks_rs_fix_preserves_force
)

# ============================================================
# no_vld_include
# ============================================================
add_custom_target(test_validate_no_vld_include_rs_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${TEST_FIXTURES_DIR}/validate_no_vld_include/no_vld_include" --check no_vld_include
    COMMENT "[Rust] Testing no_vld_include on clean files"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_no_vld_include_rs_fix
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/no_vld_fix"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${TEST_FIXTURES_DIR}/validate_no_vld_include/has_vld_include"
        "${CMAKE_CURRENT_BINARY_DIR}/no_vld_fix"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/no_vld_fix" --check no_vld_include --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/no_vld_fix" --check no_vld_include
    COMMENT "[Rust] Testing no_vld_include fix"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_no_vld_include_rs_fix_preserves_other
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/no_vld_preserve"
    COMMAND ${CMAKE_COMMAND} -E copy
        "${TEST_FIXTURES_DIR}/validate_no_vld_include/has_vld_include/sample_with_ifdef_other_code.c"
        "${CMAKE_CURRENT_BINARY_DIR}/no_vld_preserve/"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/no_vld_preserve" --check no_vld_include --fix
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/no_vld_preserve/sample_with_ifdef_other_code.c"
        "${TEST_FIXTURES_DIR}/validate_no_vld_include/has_vld_include/sample_with_ifdef_other_code_expected.c"
    COMMENT "[Rust] Testing no_vld_include fix preserves other code"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_no_vld_include_rs
    COMMENT "[Rust] Running all no_vld_include tests"
)
add_dependencies(test_validate_no_vld_include_rs
    test_validate_no_vld_include_rs_clean
    test_validate_no_vld_include_rs_fix
    test_validate_no_vld_include_rs_fix_preserves_other
)

# ============================================================
# no_backticks_in_srs
# ============================================================
add_custom_target(test_validate_no_backticks_rs_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${TEST_FIXTURES_DIR}/validate_no_backticks_in_srs/no_backticks" --check no_backticks_in_srs
    COMMENT "[Rust] Testing no_backticks on clean files"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_no_backticks_rs_fix
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/backticks_fix"
    COMMAND ${CMAKE_COMMAND} -E copy
        "${TEST_FIXTURES_DIR}/validate_no_backticks_in_srs/has_backticks/sample_with_backticks.c"
        "${CMAKE_CURRENT_BINARY_DIR}/backticks_fix/"
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/backticks_fix" --check no_backticks_in_srs --fix
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/backticks_fix" --check no_backticks_in_srs
    COMMENT "[Rust] Testing no_backticks fix"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_no_backticks_in_srs_rs
    COMMENT "[Rust] Running all no_backticks tests"
)
add_dependencies(test_validate_no_backticks_in_srs_rs
    test_validate_no_backticks_rs_clean
    test_validate_no_backticks_rs_fix
)

# ============================================================
# test_spec_tags
# ============================================================
add_custom_target(test_validate_test_spec_tags_rs_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${TEST_FIXTURES_DIR}/validate_test_spec_tags/no_violations" --check test_spec_tags
    COMMENT "[Rust] Testing test_spec_tags on clean files"
    DEPENDS repo_validator_rs
)

add_custom_target(test_validate_test_spec_tags_rs
    COMMENT "[Rust] Running all test_spec_tags tests"
)
add_dependencies(test_validate_test_spec_tags_rs
    test_validate_test_spec_tags_rs_clean
)

# ============================================================
# Master target: runs ALL Rust validation tests
# ============================================================
add_custom_target(test_validate_all_rs
    COMMENT "[Rust] Running all Rust validation tests"
)
add_dependencies(test_validate_all_rs
    test_validate_no_tabs_rs
    test_validate_file_endings_rs
    test_validate_requirements_naming_rs
    test_validate_srs_uniqueness_rs
    test_validate_enable_mocks_rs
    test_validate_no_vld_include_rs
    test_validate_no_backticks_in_srs_rs
    test_validate_test_spec_tags_rs
)
