#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

add_subdirectory(reals)
add_subdirectory(both)
set(REAL_CHECK_TEST_INC_FOLDER ${CMAKE_CURRENT_LIST_DIR}/inc CACHE INTERNAL "this is what needs to be included if using sharedLib lib" FORCE)

set(real_check_test_c_files
    ./src/dummy.c
)

set(real_check_test_h_files
    ./inc/real_check_test/dummy.h
)

add_library(real_check_test ${real_check_test_c_files} ${real_check_test_h_files} ${c_util_md_files})
target_include_directories(real_check_test PUBLIC $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/real_check/test/inc>)
