// Test file with deprecated #define ENABLE_MOCKS pattern
// Copyright (c) Microsoft. All rights reserved.

#include "some_header.h"

#define ENABLE_MOCKS
#include "c_pal/gballoc_hl.h"
#include "c_util/rc_string.h"
#undef ENABLE_MOCKS

#include "my_module.h"

// Rest of the test file
int test_function(void)
{
    return 0;
}
