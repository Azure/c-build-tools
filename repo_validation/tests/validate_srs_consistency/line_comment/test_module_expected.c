// Test module implementation with line-style SRS comments
// This tests that // comments are preserved correctly
#include <stdlib.h>

typedef struct TEST_MODULE_TAG {
    int value;
} TEST_MODULE;

TEST_MODULE* test_module_create(void) {
    TEST_MODULE* result;

    // Codes_SRS_LINE_COMMENT_TEST_02_001: [ test_module_create shall allocate memory for a test module. ]
    result = malloc(sizeof(TEST_MODULE));

    // Codes_SRS_LINE_COMMENT_TEST_02_002: [ test_module_create shall return NULL if allocation fails. ]
    if (result == NULL) {
        return NULL;
    }

    result->value = 0;
    return result;
}

void test_module_destroy(TEST_MODULE* module) {
    // Codes_SRS_LINE_COMMENT_TEST_02_003: [ test_module_destroy shall free all allocated memory. ]
    if (module != NULL) {
        free(module);
    }
}
