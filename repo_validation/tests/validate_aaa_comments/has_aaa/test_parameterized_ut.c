// Copyright (c) Microsoft. All rights reserved.
// Test file with PARAMETERIZED_TEST_FUNCTION that has multi-line macro invocation
// with nested parentheses in ARGS and CASE macros

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_parameterized_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

TEST_SUITE_CLEANUP(suite_cleanup)
{
}

// Parameterized test with multi-line CASE entries containing nested parens
PARAMETERIZED_TEST_FUNCTION(parameterized_test_with_aaa,
    ARGS(const char*, input, int, expected),
    CASE(("hello", 5), input_hello),
    CASE(("world", 5), input_world),
    CASE(("test", 4), input_test))
{
    // arrange
    const char* str = input;

    // act
    int len = (int)strlen(str);

    // assert
    ASSERT_ARE_EQUAL(int, expected, len);
}

// Simple parameterized test with single CASE
PARAMETERIZED_TEST_FUNCTION(parameterized_test_single_case,
    ARGS(int, value, int, expected),
    CASE((42, 84), double_42))
{
    // arrange
    int input = value;

    // act
    int result = input * 2;

    // assert
    ASSERT_ARE_EQUAL(int, expected, result);
}

END_TEST_SUITE(test_parameterized_ut)
