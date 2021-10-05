#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

add_subdirectory(reals)
add_subdirectory(both)

set(real_check_test_c_files
    ./src/dummy.c
)

set(real_check_test_h_files
    ./inc/real_check_test/dummy.h
)

add_library(real_check_test ${real_check_test_c_files} ${real_check_test_h_files} ${c_util_md_files})
target_include_directories(real_check_test PUBLIC $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/real_check/test/inc>)

add_test(NAME RUN_REAL_CHECK_TEST COMMAND powershell ${CMAKE_CURRENT_SOURCE_DIR}/test_real_check.ps1 ${CMAKE_CURRENT_SOURCE_DIR}/../real_check.ps1 ${CMAKE_BINARY_DIR} $<CONFIG>)
