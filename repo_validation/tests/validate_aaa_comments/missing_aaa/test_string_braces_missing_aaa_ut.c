// Copyright (c) Microsoft. All rights reserved.
// Test file with string braces but NO AAA comments
// This should FAIL validation - string braces shouldn't fool the validator

#include "testrunnerswitcher.h"

BEGIN_TEST_SUITE(test_string_braces_missing_aaa_ut)

TEST_SUITE_INITIALIZE(suite_init)
{
}

// Test with string containing braces but NO AAA comments - should FAIL
TEST_FUNCTION(test_string_braces_no_aaa)
{
    // This test has NO arrange/act/assert comments
    // The string braces should not confuse the validator
    const char* json = "{ \"key\": \"value\" }";
    const char* more = "{ nested { braces } }";
    (void)json;
    (void)more;
}

// Test with unmatched braces in string but NO AAA comments - should FAIL
TEST_FUNCTION(test_unmatched_braces_no_aaa)
{
    // This test has unmatched braces in strings but NO AAA comments
    const char* unmatched_close = "Error: unexpected }";
    const char* unmatched_open = "Error: unclosed {";
    (void)unmatched_close;
    (void)unmatched_open;
}

END_TEST_SUITE(test_string_braces_missing_aaa_ut)
