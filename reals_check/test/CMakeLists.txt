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

# Adding libs that should get ignored for reals check
add_library(random_int_lib ./dummy_source.c)
add_library(random_ut_dll SHARED ./dummy_source.c)
add_library(random_perf_lib ./dummy_source.c)
add_library(random_interface_lib INTERFACE ./dummy_source.c)

set(expected_value ";reals_check_test_reals;reals_check_test")

# adding reals check target for automatic checking
add_reals_check_target()

# Test to check that the correct libraries are selected for reals checking:
if(NOT "${LIBS_TO_BE_REAL_CHECKED}" STREQUAL "${expected_value}")
    message(FATAL_ERROR "LIBS_TO_BE_REAL_CHECKED does not contain the correct value.\nExpected value: ${expected_value}\nActual value: ${LIBS_TO_BE_REAL_CHECKED}")
endif()
