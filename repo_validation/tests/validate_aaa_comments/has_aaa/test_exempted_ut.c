// Copyright (c) Microsoft. All rights reserved.
// Test file with exempted test functions

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_exempted_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Test exempted with double-slash comment
TEST_FUNCTION(test_exempted_with_double_slash) // no-aaa
{
    // This test is intentionally exempted from AAA validation
    int x = 1;
    ASSERT_ARE_EQUAL(int, 1, x);
}

// Test exempted with block comment
TEST_FUNCTION(test_exempted_with_block_comment) /* no-aaa */
{
    // This test is also exempted
    int y = 2;
    ASSERT_ARE_EQUAL(int, 2, y);
}

// Test exempted with extra whitespace
TEST_FUNCTION(test_exempted_with_whitespace)   //   no-aaa
{
    int z = 3;
    ASSERT_ARE_EQUAL(int, 3, z);
}

// Non-exempted test should still have AAA
TEST_FUNCTION(test_not_exempted_has_aaa)
{
    // arrange
    int value = 100;

    // act
    int doubled = value * 2;

    // assert
    ASSERT_ARE_EQUAL(int, 200, doubled);
}

END_TEST_SUITE(test_exempted_ut)
