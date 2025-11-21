// Test header with deprecated #define ENABLE_MOCKS pattern
// Copyright (c) Microsoft. All rights reserved.

#ifndef TEST_FILE_H
#define TEST_FILE_H

#include <stdint.h>

#define ENABLE_MOCKS
#include "c_pal/interlocked.h"
#undef ENABLE_MOCKS

#include "real_interlocked.h"

int test_function(void);

#endif // TEST_FILE_H
