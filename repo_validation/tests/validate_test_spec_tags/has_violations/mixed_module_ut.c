// Test file with mixed violations (some with tags, some without)
// Copyright (c) Microsoft. All rights reserved.

#include "some_header.h"
#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(mixed_module_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
    // Suite initialization
}

/*Tests_SRS_MIXED_MODULE_01_001: [ This test has a proper tag. ]*/
TEST_FUNCTION(test_with_proper_tag)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

// This test is missing a spec tag - VIOLATION
TEST_FUNCTION(test_missing_tag)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

/*Tests_SRS_MIXED_MODULE_01_002: [ Another test with a tag. ]*/
TEST_FUNCTION(another_test_with_tag)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

END_TEST_SUITE(mixed_module_ut)
