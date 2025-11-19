// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file includes vld.h with a different comment (not "force")
// The validation script SHOULD detect this as a violation

#include <stdio.h>
#include <stdlib.h>
#include "vld.h"  // intentional include

void test_function_with_other_comment(void)
{
    int* ptr = (int*)malloc(sizeof(int));
    *ptr = 42;
    printf("Value: %d\n", *ptr);
    free(ptr);
}

int main(void)
{
    test_function_with_other_comment();
    return 0;
}
