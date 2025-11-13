// Test module unit tests to verify Tests_ prefix preservation
#include <stddef.h>

// Mock test framework
#define TEST_FUNCTION(name) void name(void)
#define ASSERT_IS_NOT_NULL(x) if (x == NULL) return

TEST_FUNCTION(test_module_create_success) {
    // arrange
    TEST_MODULE* module;

    // act
    /* Tests_SRS_PREFIX_TEST_01_001: [ WRONG TEXT - will be fixed but prefix should stay Tests_ ]*/
    module = test_module_create();

    // assert
    /* Tests_SRS_PREFIX_TEST_01_002: [ WRONG TEXT - prefix must remain Tests_ after fix ]*/
    ASSERT_IS_NOT_NULL(module);

    // cleanup
    test_module_destroy(module);
}

TEST_FUNCTION(test_module_process_validates_input) {
    // arrange
    TEST_MODULE* module = test_module_create();

    // act & assert
    /* Tests_SRS_PREFIX_TEST_01_004: [ WRONG TEXT - should be fixed keeping Tests_ prefix ]*/
    int result = test_module_process(module, NULL);

    // cleanup
    test_module_destroy(module);
}
