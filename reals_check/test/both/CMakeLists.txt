#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

set(reals_check_test_both_c_files
    ../reals/reals_dummy.c
    ../src/dummy.c
)

set(reals_check_test_both_h_files
    ../reals/reals_dummy.h
    ../inc/reals_check_test/dummy.h
)


include_directories(${CMAKE_CURRENT_LIST_DIR}/../inc)
include_directories(${CMAKE_CURRENT_LIST_DIR}/../reals)
include_directories(${CMAKE_CURRENT_LIST_DIR}/../src)

# creating library with both reals and original symbols
# adding _int_ to the name so that it is ignored in LIBS_TO_BE_REAL_CHECKED
add_library(reals_check_test_both_int_lib ${reals_check_test_both_c_files} ${reals_check_test_both_h_files})
target_link_libraries(reals_check_test_both_int_lib reals_check_test reals_check_test_reals)
target_include_directories(reals_check_test_both_int_lib PUBLIC $<BUILD_INTERFACE:${PROJECT_SOURCE_DIR}/reals_check/test/both>)
