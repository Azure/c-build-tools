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

END_TEST_SUITE(sample_module_ut)
