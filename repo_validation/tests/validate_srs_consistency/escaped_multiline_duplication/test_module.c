// Copyright (C) Microsoft Corporation. All rights reserved.
//
// TEST CASE: This reproduces the bug where a long SRS requirement with escaped characters
// causes the fix script to duplicate the text multiple times.
// Initially this has incorrect text that needs to be fixed.

#include <stddef.h>

void test_function(void)
{
    /*Codes_SRS_ESCAPED_MULTILINE_02_013: [ If cert_rdn_attr->dwValueType is none of the previously listed values then test_function shall produce a string with format (CERT_RDN_ATTR){ .pszObjId=%s \/*%s*\/, .dwValueType=%s, .Value=%s } and use "UNIMPLEMENTED" for ".Value".]*/, .dwValueType=%s, .Value=%s } and use "UNIMPLEMENTED" for ".Value".]*/, .dwValueType=%s, .Value=%s } and use "UNIMPLEMENTED" for ".Value". ]*/
    // Function implementation
}
