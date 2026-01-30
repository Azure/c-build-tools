// Copyright (c) Microsoft. All rights reserved.
// Test file with no AAA comments at all

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_no_aaa_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Test with no AAA comments
TEST_FUNCTION(test_completely_missing_aaa)
{
    int x = 5;
    int y = 10;
    int result = x + y;
    ASSERT_ARE_EQUAL(int, 15, result);
}

// Another test with no AAA comments
TEST_FUNCTION(test_also_missing_aaa)
{
    int value = 42;
    int doubled = value * 2;
    ASSERT_ARE_EQUAL(int, 84, doubled);
}

END_TEST_SUITE(test_no_aaa_ut)
