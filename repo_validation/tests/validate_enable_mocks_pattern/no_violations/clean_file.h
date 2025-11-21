// Test header with correct ENABLE_MOCKS pattern using includes
// Copyright (c) Microsoft. All rights reserved.

#ifndef CLEAN_FILE_H
#define CLEAN_FILE_H

#include <stdint.h>

#include "umock_c/umock_c_ENABLE_MOCKS.h" // ============================== ENABLE_MOCKS
#include "c_pal/interlocked.h"
#include "umock_c/umock_c_DISABLE_MOCKS.h" // ============================== DISABLE_MOCKS

#include "real_interlocked.h"

int test_function(void);

#endif // CLEAN_FILE_H
