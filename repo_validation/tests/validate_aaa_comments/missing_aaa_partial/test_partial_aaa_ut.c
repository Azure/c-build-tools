// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(TEST_SUITE_NAME_FROM_CMAKE)

TEST_SUITE_INITIALIZE(suite_init)
{
}

TEST_SUITE_CLEANUP(suite_cleanup)
{
}

// Has arrange and assert but missing act
TEST_FUNCTION(test_missing_act_only)
{
    // arrange
    int x = 1;

    // assert
    ASSERT_ARE_EQUAL(int, 1, x);
}

// Has arrange and act but missing assert
TEST_FUNCTION(test_missing_assert_only)
{
    // arrange
    int x = 1;

    // act
    x = x + 1;
}

// Has act and assert but missing arrange
TEST_FUNCTION(test_missing_arrange_only)
{
    // act
    int result = 42;

    // assert
    ASSERT_ARE_EQUAL(int, 42, result);
}

PARAMETERIZED_TEST_FUNCTION(parameterized_missing_act, 2, ARGS(int, value, int, expected))
PARAMETERIZED_TEST_FUNCTION_BEGIN(parameterized_missing_act)
{
    // arrange
    int x = value;

    // assert
    ASSERT_ARE_EQUAL(int, expected, x);
}
PARAMETERIZED_TEST_FUNCTION_END(parameterized_missing_act)

PARAMETERIZED_TEST_FUNCTION_ADD_CASE(parameterized_missing_act, CASE(1, 1))
PARAMETERIZED_TEST_FUNCTION_ADD_CASE(parameterized_missing_act, CASE(2, 2))

END_TEST_SUITE(TEST_SUITE_NAME_FROM_CMAKE)
