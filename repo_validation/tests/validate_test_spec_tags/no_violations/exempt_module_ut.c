// Test file with exempted tests using no-srs marker
// Copyright (c) Microsoft. All rights reserved.

#include "some_header.h"
#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(exempt_module_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
    // Suite initialization
}

TEST_FUNCTION_INITIALIZE(method_init)
{
    // Method initialization
}

// This test is exempted from requiring spec tags
TEST_FUNCTION(helper_test_without_spec_tag) // no-srs
{
    // This is a helper test that doesn't test specific requirements
    ASSERT_IS_TRUE(1);
}

/*Tests_SRS_EXEMPT_MODULE_01_001: [ exempt_function shall succeed. ]*/
TEST_FUNCTION(normal_test_with_tag)
{
    // Test implementation with proper tag
    ASSERT_IS_TRUE(1);
}

// Test exempted using C-style comment marker
TEST_FUNCTION(another_exempt_test) /* no-srs */
{
    // Another helper test
    ASSERT_IS_TRUE(1);
}

END_TEST_SUITE(exempt_module_ut)
