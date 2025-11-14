// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file does NOT include vld.h and should pass validation

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void test_function_clean(void)
{
    int* ptr = (int*)malloc(sizeof(int));
    *ptr = 42;
    printf("Value: %d\n", *ptr);
    free(ptr);
}

int main(void)
{
    test_function_clean();
    return 0;
}
