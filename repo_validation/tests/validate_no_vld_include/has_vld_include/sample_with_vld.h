// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file intentionally includes vld.h with different syntax to test the validation script

#ifndef SAMPLE_WITH_VLD_H
#define SAMPLE_WITH_VLD_H

#include <stdint.h>
#  include <vld.h>

typedef struct MY_DATA_TAG
{
    int value;
    char* name;
} MY_DATA;

extern void process_data(MY_DATA* data);

#endif // SAMPLE_WITH_VLD_H
