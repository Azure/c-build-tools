#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

if(NOT DEFINED CMAKE_MINIMUM_REQUIRED_VERSION)
    cmake_minimum_required(VERSION 3.18)
endif()

# canon way of using build_tools from another repo is below. It assumes the using repo has placed c-build-tools in "deps"

#if ((NOT TARGET c_build_tools) AND (EXISTS ${CMAKE_CURRENT_LIST_DIR}/deps/c-build-tools/CMakeLists.txt))
#    add_subdirectory(deps/c-build-tools)
#    set_default_build_options()
#endif()

if(TARGET c_build_tools)
    return()
endif()

add_custom_target(c_build_tools)

project(c_build_tools)

option(run_unittests "set run_unittests to ON to build unittests (default is OFF)" OFF)
option(run_e2e_tests "set run_e2e_tests to ON to build e2e tests (default is OFF)." OFF)
option(run_int_tests "set run_int_tests to ON to build integration tests (default is OFF)." OFF)
option(run_perf_tests "set run_perf_tests to ON to build performance tests (default is OFF)." OFF)
option(use_segment_heap "Use segment heap on Windows as opposed to regular NT heap (default is ON)." ON)
option(run_valgrind "run valgrind on tests (Linux only) (default is ON)." ON)
option(run_helgrind "run helgrind on tests (Linux only) (default is ON)." ON)
option(run_drd "run DRD on tests (Linux only) (default is OFF)." OFF)
option(run_traceability "run traceability tool (default is ON)" ON)

add_subdirectory(build_functions)
add_subdirectory(test_projects)
# Skip for Ninja which can't build the C# project
if (WIN32 AND (CMAKE_GENERATOR MATCHES "Visual Studio"))
    add_subdirectory(traceabilitytool)
endif()
