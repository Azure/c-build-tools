// Copyright (c) Microsoft. All rights reserved.
// Test file missing the act comment

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_missing_act_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Test missing act comment
TEST_FUNCTION(test_missing_act)
{
    // arrange
    int x = 5;
    int y = 10;

    int result = x + y;

    // assert
    ASSERT_ARE_EQUAL(int, 15, result);
}

END_TEST_SUITE(test_missing_act_ut)
