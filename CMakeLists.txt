#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

if(NOT DEFINED CMAKE_MINIMUM_REQUIRED_VERSION)
    cmake_minimum_required(VERSION 3.31) #3.31 comes default with Visual Studio 2022 17.14.0 which we are using (16 May 2025). also changes the policy CMP0177 (for the better)
    #cmake_minimum_required(VERSION 3.24) #3.24 brings in support for WHOLE_ARCHIVE which is needed for vld
endif()

cmake_policy(SET CMP0177 NEW) #cmake --help-policy CMP0177

# canon way of using build_tools from another repo is below. It assumes the using repo has placed c-build-tools in "deps"

#if ((NOT TARGET c_build_tools) AND (EXISTS ${CMAKE_CURRENT_LIST_DIR}/deps/c-build-tools/CMakeLists.txt))
#    add_subdirectory(deps/c-build-tools)
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
option(build_traceability_tool "build traceability tool (default is ON)" ON)
option(run_reals_check "run reals check tool (default is OFF)" OFF)
option(use_vld "use VLD for leak detection (default is OFF)" OFF)
option(fsanitize_address "enable /fsanitize=address compiler switch (default is OFF)" OFF) # see https://docs.microsoft.com/en-us/cpp/build/reference/fsanitize
option(build_csharp_projects "Build csharp projects? (default is ON)" ON)
option(build_sarif_results_checker "Build Sarif results checker? (default is ON)" ON)
option(use_ltcg "use link time code generation (default is ON)" ON)
option(use_guard_cf "use /guard:cf compiler switch (default is ON). Set this to OFF to workaround not stepping into functions through function pointers." ON)

# BUILD_BINARIESDIRECTORY is an environment variable used to designate where the binaries resulting from the build go
# It exists because we usually build using Azure DevOps (it maps to the Build.BinariesDirectory predefined variable of DevOps: https://learn.microsoft.com/en-us/azure/devops/pipelines/build/variables?view=azure-devops&tabs=yaml)
# Set this to a folder where all build binaries will be placed
if ("$ENV{BUILD_BINARIESDIRECTORY}" STREQUAL "")
    message(WARNING "BUILD_BINARIESDIRECTORY not defined!")
else()
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG $ENV{BUILD_BINARIESDIRECTORY}/Debug)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE $ENV{BUILD_BINARIESDIRECTORY}/Release)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO $ENV{BUILD_BINARIESDIRECTORY}/RelWithDebInfo)
    set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL $ENV{BUILD_BINARIESDIRECTORY}/MinSizeRel)
endif()

add_subdirectory(build_functions)

enable_testing()

include (CheckIncludeFiles)

CHECK_INCLUDE_FILES(stdint.h HAVE_STDINT_H)
CHECK_INCLUDE_FILES(stdbool.h HAVE_STDBOOL_H)

set_default_build_options()

#build a linkable lib called use_vld that can be indicated to targets as "to link with" rather than compiling "use_vld.c" in every target
if(${use_vld})
    add_library(use_vld STATIC build_functions/use_vld.c)
endif()


#vld and address sanitizer do not play nice with each other (stack overflow will happen)
if(${fsanitize_address} AND ${use_vld})
    MESSAGE(FATAL_ERROR "using both \${fsanitize_address}=${fsanitize_address} and \${use_vld}=${use_vld} at the same time will result in stack overflow. Refusing to generate.")
endif()

# Skip for Ninja which can't build the C# project
if (WIN32 AND (CMAKE_GENERATOR MATCHES "Visual Studio"))
    if((${build_traceability_tool}) AND (${build_csharp_projects}))
        add_subdirectory(traceabilitytool)
    endif()
    add_subdirectory(reals_check)
endif()

if((CMAKE_GENERATOR MATCHES "Visual Studio") AND (${build_sarif_results_checker}))
    add_subdirectory(sarif_results_checker)
endif()

#Insert vld in all executables if so required
add_vld_if_defined(${CMAKE_CURRENT_SOURCE_DIR})