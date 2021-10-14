#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

set(reals_check_test_reals_c_files
    reals_dummy.c
)

set(reals_check_test_reals_h_files
    reals_dummy.h
    reals_dummy_renames.h
)

include_directories(${CMAKE_CURRENT_LIST_DIR}/../src)
include_directories(${CMAKE_CURRENT_LIST_DIR}/../inc)
add_library(reals_check_test_reals ${reals_check_test_reals_c_files} ${reals_check_test_reals_h_files})
target_include_directories(reals_check_test_reals PUBLIC $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/reals_check/test/reals>)
