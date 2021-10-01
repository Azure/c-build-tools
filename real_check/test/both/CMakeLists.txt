#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.
set(real_check_test_both_c_files
    ../reals/real_dummy.c
    ../src/dummy.c
)

set(real_check_test_both_h_files
    ../reals/real_dummy.h
    ../inc/real_check_test/dummy.h
)


include_directories(${CMAKE_CURRENT_LIST_DIR}/../inc)
include_directories(${CMAKE_CURRENT_LIST_DIR}/../reals)
include_directories(${CMAKE_CURRENT_LIST_DIR}/../src)

add_library(real_check_test_both ${real_check_test_both_c_files} ${real_check_test_both_h_files})
target_link_libraries(real_check_test_both real_check_test real_check_test_reals)
target_include_directories(real_check_test_both PUBLIC $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/real_check/test/both>)
