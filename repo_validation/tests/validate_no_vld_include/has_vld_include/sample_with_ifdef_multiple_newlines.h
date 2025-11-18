// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file tests vld.h with multiple newlines between #ifdef, include, and #endif

#ifndef SAMPLE_WITH_IFDEF_MULTIPLE_NEWLINES_H
#define SAMPLE_WITH_IFDEF_MULTIPLE_NEWLINES_H

#include <stdint.h>


#ifdef USE_VLD



#include "vld.h"



#endif


typedef struct MY_STRUCT_TAG
{
    int id;
    const char* name;
} MY_STRUCT;

#endif // SAMPLE_WITH_IFDEF_MULTIPLE_NEWLINES_H
