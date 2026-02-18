// Test file with correct Tests_SRS_ tags
#include "my_module.h"

// Tests_SRS_TAG_PLACE_42_001: [ my_function shall validate parameters. ]
TEST_FUNCTION(when_param_is_NULL_then_my_function_fails)
{
    int result = my_function(NULL);
    ASSERT_ARE_NOT_EQUAL(int, 0, result);
}

// Tests_SRS_TAG_PLACE_42_002: [ my_function shall allocate memory. ]
TEST_FUNCTION(when_all_ok_then_my_function_succeeds)
{
    int result = my_function(&some_value);
    ASSERT_ARE_EQUAL(int, 0, result);
}
