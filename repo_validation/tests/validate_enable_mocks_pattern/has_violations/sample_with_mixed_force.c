// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

// This file has mixed patterns:
// - Some with //force that should be ignored
// - Some without //force that should be flagged as violations

#include "some_header.h"

// This one should be flagged as a violation
#define ENABLE_MOCKS
#include "c_pal/gballoc_hl.h"
#undef ENABLE_MOCKS

// This one should be ignored (has //force)
#define ENABLE_MOCKS  // force
#include "c_util/rc_string.h"
#undef ENABLE_MOCKS  // force

// This one should be flagged as a violation
#define ENABLE_MOCKS
#include "azure_c_shared_utility/map.h"
#undef ENABLE_MOCKS

#include "my_module.h"

int test_function_mixed(void)
{
    return 0;
}
