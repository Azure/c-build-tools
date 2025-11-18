// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file tests vld.h with comments in the #ifdef block

#include <iostream>

#ifdef USE_VLD
// Include VLD for memory leak detection
#include <vld.h>
#endif // USE_VLD

class TestClass
{
public:
    void doWork()
    {
        int* data = new int[10];
        // Do some work
        delete[] data;
    }
};
