// Test module implementation with inconsistent SRS tags
#include <stdlib.h>
#include "test_module.h"

typedef struct TEST_MODULE_TAG {
    int initialized;
    char* data;
} TEST_MODULE;

TEST_MODULE_HANDLE test_module_create(void) {
    TEST_MODULE* result;
    
    /* Codes_SRS_TEST_MODULE_66_001: [ test_module_create shall allocate memory for a new test module instance. ]*/
    result = malloc(sizeof(TEST_MODULE));
    
    /* Codes_SRS_TEST_MODULE_66_002: [ If memory allocation fails, test_module_create shall return NULL. ]*/
    if (result == NULL) {
        // Memory allocation failed
    }
    else {
        /* Codes_SRS_TEST_MODULE_66_003: [ On success, test_module_create shall initialize all fields to their initial values. ]*/
        result->initialized = 1;
        result->data = NULL;
    }
    
    return result;
}