// Test file with Tests_SRS_ tags (correct placement in _ut.c file)
#include "helper_module.h"

// Tests_SRS_HELPER_MODULE_01_001: [ helper_module_create shall allocate memory. ]
TEST_FUNCTION(when_all_ok_then_helper_module_create_allocates_memory)
{
    int result = helper_module_create();
    ASSERT_ARE_EQUAL(int, 0, result);
}
