// Copyright (c) Microsoft. All rights reserved.
// Test file missing the assert comment

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_missing_assert_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Test missing assert comment
TEST_FUNCTION(test_missing_assert)
{
    // arrange
    int x = 5;
    int y = 10;

    // act
    int result = x + y;

    ASSERT_ARE_EQUAL(int, 15, result);
}

END_TEST_SUITE(test_missing_assert_ut)
