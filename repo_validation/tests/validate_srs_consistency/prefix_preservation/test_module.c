// Test module implementation to verify Codes_ prefix preservation
#include <stdlib.h>

typedef struct TEST_MODULE_TAG {
    int value;
} TEST_MODULE;

TEST_MODULE* test_module_create(void) {
    TEST_MODULE* result;

    /* Codes_SRS_PREFIX_TEST_66_001: [ WRONG TEXT - will be fixed but prefix should stay Codes_ ]*/
    result = malloc(sizeof(TEST_MODULE));

    /* Codes_SRS_PREFIX_TEST_66_002: [ WRONG TEXT - prefix must remain Codes_ after fix ]*/
    if (result == NULL) {
        return NULL;
    }

    result->value = 0;
    return result;
}

void test_module_destroy(TEST_MODULE* module) {
    /* Codes_SRS_PREFIX_TEST_66_003: [ WRONG TEXT - should be fixed keeping Codes_ prefix ]*/
    if (module != NULL) {
        free(module);
    }
}
