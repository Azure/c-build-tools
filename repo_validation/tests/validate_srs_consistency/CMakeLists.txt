# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# SRS Consistency Validation Tests
#
# Tests the repo_validator srs_consistency check to ensure it correctly detects
# inconsistencies between markdown requirements and C code SRS tags.
#

# Test 1: Verify tool detects inconsistent SRS tags
add_custom_target(test_validate_srs_consistency_detection
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/inconsistent" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency detection on inconsistent files"
    DEPENDS repo_validator_rs
)

# Test 2: Verify tool passes on consistent SRS tags
add_custom_target(test_validate_srs_consistency_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/consistent" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency validation on consistent files"
    DEPENDS repo_validator_rs
)

# Test 3: Verify fix functionality works
add_custom_target(test_validate_srs_consistency_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/inconsistent"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check srs_consistency --fix
    # Verify SRS tags were made consistent (tool should pass now)
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency fix functionality"
    DEPENDS repo_validator_rs
)

# Test 4: Verify Tests_/Codes_ prefix preservation
add_custom_target(test_validate_srs_consistency_prefix_preservation
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/prefix_preservation"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test" --check srs_consistency --fix
    # Verify that Codes_ prefix was preserved in source file
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test/test_module.c' -Raw) -notmatch 'Codes_SRS_PREFIX_TEST_66_001') { Write-Error 'Codes_ prefix was not preserved'; exit 1 }"
    # Verify that Tests_ prefix was preserved in test file
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test/test_module_ut/test_module_ut.c' -Raw) -notmatch 'Tests_SRS_PREFIX_TEST_66_001') { Write-Error 'Tests_ prefix was not preserved'; exit 1 }"
    # Verify that the text was actually fixed (should now match the markdown)
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test/test_module.c' -Raw) -notmatch 'test_module_create shall allocate memory for a test module') { Write-Error 'Text was not fixed correctly'; exit 1 }"
    # Run validation again to ensure it passes
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing Tests_/Codes_ prefix preservation during fix"
    DEPENDS repo_validator_rs
)

# Test 5: Verify malformed comment handling (missing closing bracket)
add_custom_target(test_validate_srs_consistency_malformed_comment
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/malformed_comment"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test" --check srs_consistency --fix
    # Compare output with expected file to verify correct behavior
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test/test_module.c"
        "${CMAKE_CURRENT_SOURCE_DIR}/malformed_comment/test_module_expected.c"
    # Run validation again to ensure it passes
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing malformed comment handling (missing closing bracket)"
    DEPENDS repo_validator_rs
)

# Test 6: Verify line-style comment preservation
add_custom_target(test_validate_srs_consistency_line_comment
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/line_comment"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test" --check srs_consistency --fix
    # Compare output with expected file to verify correct behavior
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test/test_module.c"
        "${CMAKE_CURRENT_SOURCE_DIR}/line_comment/test_module_expected.c"
    # Run validation again to ensure it passes
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing line-style comment preservation"
    DEPENDS repo_validator_rs
)

# Test 7: Verify whitespace preservation in comments
add_custom_target(test_validate_srs_consistency_whitespace
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/whitespace_preservation"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test"
    # Run the tool with fix mode
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test" --check srs_consistency --fix
    # Compare output with expected file to verify correct behavior
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test/test_module.c"
        "${CMAKE_CURRENT_SOURCE_DIR}/whitespace_preservation/test_module_expected.c"
    # Run validation again to ensure it passes
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing whitespace preservation in comments"
    DEPENDS repo_validator_rs
)

# Test 8: Verify pointer asterisk preservation in backticks
add_custom_target(test_validate_srs_consistency_pointer_asterisks
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/pointer_asterisks" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing pointer asterisk preservation in backticks"
    DEPENDS repo_validator_rs
)

# Test 9: Verify escaped character handling (\<, \>, \\)
add_custom_target(test_validate_srs_consistency_escaped_characters
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/escaped_characters" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing escaped character handling (\\<, \\>, \\\\)"
    DEPENDS repo_validator_rs
)

# Test 10: Verify bold text only handling (entire bracketed text is bold: [** text **])
add_custom_target(test_validate_srs_consistency_bold_text_only
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/bold_text_only" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing bold text only handling ([** text **])"
    DEPENDS repo_validator_rs
)

# Test 11: Verify escaped multiline duplication fix (bug from cert_rdn_attr_helper)
add_custom_target(test_validate_srs_consistency_escaped_multiline_duplication
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/escaped_multiline_duplication"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test"
    # Run the tool with fix mode to clean up duplication
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test" --check srs_consistency --fix
    # Verify duplication was removed (should not contain multiple ]*/  patterns)
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test/test_module.c' -Raw) -match '\\]\\*/.*?\\]\\*/') { Write-Error 'Duplication was not removed'; exit 1 }"
    # Run validation again to ensure it passes
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing escaped multiline duplication fix"
    DEPENDS repo_validator_rs
)

