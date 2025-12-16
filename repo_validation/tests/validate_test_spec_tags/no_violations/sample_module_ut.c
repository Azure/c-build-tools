// Test file with unit tests that have proper spec tags (no violations)
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

/*Tests_SRS_SAMPLE_MODULE_01_001: [ sample_function shall return 0 when successful. ]*/
TEST_FUNCTION(sample_test_with_tag)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

// Tests_SRS_SAMPLE_MODULE_01_002: [ sample_function shall return 1 when parameter is NULL. ]
TEST_FUNCTION(sample_test_with_cpp_style_tag)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

/*Tests_SRS_SAMPLE_MODULE_01_003: [ First requirement. ]*/
/*Tests_SRS_SAMPLE_MODULE_01_004: [ Second requirement. ]*/
TEST_FUNCTION(sample_test_with_multiple_tags)
{
    // Test implementation
    ASSERT_IS_TRUE(1);
}

END_TEST_SUITE(sample_module_ut)
