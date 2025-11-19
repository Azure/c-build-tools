// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file includes vld.h with a "// FORCE" comment (uppercase)
// The validation script should ignore this include

#include <stdio.h>
#include <stdlib.h>
#include "vld.h"  // FORCE

void test_function_with_force_upper(void)
{
    int* ptr = (int*)malloc(sizeof(int));
    *ptr = 42;
    printf("Value: %d\n", *ptr);
    free(ptr);
}

int main(void)
{
    test_function_with_force_upper();
    return 0;
}