# Test 12: Verify incomplete comment detection and fix (missing closing bracket and text)
add_custom_target(test_validate_srs_consistency_incomplete_comment
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/incomplete_comment"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test"
    # Run the tool with fix mode to complete the comments
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test" --check srs_consistency --fix
    # Verify incomplete comments were completed (should now have closing brackets and complete text)
    # Check that SRS_TEST_MODULE_01_002 now has the complete text with escaped brackets
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test/src/test.c' -Raw) -notmatch 'If any character has the value outside \\[1\\.\\.\\.127\\] then test_function shall fail and return NULL\\.\\s*\\]') { Write-Error 'Incomplete comment was not fixed correctly'; exit 1 }"
    # Run validation again to ensure it passes
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing incomplete comment detection and fix"
    DEPENDS repo_validator_rs
)

# Test 13: Verify line comments with brackets in text content (e.g., format strings with "]")
# This test reproduces the bug where the line comment regex [^\]] would stop at ] characters
# within the SRS text, causing false validation failures for format strings like "]=%s /*%s*/"
add_custom_target(test_validate_srs_consistency_line_comment_with_brackets
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/line_comment_with_brackets" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing line comments with bracket characters in text content"
    DEPENDS repo_validator_rs
)

# Test 14: Verify tag placement passes on correctly placed tags
add_custom_target(test_validate_srs_consistency_tag_placement_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/tag_placement_clean" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tag placement validation on correctly placed tags"
    DEPENDS repo_validator_rs
)

# Test 15: Verify tag placement detects violations (Codes_ in test files, Tests_ in prod files)
# This test is expected to fail (exit code 1) - run manually to verify detection works
add_custom_target(test_validate_srs_consistency_tag_placement_violations
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/tag_placement_violations" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tag placement violation detection"
    DEPENDS repo_validator_rs
)

# Test 16: Verify tag placement violation output includes file names (multiple violations)
add_custom_target(test_validate_srs_consistency_tag_placement_output
    COMMAND ${POWERSHELL_EXECUTABLE} -NoProfile -ExecutionPolicy Bypass -File
        "${CMAKE_CURRENT_SOURCE_DIR}/test_tag_placement_output.ps1"
        -ValidatorPath "${REPO_VALIDATOR_RS_EXE}"
        -FixtureRoot "${CMAKE_CURRENT_SOURCE_DIR}/tag_placement_violations"
        -ExpectedFileNames "tag_place.c,tag_place_ut.c"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tag placement violation output includes file names"
    DEPENDS repo_validator_rs
)

# Test 17: Verify tag placement output with a single violation
add_custom_target(test_validate_srs_consistency_tag_placement_single_violation
    COMMAND ${POWERSHELL_EXECUTABLE} -NoProfile -ExecutionPolicy Bypass -File
        "${CMAKE_CURRENT_SOURCE_DIR}/test_tag_placement_output.ps1"
        -ValidatorPath "${REPO_VALIDATOR_RS_EXE}"
        -FixtureRoot "${CMAKE_CURRENT_SOURCE_DIR}/tag_placement_single_violation"
        -ExpectedFileNames "single_place.c"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tag placement output with single violation"
    DEPENDS repo_validator_rs
)

# Test 18: Verify Tests_SRS_ tags are allowed in test helper files inside _ut directories
add_custom_target(test_validate_srs_consistency_tag_placement_test_helper
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/tag_placement_test_helper" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing that Tests_SRS_ tags are allowed in helper files inside _ut directories"
    DEPENDS repo_validator_rs
)

# Test 19: C# file support - clean validation
add_custom_target(test_validate_srs_consistency_cs_clean
    COMMAND "${REPO_VALIDATOR_RS_EXE}" --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/cs_clean" --check srs_consistency
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency validation on clean C# files"
    DEPENDS repo_validator_rs
)

# Master target for all SRS consistency validation tests
add_custom_target(test_validate_srs_consistency
    COMMENT "Running all SRS consistency validation tests"
)

# Add dependencies - clean test should pass, fix test validates fix functionality
add_dependencies(test_validate_srs_consistency
    test_validate_srs_consistency_clean
    test_validate_srs_consistency_fix
    test_validate_srs_consistency_prefix_preservation
    test_validate_srs_consistency_malformed_comment
    test_validate_srs_consistency_line_comment
    test_validate_srs_consistency_whitespace
    test_validate_srs_consistency_pointer_asterisks
    test_validate_srs_consistency_escaped_characters
    test_validate_srs_consistency_bold_text_only
    test_validate_srs_consistency_escaped_multiline_duplication
    test_validate_srs_consistency_incomplete_comment
    test_validate_srs_consistency_line_comment_with_brackets
    test_validate_srs_consistency_tag_placement_clean
    test_validate_srs_consistency_tag_placement_output
    test_validate_srs_consistency_tag_placement_single_violation
    test_validate_srs_consistency_tag_placement_test_helper
    test_validate_srs_consistency_cs_clean
)
# Master target for all expected-failure tests
add_custom_target(test_validate_srs_consistency_failures
    COMMENT "Running all srs_consistency failure detection tests"
)
add_dependencies(test_validate_srs_consistency_failures
    test_validate_srs_consistency_detection
    test_validate_srs_consistency_tag_placement_violations
)