// Copyright (c) Microsoft. All rights reserved.
// Test file with direct AAA comments in test bodies

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_direct_aaa_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

TEST_SUITE_CLEANUP(suite_cleanup)
{
}

TEST_FUNCTION_INITIALIZE(method_init)
{
}

TEST_FUNCTION_CLEANUP(method_cleanup)
{
}

// Basic test with standard AAA comments
TEST_FUNCTION(test_with_standard_aaa_comments)
{
    // arrange
    int x = 5;
    int y = 10;

    // act
    int result = x + y;

    // assert
    ASSERT_ARE_EQUAL(int, 15, result);
}

// Test with triple-slash comments
TEST_FUNCTION(test_with_triple_slash_comments)
{
    /// arrange
    int a = 1;

    /// act
    int b = a * 2;

    /// assert
    ASSERT_ARE_EQUAL(int, 2, b);
}

// Test with block comments
TEST_FUNCTION(test_with_block_comments)
{
    /* arrange */
    int value = 42;

    /* act */
    int doubled = value * 2;

    /* assert */
    ASSERT_ARE_EQUAL(int, 84, doubled);
}

// Test with uppercase AAA comments
TEST_FUNCTION(test_with_uppercase_comments)
{
    // ARRANGE
    int input = 100;

    // ACT
    int output = input / 10;

    // ASSERT
    ASSERT_ARE_EQUAL(int, 10, output);
}

// Test with mixed case AAA comments
TEST_FUNCTION(test_with_mixed_case_comments)
{
    // Arrange
    int first = 3;

    // Act
    int second = first + 7;

    // Assert
    ASSERT_ARE_EQUAL(int, 10, second);
}

// Test with cleanup section (optional, not validated)
TEST_FUNCTION(test_with_cleanup_section)
{
    // arrange
    int* ptr = malloc(sizeof(int));
    *ptr = 5;

    // act
    int value = *ptr;

    // assert
    ASSERT_ARE_EQUAL(int, 5, value);

    // cleanup
    free(ptr);
}

END_TEST_SUITE(test_direct_aaa_ut)
