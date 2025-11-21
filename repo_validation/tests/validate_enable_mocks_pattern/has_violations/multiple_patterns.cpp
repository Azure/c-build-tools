// Test file with multiple deprecated patterns
// Copyright (c) Microsoft. All rights reserved.

#include "another_header.h"

// First mock section
#define ENABLE_MOCKS
#include "c_pal/gballoc_hl.h"
#undef ENABLE_MOCKS

#include "real_gballoc_hl.h"

// Second mock section
#define ENABLE_MOCKS
#include "c_util/rc_string.h"
#undef ENABLE_MOCKS

#include "my_module.h"

int another_test_function(void)
{
    return 0;
}
