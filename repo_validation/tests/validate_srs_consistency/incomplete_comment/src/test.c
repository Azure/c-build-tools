// Test file with incomplete SRS comment

#include <stdlib.h>

void* test_function(void* param)
{
    /*Codes_SRS_TEST_MODULE_01_001: [If param is NULL then test_function shall fail and return NULL. */
    if (param == NULL)
    {
        return NULL;
    }
    
    /*Codes_SRS_TEST_MODULE_01_002: [If any character has the value outside [1...127] */
    void* result = malloc(sizeof(int));
    
    return result;
}
