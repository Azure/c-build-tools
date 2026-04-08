// Test file with one malformed SRS tag (dash instead of colon, no brackets)
// Tests_SRS_MALFORMED_TAG_88_001: [ my_function shall validate parameters. ]
TEST_FUNCTION(when_param_is_NULL_then_my_function_fails)
{
    int result = my_function(NULL);
    ASSERT_ARE_NOT_EQUAL(int, 0, result);
}

// Tests_SRS_MALFORMED_TAG_88_002 - not a test, but documenting that ICE fail guard path is not testable from public API
