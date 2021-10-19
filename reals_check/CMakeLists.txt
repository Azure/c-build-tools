#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

add_custom_target(reals_check SOURCES reals_check.ps1)

if(${run_unittests} AND ${run_reals_check})
    add_subdirectory(test)
endif()
