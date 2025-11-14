// Test module implementation with line-style SRS comments
// This tests that // comments are preserved correctly
#include <stdlib.h>

typedef struct TEST_MODULE_TAG {
    int value;
} TEST_MODULE;

TEST_MODULE* test_module_create(void) {
    TEST_MODULE* result;

    // Codes_SRS_LINE_COMMENT_TEST_02_001: [ allocate memory - WRONG TEXT ]
    result = malloc(sizeof(TEST_MODULE));

    // Codes_SRS_LINE_COMMENT_TEST_02_002: [ return NULL - WRONG TEXT ]
    if (result == NULL) {
        return NULL;
    }

    result->value = 0;
    return result;
}

void test_module_destroy(TEST_MODULE* module) {
    // Codes_SRS_LINE_COMMENT_TEST_02_003: [ free memory - WRONG TEXT ]
    if (module != NULL) {
        free(module);
    }
}
