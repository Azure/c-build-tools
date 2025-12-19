// Test file with multi-line comments between spec tags and TEST_FUNCTION
// Copyright (c) Microsoft. All rights reserved.

#include "some_header.h"
#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(multiline_comments_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
    // Suite initialization
}

TEST_FUNCTION_INITIALIZE(method_init)
{
    // Method initialization
}

/*Tests_SRS_MULTILINE_01_001: [ multiline_function shall succeed. ]*/
/*Tests_SRS_MULTILINE_01_002: [ multiline_function shall return 0 on success. ]*/
/*
Test case table:
case    input       expected
1       valid       success
2       invalid     failure
*/
TEST_FUNCTION(test_with_multiline_comment_table_between_tags_and_function)
{
    // This test has a multi-line comment table between the spec tags and the TEST_FUNCTION
    ASSERT_IS_TRUE(1);
}

/*Tests_SRS_MULTILINE_01_003: [ another_function shall validate parameters. ]*/
/*
This is a descriptive block comment explaining the test scenario
in more detail, spanning multiple lines without any special
formatting or table structure.
*/
TEST_FUNCTION(test_with_multiline_comment_description_between_tags_and_function)
{
    // This test has a multi-line description comment between spec tags and TEST_FUNCTION
    ASSERT_IS_TRUE(1);
}

/*Tests_SRS_MULTILINE_01_004: [ yet_another_function shall process data. ]*/
/*Tests_SRS_MULTILINE_01_005: [ yet_another_function shall return error on failure. ]*/
/*
Scenario: Test with multiple requirements and documentation

Requirements covered:
- SRS_MULTILINE_01_004: Process data correctly
- SRS_MULTILINE_01_005: Handle errors

Test matrix:
input       condition       output
"data"      valid           OK
NULL        invalid         ERROR
""          empty           ERROR
*/
TEST_FUNCTION(test_with_complex_multiline_comment_between_tags_and_function)
{
    // This test has a complex multi-line comment with test matrix between spec tags and TEST_FUNCTION
    ASSERT_IS_TRUE(1);
}

/*Tests_SRS_MULTILINE_01_006: [ simple_function shall work. ]*/
/* Just a one-liner comment here */
TEST_FUNCTION(test_with_single_line_block_comment_between_tags_and_function)
{
    // This test has a single-line block comment between spec tags and TEST_FUNCTION
    ASSERT_IS_TRUE(1);
}

/*Tests_SRS_MULTILINE_01_007: [ blank_lines_function shall succeed. ]*/

/* A comment after blank line */

TEST_FUNCTION(test_with_blank_lines_and_comments_between_tags_and_function)
{
    // This test has blank lines and comments between spec tags and TEST_FUNCTION
    ASSERT_IS_TRUE(1);
}

END_TEST_SUITE(multiline_comments_ut)
