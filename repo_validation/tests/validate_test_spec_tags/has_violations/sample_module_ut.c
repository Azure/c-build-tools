// Test file with unit tests missing spec tags (violations)
// Copyright (c) Microsoft. All rights reserved.

#include "some_header.h"
#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(sample_module_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
    // Suite initialization
}

TEST_SUITE_CLEANUP(suite_cleanup)
{
    // Suite cleanup
}

TEST_FUNCTION_INITIALIZE(method_init)
{
    // Method initialization
}

TEST_FUNCTION_CLEANUP(method_cleanup)
{
    // Method cleanup
}

// This test is missing a spec tag - VIOLATION
TEST_FUNCTION(sample_test_without_tag)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

// This test is also missing a spec tag - VIOLATION
TEST_FUNCTION(another_test_without_tag)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

// This parameterized test is missing a spec tag - VIOLATION
PARAMETERIZED_TEST_FUNCTION(parameterized_test_without_tag,
    ARGS(int, value),
    CASE((1), with_one),
    CASE((2), with_two))
{
    // Test implementation
    ASSERT_IS_TRUE(value > 0);
}

// This parameterized test is also missing a spec tag - VIOLATION
PARAMETERIZED_TEST_FUNCTION(another_parameterized_without_tag,
    ARGS(int, x, int, y),
    CASE((1, 2), small_values),
    CASE((10, 20), larger_values))
{
    ASSERT_IS_TRUE(x + y > 0);
}

END_TEST_SUITE(sample_module_ut)
