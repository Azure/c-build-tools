// Sample file with SRS requirements containing backticks (should FAIL validation)
// This simulates copy-pasted requirements with markdown backticks

/*Codes_SRS_SAMPLE_MODULE_01_001: [ The function shall call `do_something`. ]*/
void test_func1(void)
{
    // implementation
}

/*Codes_SRS_SAMPLE_MODULE_01_002: [ The function shall set the state to `active`. ]*/
void test_func2(void)
{
    // implementation
}

// This one has trailing backtick like the real-world issue
/*Codes_SRS_SAMPLE_MODULE_01_003: [ The function shall call sm_fault`. ]*/
void test_func3(void)
{
    // implementation
}
