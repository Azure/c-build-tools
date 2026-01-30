// Copyright (c) Microsoft. All rights reserved.
// Test file with various comment styles for AAA

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_mixed_styles_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Test with // style
TEST_FUNCTION(test_double_slash_style)
{
    // arrange
    int x = 1;

    // act
    int y = x + 1;

    // assert
    ASSERT_ARE_EQUAL(int, 2, y);
}

// Test with /// style
TEST_FUNCTION(test_triple_slash_style)
{
    /// arrange
    int a = 5;

    /// act
    int b = a * 3;

    /// assert
    ASSERT_ARE_EQUAL(int, 15, b);
}

// Test with /* */ style
TEST_FUNCTION(test_block_comment_style)
{
    /* arrange */
    int p = 10;

    /* act */
    int q = p - 3;

    /* assert */
    ASSERT_ARE_EQUAL(int, 7, q);
}

// Test with mixed styles in same function
TEST_FUNCTION(test_mixed_in_same_function)
{
    // arrange
    int m = 2;

    /// act
    int n = m * m;

    /* assert */
    ASSERT_ARE_EQUAL(int, 4, n);
}

// Test with extra text after AAA keyword
TEST_FUNCTION(test_with_extra_text)
{
    // arrange - setup initial values
    int first = 1;
    int second = 2;

    // act - perform the operation
    int sum = first + second;

    // assert - verify the result
    ASSERT_ARE_EQUAL(int, 3, sum);
}

// CTEST_FUNCTION style test
CTEST_FUNCTION(ctest_with_aaa_comments)
{
    // arrange
    int val = 50;

    // act
    int half = val / 2;

    // assert
    ASSERT_ARE_EQUAL(int, 25, half);
}

END_TEST_SUITE(test_mixed_styles_ut)
