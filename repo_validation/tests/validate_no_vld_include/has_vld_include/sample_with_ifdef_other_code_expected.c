// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file has an #ifdef USE_VLD block with other code - block should NOT be removed
// Only the vld.h include line should be removed

#include <stdio.h>

#ifdef USE_VLD
#define VLD_ENABLED 1
#endif

void test_function(void)
{
#ifdef USE_VLD
    printf("VLD is enabled\n");
#endif
    printf("Running test\n");
}
