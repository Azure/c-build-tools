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

    # List of all validation checks — each has a test_validate_<CHECK> master target
    # for passing tests and a test_validate_<CHECK>_failures master target for
    # expected-failure detection tests.
    set(VALIDATION_CHECKS
        no_tabs
        file_endings
        srs_consistency
        srs_uniqueness
        requirements_naming
        no_vld_include
        enable_mocks
        test_spec_tags
        aaa_comments
        no_backticks_in_srs
        c_build_tools_ref
        srs_format
    )

    # Register passing and failing tests for each check
    foreach(CHECK ${VALIDATION_CHECKS})
        # Passing tests (clean + fix)
        add_test(NAME validate_${CHECK}_test
            COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_${CHECK}
        )

        # Failure detection tests (expected to fail with exit code 1)
        add_test(NAME validate_${CHECK}_failures_test
            COMMAND ${CMAKE_COMMAND} --build ${CMAKE_BINARY_DIR} --target test_validate_${CHECK}_failures
        )
        set_tests_properties(validate_${CHECK}_failures_test PROPERTIES WILL_FAIL TRUE)
    endforeach()
endif()