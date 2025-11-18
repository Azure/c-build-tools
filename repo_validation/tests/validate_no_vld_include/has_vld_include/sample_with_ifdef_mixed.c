// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file has multiple include patterns including standalone vld.h

#include <stdio.h>

// This ifdef should be removed (only contains vld.h)
#ifdef USE_VLD
#include "vld.h"
#endif

#include <stdlib.h>

// This standalone include should also be removed
#include <vld.h>

void function_one(void)
{
    printf("Function one\n");
}
