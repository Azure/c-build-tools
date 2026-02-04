// Copyright (c) Microsoft. All rights reserved.
// Test file with helper that has nested parens but NO AAA comments
// This should FAIL validation - the helper exists but lacks AAA

#include "testrunnerswitcher.h"

#define THANDLE(T) T##_HANDLE

typedef struct TRACKER_TAG* TRACKER_HANDLE;

BEGIN_TEST_SUITE(test_nested_parens_missing_aaa_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Helper with THANDLE param but NO AAA comments - should not satisfy AAA requirement
static void helper_without_aaa(int value, THANDLE(TRACKER) tracker)
{
    // This helper has NO arrange/act/assert comments
    (void)value;
    (void)tracker;
    // just some code
    int x = 5;
    (void)x;
}

// Test that calls the helper - should FAIL because neither test nor helper has AAA
TEST_FUNCTION(test_missing_aaa_with_thandle_helper)
{
    helper_without_aaa(42, NULL);
}

END_TEST_SUITE(test_nested_parens_missing_aaa_ut)
