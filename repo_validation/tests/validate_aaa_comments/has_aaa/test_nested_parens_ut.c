// Copyright (c) Microsoft. All rights reserved.
// Test file with helper functions that have nested parentheses in parameter types
// This tests the Fix-FunctionEnd helper that handles THANDLE(...) and similar macros

#include "testrunnerswitcher.h"

// Simulate THANDLE macro - common in Azure C SDK
#define THANDLE(T) T##_HANDLE

typedef struct LATENCY_TRACKER_TAG* LATENCY_TRACKER_HANDLE;
typedef struct ASYNC_SOCKET_TAG* ASYNC_SOCKET_HANDLE;

BEGIN_TEST_SUITE(test_nested_parens_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Helper function with THANDLE(...) in parameters - single nested paren
static void helper_with_thandle_param(int result, THANDLE(LATENCY_TRACKER) tracker)
{
    // arrange
    (void)result;
    (void)tracker;

    // act
    // do something

    // assert
    ASSERT_IS_TRUE(1);
}

// Helper function with multiple THANDLE(...) parameters
static void helper_with_multiple_thandles(
    THANDLE(ASYNC_SOCKET) socket,
    int value,
    THANDLE(LATENCY_TRACKER) tracker)
{
    // arrange
    (void)socket;
    (void)value;
    (void)tracker;

    // act
    // process

    // assert
    ASSERT_IS_NOT_NULL(socket);
}

// Helper with deeply nested parentheses in type
static void helper_with_complex_signature(
    void (*callback)(int, THANDLE(LATENCY_TRACKER)),
    THANDLE(ASYNC_SOCKET) socket)
{
    // arrange
    (void)callback;
    (void)socket;

    // act
    // invoke

    // assert
    ASSERT_IS_TRUE(1);
}

// Test that calls helper with THANDLE parameter
TEST_FUNCTION(test_calls_thandle_helper)
{
    helper_with_thandle_param(0, NULL);
}

// Test that calls helper with multiple THANDLE parameters
TEST_FUNCTION(test_calls_multiple_thandle_helper)
{
    helper_with_multiple_thandles(NULL, 42, NULL);
}

// Test that calls helper with complex nested signature
TEST_FUNCTION(test_calls_complex_signature_helper)
{
    helper_with_complex_signature(NULL, NULL);
}

END_TEST_SUITE(test_nested_parens_ut)
