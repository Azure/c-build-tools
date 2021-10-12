#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

if(${run_unittests})
    add_subdirectory(test)
endif()

add_custom_target(realcheck SOURCES real_check.ps1)
