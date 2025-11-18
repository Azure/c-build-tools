// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file tests vld.h with various spacing in #ifdef blocks

#ifndef SAMPLE_WITH_IFDEF_SPACES_H
#define SAMPLE_WITH_IFDEF_SPACES_H

#include <stdint.h>

#ifdef USE_VLD

#include "vld.h"

#endif

typedef struct MY_DATA_TAG
{
    int value;
    char* name;
} MY_DATA;

extern void process_data(MY_DATA* data);

#endif // SAMPLE_WITH_IFDEF_SPACES_H
