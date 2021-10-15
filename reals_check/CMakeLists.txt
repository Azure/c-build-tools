#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

if(${run_reals_check})
    if(NOT WIN32)
        message(FATAL_ERROR "Cannot run reals check for non-Windows build.")
    endif()
    add_custom_target(reals_check SOURCES reals_check.ps1)
endif()

if(${run_unittests})
    add_subdirectory(test)
endif()
