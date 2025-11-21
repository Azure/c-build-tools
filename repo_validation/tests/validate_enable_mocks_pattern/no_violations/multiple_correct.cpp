// Test file with multiple correct ENABLE_MOCKS patterns
// Copyright (c) Microsoft. All rights reserved.

#include "another_header.h"

// First mock section
#include "umock_c/umock_c_ENABLE_MOCKS.h" // ============================== ENABLE_MOCKS
#include "c_pal/gballoc_hl.h"
#include "umock_c/umock_c_DISABLE_MOCKS.h" // ============================== DISABLE_MOCKS

#include "real_gballoc_hl.h"

// Second mock section
#include "umock_c/umock_c_ENABLE_MOCKS.h" // ============================== ENABLE_MOCKS
#include "c_util/rc_string.h"
#include "umock_c/umock_c_DISABLE_MOCKS.h" // ============================== DISABLE_MOCKS

#include "my_module.h"

int another_test_function(void)
{
    return 0;
}
