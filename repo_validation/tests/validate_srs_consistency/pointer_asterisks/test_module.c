// Copyright (C) Microsoft Corporation. All rights reserved.
//
// TEST CASE: This tests that asterisks in C pointer syntax are preserved.
// Requirements in markdown use backticks around pointer syntax like `*t1`.
// The validation script must preserve these asterisks in C file comments.

#include <stddef.h>

int test_function(void** t1, void** t2)
{
    /*Codes_SRS_POINTER_TEST_01_003: [ If both *t1 and *t2 are NULL then test_function shall return 0. ]*/
    if (*t1 == NULL && *t2 == NULL)
    {
        return 0;
    }
    
    /*Codes_SRS_POINTER_TEST_01_001: [ If *t1 is NULL and *t2 is not NULL then test_function shall move *t2 under t1, set *t2 to NULL and return 0. ]*/
    if (*t1 == NULL && *t2 != NULL)
    {
        *t1 = *t2;
        *t2 = NULL;
        return 0;
    }
    
    /*Codes_SRS_POINTER_TEST_01_002: [ If *t1 is not NULL and *t2 is NULL then test_function shall free *t1, set *t1 to NULL and return 0. ]*/
    if (*t1 != NULL && *t2 == NULL)
    {
        free(*t1);
        *t1 = NULL;
        return 0;
    }
    
    return -1;
}
