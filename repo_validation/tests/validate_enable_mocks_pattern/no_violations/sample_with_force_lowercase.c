// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file uses the deprecated #define/#undef ENABLE_MOCKS pattern with "// force" comment
// The validation script should ignore these patterns

#include "some_header.h"

#define ENABLE_MOCKS  // force
#include "c_pal/gballoc_hl.h"
#include "c_util/rc_string.h"
#undef ENABLE_MOCKS  // force

#include "my_module.h"

int test_function_with_force(void)
{
    return 0;
}
