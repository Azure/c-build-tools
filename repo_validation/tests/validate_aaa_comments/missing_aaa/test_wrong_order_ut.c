// Copyright (c) Microsoft. All rights reserved.
// Test file with AAA comments in wrong order

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_wrong_order_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Test with AAA in wrong order (act before arrange)
TEST_FUNCTION(test_act_before_arrange)
{
    // act
    int result = 5 + 10;

    // arrange
    int expected = 15;

    // assert
    ASSERT_ARE_EQUAL(int, expected, result);
}

// Test with AAA in wrong order (assert before act)
TEST_FUNCTION(test_assert_before_act)
{
    // arrange
    int x = 5;

    // assert
    ASSERT_ARE_EQUAL(int, 5, x);

    // act
    x = x + 1;
}

END_TEST_SUITE(test_wrong_order_ut)
