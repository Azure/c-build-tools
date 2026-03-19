// Production file with WRONG Tests_SRS_ tags (should be Codes_SRS_)
#include "my_module.h"

int my_function(void* param)
{
    /*Tests_SRS_TAG_PLACE_42_001: [ my_function shall validate parameters. ]*/
    if (param == NULL)
    {
        return -1;
    }
    else
    {
        /*Codes_SRS_TAG_PLACE_42_002: [ my_function shall allocate memory. ]*/
        void* mem = malloc(sizeof(int));
        if (mem == NULL)
        {
            return -1;
        }
        else
        {
            return 0;
        }
    }
}
