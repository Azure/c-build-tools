#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

add_subdirectory(reals)
add_subdirectory(both)

set(reals_check_test_c_files
    ./src/dummy.c
)

set(reals_check_test_h_files
    ./inc/reals_check_test/dummy.h
)

add_library(reals_check_test ${reals_check_test_c_files} ${reals_check_test_h_files})
target_include_directories(reals_check_test PUBLIC $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/reals_check/test/inc>)

add_test(NAME RUN_REALS_CHECK_TEST COMMAND powershell ${CMAKE_CURRENT_SOURCE_DIR}/test_reals_check.ps1 ${CMAKE_CURRENT_SOURCE_DIR}/../reals_check.ps1 ${CMAKE_BINARY_DIR} $<CONFIG>)
