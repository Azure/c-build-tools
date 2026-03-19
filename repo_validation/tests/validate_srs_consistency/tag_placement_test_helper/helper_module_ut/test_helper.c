// Test helper file inside _ut directory with Tests_SRS_ tags
// This file is not named _ut.c but resides in a _ut directory,
// so Tests_SRS_ tags should be allowed here.
#include "helper_module.h"

/*Tests_SRS_HELPER_MODULE_01_002: [ helper_module_create shall initialize the module. ]*/
DEFINE_TEST_HELPER(helper_module_create)
{
    return 0;
}
