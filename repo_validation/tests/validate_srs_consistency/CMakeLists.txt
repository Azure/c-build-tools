# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#
# SRS Consistency Validation Tests
#
# Tests the validate_srs_consistency.ps1 script to ensure it correctly detects
# inconsistencies between markdown requirements and C code SRS tags.
#

set(VALIDATE_SRS_CONSISTENCY_SCRIPT "${VALIDATION_SCRIPTS_DIR}/validate_srs_consistency.ps1")

# Test 1: Verify script detects inconsistent SRS tags
add_custom_target(test_validate_srs_consistency_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/inconsistent"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency detection on inconsistent files"
)

# Test 2: Verify script passes on consistent SRS tags
add_custom_target(test_validate_srs_consistency_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/consistent"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency validation on consistent files"
)

# Test 3: Verify fix functionality works
add_custom_target(test_validate_srs_consistency_fix
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/inconsistent"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
        -Fix
    # Verify SRS tags were made consistent (script should pass now)
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_fix_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing SRS consistency fix functionality"
)

# Test 4: Verify Tests_/Codes_ prefix preservation
add_custom_target(test_validate_srs_consistency_prefix_preservation
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/prefix_preservation"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test"
        -Fix
    # Verify that Codes_ prefix was preserved in source file
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test/test_module.c' -Raw) -notmatch 'Codes_SRS_PREFIX_TEST_66_001') { Write-Error 'Codes_ prefix was not preserved'; exit 1 }"
    # Verify that Tests_ prefix was preserved in test file
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test/test_module_ut.c' -Raw) -notmatch 'Tests_SRS_PREFIX_TEST_66_001') { Write-Error 'Tests_ prefix was not preserved'; exit 1 }"
    # Verify that the text was actually fixed (should now match the markdown)
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test/test_module.c' -Raw) -notmatch 'test_module_create shall allocate memory for a test module') { Write-Error 'Text was not fixed correctly'; exit 1 }"
    # Run validation again to ensure it passes
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_prefix_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing Tests_/Codes_ prefix preservation during fix"
)# Test 8: Verify pointer asterisk preservation in backticks
add_custom_target(test_validate_srs_consistency_pointer_asterisks
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/pointer_asterisks"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing pointer asterisk preservation in backticks"
)

# Test 9: Verify escaped character handling (\<, \>, \\)
add_custom_target(test_validate_srs_consistency_escaped_characters
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/escaped_characters"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing escaped character handling (\\<, \\>, \\\\)"
)

# Test 10: Verify bold text only handling (entire bracketed text is bold: [** text **])
add_custom_target(test_validate_srs_consistency_bold_text_only
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/bold_text_only"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing bold text only handling ([** text **])"
)

# Test 11: Verify escaped multiline duplication fix (bug from cert_rdn_attr_helper)
add_custom_target(test_validate_srs_consistency_escaped_multiline_duplication
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/escaped_multiline_duplication"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test"
    # Run the script with fix mode to clean up duplication
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test"
        -Fix
    # Verify duplication was removed (should not contain multiple ]*/  patterns)
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test/test_module.c' -Raw) -match '\\]\\*/.*?\\]\\*/') { Write-Error 'Duplication was not removed'; exit 1 }"
    # Run validation again to ensure it passes
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_escaped_multiline_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing escaped multiline duplication fix"
)

# Test 12: Verify incomplete comment detection and fix (missing closing bracket and text)
add_custom_target(test_validate_srs_consistency_incomplete_comment
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/incomplete_comment"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test"
    # Run the script with fix mode to complete the comments
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test"
        -Fix
    # Verify incomplete comments were completed (should now have closing brackets and complete text)
    # Check that SRS_TEST_MODULE_01_002 now has the complete text with escaped brackets
    COMMAND ${POWERSHELL_EXECUTABLE} -Command "if ((Get-Content '${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test/src/test.c' -Raw) -notmatch 'If any character has the value outside \\[1\\.\\.\\.127\\] then test_function shall fail and return NULL\\.\\s*\\]') { Write-Error 'Incomplete comment was not fixed correctly'; exit 1 }"
    # Run validation again to ensure it passes
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_incomplete_comment_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing incomplete comment detection and fix"
)

# Test 13: Verify line comments with brackets in text content (e.g., format strings with "]")
# This test reproduces the bug where the line comment regex [^\]] would stop at ] characters
# within the SRS text, causing false validation failures for format strings like "]=%s /*%s*/"
add_custom_target(test_validate_srs_consistency_line_comment_with_brackets
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/line_comment_with_brackets"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing line comments with bracket characters in text content"
)

# Test 14: Verify tag placement passes on correctly placed tags
add_custom_target(test_validate_srs_consistency_tag_placement_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/tag_placement_clean"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tag placement validation on correctly placed tags"
)

# Test 15: Verify tag placement detects violations (Codes_ in test files, Tests_ in prod files)
# This test is expected to fail (exit code 1) - run manually to verify detection works
add_custom_target(test_validate_srs_consistency_tag_placement_violations
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/tag_placement_violations"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing tag placement violation detection"
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
)
# Note: We don't add test_validate_srs_consistency_detection or 
# test_validate_srs_consistency_tag_placement_violations as dependencies because
# they should fail with exit code 1 (which would fail the build). 
# Instead, they are available to run manually to verify detection works.
# Test 5: Verify malformed comment handling (missing closing bracket)
add_custom_target(test_validate_srs_consistency_malformed_comment
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/malformed_comment"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test"
        -Fix
    # Compare output with expected file to verify correct behavior
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test/test_module.c"
        "${CMAKE_CURRENT_SOURCE_DIR}/malformed_comment/test_module_expected.c"
    # Run validation again to ensure it passes
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_malformed_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing malformed comment handling (missing closing bracket)"
)

# Test 6: Verify line-style comment preservation
add_custom_target(test_validate_srs_consistency_line_comment
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/line_comment"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test"
        -Fix
    # Compare output with expected file to verify correct behavior
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test/test_module.c"
        "${CMAKE_CURRENT_SOURCE_DIR}/line_comment/test_module_expected.c"
    # Run validation again to ensure it passes
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_line_comment_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing line-style comment preservation"
)

# Test 7: Verify whitespace preservation in comments
add_custom_target(test_validate_srs_consistency_whitespace
    # Create a temporary directory and copy test files
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/whitespace_preservation"
        "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test"
    # Run the script with fix mode
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test"
        -Fix
    # Compare output with expected file to verify correct behavior
    COMMAND ${CMAKE_COMMAND} -E compare_files
        "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test/test_module.c"
        "${CMAKE_CURRENT_SOURCE_DIR}/whitespace_preservation/test_module_expected.c"
    # Run validation again to ensure it passes
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File "${VALIDATE_SRS_CONSISTENCY_SCRIPT}"
        -RepoRoot "${CMAKE_CURRENT_BINARY_DIR}/temp_whitespace_test"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Testing whitespace preservation in comments"
)



