// Copyright (c) Microsoft. All rights reserved.
// Test file with PARAMETERIZED_TEST_FUNCTION missing AAA comments

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_parameterized_missing_aaa_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Parameterized test with multi-line CASE entries but no AAA comments
PARAMETERIZED_TEST_FUNCTION(parameterized_test_no_aaa,
    ARGS(const char*, input, int, expected),
    CASE(("hello", 5), input_hello),
    CASE(("world", 5), input_world))
{
    int len = (int)strlen(input);
    ASSERT_ARE_EQUAL(int, expected, len);
}

END_TEST_SUITE(test_parameterized_missing_aaa_ut)
