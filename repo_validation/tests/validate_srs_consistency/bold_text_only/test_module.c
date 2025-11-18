// Copyright (C) Microsoft Corporation. All rights reserved.
//
// TEST CASE: This tests that asterisks used for bold formatting in markdown
// are properly stripped when the entire bracketed text is bold: [** text **]
// This pattern is commonly used for type names in requirements.

#include <stddef.h>

void supported_types(void)
{
    /* Codes_SRS_BOLD_TEST_01_001: [The following types shall be supported:]*/
    /* Codes_SRS_BOLD_TEST_01_002: [unsigned char]*/
    /* Codes_SRS_BOLD_TEST_01_003: [short]*/
    /* Codes_SRS_BOLD_TEST_01_004: [unsigned short]*/
    /* Codes_SRS_BOLD_TEST_01_005: [int]*/
    /* Codes_SRS_BOLD_TEST_01_006: [unsigned int]*/
    /* Codes_SRS_BOLD_TEST_01_007: [long]*/
    /* Codes_SRS_BOLD_TEST_01_008: [unsigned long]*/
    /* Codes_SRS_BOLD_TEST_01_009: [long long]*/
    /* Codes_SRS_BOLD_TEST_01_010: [unsigned long long]*/
    /* Codes_SRS_BOLD_TEST_01_011: [float]*/
    /* Codes_SRS_BOLD_TEST_01_012: [double]*/
    /* Codes_SRS_BOLD_TEST_01_013: [long double]*/
    /* Codes_SRS_BOLD_TEST_01_014: [size_t]*/
}
