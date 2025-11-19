// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file includes vld.h with a "// force" comment
// The validation script should ignore this include

#include <stdio.h>
#include <stdlib.h>
#include "vld.h"  // force

void test_function_with_force(void)
{
    int* ptr = (int*)malloc(sizeof(int));
    *ptr = 42;
    printf("Value: %d\n", *ptr);
    free(ptr);
}

int main(void)
{
    test_function_with_force();
    return 0;
}
