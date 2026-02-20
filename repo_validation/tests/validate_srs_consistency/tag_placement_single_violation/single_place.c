// Production file with WRONG Tests_SRS_ tag (should be Codes_SRS_)
#include "my_module.h"

int my_function(void* param)
{
    /*Tests_SRS_SINGLE_PLACE_42_001: [ my_function shall validate parameters. ]*/
    if (param == NULL)
    {
        return -1;
    }
    return 0;
}
