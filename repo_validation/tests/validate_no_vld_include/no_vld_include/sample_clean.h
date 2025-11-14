// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file does NOT include vld.h and should pass validation

#ifndef SAMPLE_CLEAN_H
#define SAMPLE_CLEAN_H

#include <stdint.h>
#include <stdbool.h>

typedef struct MY_CLEAN_DATA_TAG
{
    int value;
    char* name;
} MY_CLEAN_DATA;

extern void process_clean_data(MY_CLEAN_DATA* data);

#endif // SAMPLE_CLEAN_H
