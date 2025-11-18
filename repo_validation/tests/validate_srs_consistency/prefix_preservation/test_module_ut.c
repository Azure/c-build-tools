// Test module unit tests to verify Tests_ prefix preservation
#include <stddef.h>

// Mock test framework
#define TEST_FUNCTION(name) void name(void)
#define ASSERT_IS_NOT_NULL(x) if (x == NULL) return

TEST_FUNCTION(test_module_create_success) {
    // arrange
    TEST_MODULE* module;

    // act
    /* Tests_SRS_PREFIX_TEST_66_001: [ test_module_create shall allocate memory for a test module. ]*/
    module = test_module_create();

    // assert
    /* Tests_SRS_PREFIX_TEST_66_002: [ test_module_create shall return NULL if allocation fails. ]*/
    ASSERT_IS_NOT_NULL(module);

    // cleanup
    test_module_destroy(module);
}

TEST_FUNCTION(test_module_process_validates_input) {
    // arrange
    TEST_MODULE* module = test_module_create();

    // act & assert
    /* Tests_SRS_PREFIX_TEST_66_004: [ test_module_process shall validate the input parameter. ]*/
    int result = test_module_process(module, NULL);

    // cleanup
    test_module_destroy(module);
}
