// Test file with multi-line comments but code between tags and test - should fail
// Copyright (c) Microsoft. All rights reserved.

#include "some_header.h"
#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(multiline_violations_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
    // Suite initialization
}

/*Tests_SRS_MULTILINE_VIOL_01_001: [ This should succeed. ]*/
TEST_FUNCTION(test_with_proper_tag)
{
    // Test implementation - this is correct
    ASSERT_IS_TRUE(1);
}

// This test is missing a spec tag entirely - VIOLATION
TEST_FUNCTION(test_missing_tag_entirely)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

// This test has only a regular comment, not a spec tag - VIOLATION
/* This is just a regular comment without spec tag */
TEST_FUNCTION(test_with_regular_comment_only)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

END_TEST_SUITE(multiline_violations_ut)
