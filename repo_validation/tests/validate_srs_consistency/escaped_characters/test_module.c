// Copyright (C) Microsoft Corporation. All rights reserved.
//
// TEST CASE: This tests that escaped characters (\<, \>, \\) in markdown requirements
// are properly handled. The markdown has these escaped, but C code should not.

#include <stddef.h>

int test_function(int count)
{
    /*Codes_SRS_ESCAPED_TEST_01_001: [ If next_available_slot < window_count then test_function shall increment the count. ]*/
    if (next_available_slot < window_count)
    {
        return count + 1;
    }
    
    /*Codes_SRS_ESCAPED_TEST_01_002: [ If next_available_slot >= window_count then test_function shall reset to 0. ]*/
    if (next_available_slot >= window_count)
    {
        return 0;
    }
    
    /*Codes_SRS_ESCAPED_TEST_01_003: [ The path shall be in format directory\filename for Windows paths. ]*/
    return -1;
}
