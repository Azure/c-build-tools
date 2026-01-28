// Copyright (c) Microsoft. All rights reserved.
// Test file with AAA comments in helper functions

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_helper_aaa_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Helper function containing arrange comment
static void setup_test_data(int* value)
{
    // arrange
    *value = 42;
}

// Helper function containing act comment
static int perform_action(int input)
{
    // act
    return input * 2;
}

// Helper function containing assert comment
static void verify_result(int expected, int actual)
{
    // assert
    ASSERT_ARE_EQUAL(int, expected, actual);
}

// Helper with arrange and act
static int setup_and_run(void)
{
    // arrange
    int x = 10;
    
    // act
    return x + 5;
}

// Test that delegates AAA to helper functions
TEST_FUNCTION(test_with_helpers_for_aaa)
{
    int value;
    setup_test_data(&value);
    int result = perform_action(value);
    verify_result(84, result);
}

// Test with partial AAA in body, rest in helpers
TEST_FUNCTION(test_with_partial_delegation)
{
    // arrange
    int input = 5;
    
    int result = perform_action(input);
    verify_result(10, result);
}

// Test using combined helper
TEST_FUNCTION(test_using_combined_helper)
{
    int result = setup_and_run();
    
    // assert
    ASSERT_ARE_EQUAL(int, 15, result);
}

END_TEST_SUITE(test_helper_aaa_ut)
