// Sample file verifying backticks OUTSIDE of SRS requirements are ignored
// This should PASS validation since only backticks inside SRS [...] are checked

// This comment has a `backtick` but it's not an SRS requirement
void func_with_comment(void)
{
    // Call `some_function` here - backticks in regular comments are fine
}

/*Codes_SRS_CLEAN_MODULE_02_001: [ The function shall succeed. ]*/
// The above SRS requirement has no backticks and should pass
void clean_srs_func(void)
{
    // `backticks` in implementation comments are fine
}
