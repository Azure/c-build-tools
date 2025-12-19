// Copyright (C) Microsoft Corporation. All rights reserved.
//
// TEST CASE: This tests that line comments (//) containing bracket characters (]) in the
// SRS text content are properly parsed. This reproduces the issue from cert_enhkey_usage_helper
// where the format string contained "]=%s /*%s*/" which broke the line comment parsing.

#include <stddef.h>
#include <inttypes.h>

char* test_function(const char* input)
{
    char* result;

    //Codes_SRS_LINE_BRACKET_TEST_01_002: [ If input is NULL then test_function shall return NULL. ]
    if (input == NULL)
    {
        result = NULL;
    }
    else
    {
        //Codes_SRS_LINE_BRACKET_TEST_01_001: [ test_function shall produce a string with the format "%s%s[%" PRIu32 "]=%s /*%s*/". ]
        //Codes_SRS_LINE_BRACKET_TEST_01_003: [ test_function shall format the output as "array[index]=value" for each element. ]
        result = format_string(input);
    }

    return result;
}

