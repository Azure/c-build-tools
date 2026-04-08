// Production file with one well-formed and one malformed tag
#include "my_module.h"

/*Codes_SRS_MALFORMED_TAG_88_001: [ my_function shall validate parameters. ]*/
int my_function(void* param)
{
    if (param == NULL)
    {
        return -1;
    }
    return 0;
}
