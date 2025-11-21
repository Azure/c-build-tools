// Test file with correct ENABLE_MOCKS pattern using includes
// Copyright (c) Microsoft. All rights reserved.

#include "some_header.h"

#include "umock_c/umock_c_ENABLE_MOCKS.h" // ============================== ENABLE_MOCKS
#include "c_pal/gballoc_hl.h"
#include "c_util/rc_string.h"
#include "umock_c/umock_c_DISABLE_MOCKS.h" // ============================== DISABLE_MOCKS

#include "my_module.h"

// Rest of the test file
int test_function(void)
{
    return 0;
}
