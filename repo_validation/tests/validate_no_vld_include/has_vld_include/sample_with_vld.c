// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file intentionally includes vld.h directly to test the validation script

#include <stdio.h>
#include <stdlib.h>
#include "vld.h"

void test_function(void)
{
    int* ptr = (int*)malloc(sizeof(int));
    *ptr = 42;
    printf("Value: %d\n", *ptr);
    free(ptr);
}

int main(void)
{
    test_function();
    return 0;
}
