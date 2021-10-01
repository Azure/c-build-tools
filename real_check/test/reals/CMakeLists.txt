#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.
set(real_check_test_reals_c_files
    real_dummy.c
)

set(real_check_test_reals_h_files
    real_dummy.h
    real_dummy_renames.h
)

include_directories(${CMAKE_CURRENT_LIST_DIR}/../src)
include_directories(${CMAKE_CURRENT_LIST_DIR}/../inc)
add_library(real_check_test_reals ${real_check_test_reals_c_files} ${real_check_test_reals_h_files})
target_include_directories(real_check_test_reals PUBLIC $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/real_check/test/reals>)
