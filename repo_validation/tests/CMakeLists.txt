# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# Repository Validation Testing Framework
#
# This CMake file defines test targets for validating the repository validation checks.
# All checks are implemented in the Rust repo_validator_rs tool.
#

# Add test targets for each validation check
add_subdirectory(validate_no_tabs)
add_subdirectory(validate_file_endings)
add_subdirectory(validate_srs_consistency)
add_subdirectory(validate_srs_uniqueness)
add_subdirectory(validate_requirements_naming)
add_subdirectory(validate_no_vld_include)
add_subdirectory(validate_enable_mocks_pattern)
add_subdirectory(validate_test_spec_tags)
add_subdirectory(validate_aaa_comments)
add_subdirectory(validate_no_backticks_in_srs)
add_subdirectory(validate_c_build_tools_ref)
add_subdirectory(validate_srs_format)

if(run_unittests)
    enable_testing()
    
    # Add each test to CTest
    add_test(NAME validate_no_tabs_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_no_tabs
    )
    
    add_test(NAME validate_file_endings_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_file_endings
    )
    
    add_test(NAME validate_srs_consistency_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_srs_consistency
    )

    add_test(NAME validate_srs_uniqueness_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_srs_uniqueness
    )

    add_test(NAME validate_requirements_naming_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_requirements_naming
    )

    add_test(NAME validate_no_vld_include_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_no_vld_include
    )

    add_test(NAME validate_enable_mocks_pattern_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_enable_mocks
    )

    add_test(NAME validate_test_spec_tags_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_test_spec_tags
    )

    add_test(NAME validate_aaa_comments_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_aaa_comments
    )

    add_test(NAME validate_no_backticks_in_srs_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_no_backticks_in_srs
    )

    add_test(NAME validate_c_build_tools_ref_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_c_build_tools_ref
    )

    add_test(NAME validate_srs_format_test
        COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_srs_format
    )

    # Detection tests: these run the validator against fixtures with known violations
    # and expect the tool to exit with code 1 (WILL_FAIL = TRUE means CTest expects failure)
    add_test(NAME validate_no_tabs_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_no_tabs/has_tabs" --check no_tabs
    )
    set_tests_properties(validate_no_tabs_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_file_endings_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_file_endings/missing_crlf" --check file_endings
    )
    set_tests_properties(validate_file_endings_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_requirements_naming_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_requirements_naming/incorrect_naming" --check requirements_naming
    )
    set_tests_properties(validate_requirements_naming_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_srs_uniqueness_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_srs_uniqueness/duplicate_srs" --check srs_uniqueness
    )
    set_tests_properties(validate_srs_uniqueness_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_enable_mocks_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_enable_mocks_pattern/has_violations" --check enable_mocks
    )
    set_tests_properties(validate_enable_mocks_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_no_vld_include_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_no_vld_include/has_vld_include" --check no_vld_include
    )
    set_tests_properties(validate_no_vld_include_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_no_backticks_in_srs_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_no_backticks_in_srs/has_backticks" --check no_backticks_in_srs
    )
    set_tests_properties(validate_no_backticks_in_srs_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_test_spec_tags_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_test_spec_tags/has_violations" --check test_spec_tags
    )
    set_tests_properties(validate_test_spec_tags_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_aaa_comments_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_aaa_comments/missing_aaa" --check aaa_comments
    )
    set_tests_properties(validate_aaa_comments_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_srs_consistency_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_srs_consistency/inconsistent" --check srs_consistency
    )
    set_tests_properties(validate_srs_consistency_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_srs_format_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_srs_format/has_violations" --check srs_format
    )
    set_tests_properties(validate_srs_format_detection_test PROPERTIES WILL_FAIL TRUE)

    add_test(NAME validate_c_build_tools_ref_detection_test
        COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/validate_c_build_tools_ref/invalid_sha_ref"
            --check c_build_tools_ref --submodule-sha "aabbccdd00112233445566778899aabbccddeeff"
    )
    set_tests_properties(validate_c_build_tools_ref_detection_test PROPERTIES WILL_FAIL TRUE)

endif()