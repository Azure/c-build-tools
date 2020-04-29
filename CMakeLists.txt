#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

cmake_minimum_required(VERSION 2.8.11)

project(azure_c_build_tools)

add_custom_target(azure_c_build_tools)

option(run_unittests "set run_unittests to ON to build unittests (default is OFF)" OFF)
option(run_e2e_tests "set run_e2e_tests to ON to build e2e tests (default is OFF)." OFF)
option(run_int_tests "set run_int_tests to ON to build integration tests (default is OFF)." OFF)
option(run_perf_tests "set run_int_tests to ON to build performance tests (default is OFF)." OFF)

if(WIN32)
    # warning C4200: nonstandard extension used: zero-sized array in struct/union : looks very standard in C99 and it is called flexible array. Documentation-wise is a flexible array, but called "unsized" in Microsoft's docs
    # https://msdn.microsoft.com/en-us/library/b6fae073.aspx
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /wd4200")
endif()

add_subdirectory(test_build_functions)
add_subdirectory(test_projects)
if(WIN32)
    add_subdirectory(traceabilitytool)
endif()
