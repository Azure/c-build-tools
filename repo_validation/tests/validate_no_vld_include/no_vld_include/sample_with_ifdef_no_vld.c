// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file has #ifdef USE_VLD but no vld.h include - should remain untouched

#include <stdio.h>

#ifdef USE_VLD
#define VLD_ENABLED 1
#else
#define VLD_ENABLED 0
#endif

void test_function(void)
{
    printf("VLD enabled: %d\n", VLD_ENABLED);
}
