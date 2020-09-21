#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

set(build_c_tests_internal_dir ${CMAKE_CURRENT_LIST_DIR} CACHE INTERNAL "")

include(CheckSymbolExists)
function(detect_architecture symbol arch)
    if (NOT DEFINED ARCHITECTURE OR ARCHITECTURE STREQUAL "")
        set(CMAKE_REQUIRED_QUIET 1)
        check_symbol_exists("${symbol}" "" ARCHITECTURE_${arch})
        unset(CMAKE_REQUIRED_QUIET)

        # The output variable needs to be unique across invocations otherwise
        # CMake's crazy scope rules will keep it defined
        if (ARCHITECTURE_${arch})
            set(ARCHITECTURE "${arch}" CACHE INTERNAL "target architecture" FORCE)
            set(ARCHITECTURE_${arch} 1 CACHE INTERNAL "target architecture" FORCE)
            add_definitions(-DARCHITECTURE_${arch}=1)
        endif()
    endif()
endfunction()

if (MSVC)
    detect_architecture("_M_AMD64" x86_64)
    detect_architecture("_M_IX86" x86)
    detect_architecture("_M_ARM" ARM)
else()
    detect_architecture("__x86_64__" x86_64)
    detect_architecture("__i386__" x86)
    detect_architecture("__arm__" ARM)
endif()
if (NOT DEFINED ARCHITECTURE OR ARCHITECTURE STREQUAL "")
    set(ARCHITECTURE "GENERIC" CACHE INTERNAL "target architecture" FORCE)
endif()

message(STATUS "target architecture: ${ARCHITECTURE}")

function(target_link_libraries_with_arg_prefix arg_prefix whatIsBuilding lib)
    if(${arg_prefix} STREQUAL "debug")
        target_link_libraries(${whatIsBuilding} debug ${lib})
    elseif(${arg_prefix} STREQUAL "optimized")
        target_link_libraries(${whatIsBuilding} optimized ${lib})
    elseif(${arg_prefix} STREQUAL "general")
        target_link_libraries(${whatIsBuilding} general ${lib})
    else()
        target_link_libraries(${whatIsBuilding} ${lib})
    endif()
endfunction()

########################################################################
########################################################################
########################################################################
########################################################################
########################################################################
########################################################################


function(build_lib whatIsBuilding solution_folder)
    
    if(
        ("${${whatIsBuilding}_c_files}" STREQUAL "") AND
        ("${${whatIsBuilding}_cpp_files}" STREQUAL "")
    )
        #for those cases when there are 0 other files except the .c file containing the tests. This is a bit less than ideal because a lib is still created and it is still linked against. To be improved at a later time.
        add_library(${whatIsBuilding}_lib 
            ${build_c_tests_internal_dir}/nothing.c
        )
        
    else()
        add_library(${whatIsBuilding}_lib 
            ${${whatIsBuilding}_c_files}
            ${${whatIsBuilding}_h_files}
            ${${whatIsBuilding}_cpp_files}
        )
        
    endif()
    
    set_target_properties(${whatIsBuilding}_lib
           PROPERTIES
           FOLDER ${solution_folder})
           
    set(PARSING_ADDITIONAL_LIBS OFF)
    set(PARSING_VALGRIND_SUPPRESSIONS_FILE OFF)
    set(VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER)
    set(ARG_PREFIX "none")
    foreach(f ${ARGN}) 
        set(skip_to_next FALSE)
        if(${f} STREQUAL "ADDITIONAL_LIBS")
            SET(PARSING_ADDITIONAL_LIBS ON)
            SET(PARSING_VALGRIND_SUPPRESSIONS_FILE OFF)
            set(ARG_PREFIX "none")
            #also unset all the other states
            set(skip_to_next TRUE)
        elseif(${f} STREQUAL "VALGRIND_SUPPRESSIONS_FILE")
            SET(PARSING_ADDITIONAL_LIBS OFF)
            SET(PARSING_VALGRIND_SUPPRESSIONS_FILE ON)
            set(skip_to_next TRUE)
        endif()

        if(NOT skip_to_next)
            if(PARSING_ADDITIONAL_LIBS)
                if((${f} STREQUAL "debug") OR (${f} STREQUAL "optimized") OR (${f} STREQUAL "general"))
                    SET(ARG_PREFIX ${f})
                else()
                    target_link_libraries_with_arg_prefix(${ARG_PREFIX} ${whatIsBuilding}_lib ${f})
                    set(ARG_PREFIX "none")
                endif()
            endif()
        endif()

    endforeach()
endfunction()

function(build_dll whatIsBuilding solution_folder)

    #lazily build _lib which is needed by both exe and dll
    if(NOT TARGET ${whatIsBuilding}_lib)
        build_lib(${whatIsBuilding} ${solution_folder} ${ARGN})
    endif()
    
    #this is the .dll run by visual studio's test runner
    add_library(${whatIsBuilding}_dll SHARED
        ${${whatIsBuilding}_test_files}
    )
    
    #make sure to compile the test file as C++!
    set_source_files_properties(${${whatIsBuilding}_test_files} PROPERTIES LANGUAGE CXX)
    
    #link with the common lib (exe an dll share the lib part)
    target_link_libraries(${whatIsBuilding}_dll ${whatIsBuilding}_lib)
    
    link_directories(${whatIsBuilding}_dll $ENV{VCInstallDir}UnitTest/lib)

    target_include_directories(${whatIsBuilding}_dll PUBLIC ${sharedutil_include_directories} $ENV{VCInstallDir}UnitTest/include)
    target_compile_definitions(${whatIsBuilding}_dll PUBLIC -DCPP_UNITTEST)
    target_compile_options(${whatIsBuilding}_dll PUBLIC /EHsc)

    set_target_properties(${whatIsBuilding}_dll
               PROPERTIES
               FOLDER ${solution_folder})
    
    if (TARGET azure_c_logging)
        target_link_libraries(${whatIsBuilding}_dll azure_c_logging)
    endif()
    if (TARGET umock_c)
        target_link_libraries(${whatIsBuilding}_dll umock_c)
    endif()
    if (TARGET ctest)
        target_link_libraries(${whatIsBuilding}_dll ctest)
    endif()
    if (TARGET testrunnerswitcher)
        target_link_libraries(${whatIsBuilding}_dll testrunnerswitcher)
    endif()
    
endfunction()

function(build_exe whatIsBuilding solution_folder)
    
    #lazily build _lib which is needed by both exe and dll
    if(NOT TARGET ${whatIsBuilding}_lib)
        build_lib(${whatIsBuilding} ${solution_folder} ${ARGN})
    endif()
    
    #this is the exe run by ctest (or directly from visual studio)
    add_executable(${whatIsBuilding}_exe
        ${${whatIsBuilding}_test_files}
        main.c
    )
    
    #make sure to compile the test file as C!
    set_source_files_properties(${whatIsBuilding}_test_files PROPERTIES LANGUAGE C)
    
    #link with the common lib (exe an dll share the lib part)
    target_link_libraries(${whatIsBuilding}_exe ${whatIsBuilding}_lib)
    
    set_target_properties(${whatIsBuilding}_exe
               PROPERTIES
               FOLDER ${solution_folder})
    
    target_compile_definitions(${whatIsBuilding}_exe PUBLIC -DUSE_CTEST)
    target_include_directories(${whatIsBuilding}_exe PUBLIC ${sharedutil_include_directories})
    
    if (TARGET azure_c_logging)
        target_link_libraries(${whatIsBuilding}_exe azure_c_logging)
    endif()
    if (TARGET umock_c)
        target_link_libraries(${whatIsBuilding}_exe umock_c)
    endif()
    if (TARGET ctest)
        target_link_libraries(${whatIsBuilding}_exe ctest)
    endif()
    if (TARGET testrunnerswitcher)
        target_link_libraries(${whatIsBuilding}_exe testrunnerswitcher)
    endif()

    #register the exe with ctest's list of tests
    add_test(NAME ${whatIsBuilding} COMMAND ${whatIsBuilding}_exe)

    if(UNIX) #LINUX OR APPLE
        if(${run_valgrind})
            find_program(VALGRIND_FOUND NAMES valgrind)
            if(${VALGRIND_FOUND} STREQUAL VALGRIND_FOUND-NOTFOUND)
                message(WARNING "run_valgrind was TRUE, but valgrind was not found - there will be no tests run under valgrind")
            else()
                add_test(NAME ${whatIsBuilding}_valgrind COMMAND valgrind                 --gen-suppressions=all --num-callers=100 --error-exitcode=1 --leak-check=full --track-origins=yes ${VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER} $<TARGET_FILE:${whatIsBuilding}_exe>)
                add_test(NAME ${whatIsBuilding}_helgrind COMMAND valgrind --tool=helgrind --gen-suppressions=all --num-callers=100 --error-exitcode=1 ${VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER} $<TARGET_FILE:${whatIsBuilding}_exe>)
                add_test(NAME ${whatIsBuilding}_drd      COMMAND valgrind --tool=drd      --gen-suppressions=all --num-callers=100 --error-exitcode=1 ${VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER} $<TARGET_FILE:${whatIsBuilding}_exe>)
            endif()
        endif()
    endif()
endfunction()

#drop in replacement for add_subdirectory :)
function(build_test_folder test_folder)

    if(
        (("${test_folder}" MATCHES ".*ut.*") AND ${run_unittests}) OR
        (("${test_folder}" MATCHES ".*e2e.*") AND ${run_e2e_tests}) OR
        (("${test_folder}" MATCHES ".*int.*") AND ${run_int_tests}) OR
        (("${test_folder}" MATCHES ".*perf.*") AND ${run_perf_tests})
    )
    
        set(BINARY_DIR) #BINARY_DIR is added to every target (because targets need to have different names).
        set(PARSING_BINARY_DIR OFF) #see https://cmake.org/cmake/help/latest/command/add_subdirectory.html for "binary_dir"
        
        foreach(f ${ARGN})
            if(${f} STREQUAL "BINARY_DIR")
                set(PARSING_BINARY_DIR ON)
            elseif(PARSING_BINARY_DIR)
                set(BINARY_DIR ${f})
                set(PARSING_BINARY_DIR OFF)
            endif()
            
        endforeach()
        
        set(building exe)
        add_subdirectory(${test_folder} ${test_folder}/${BINARY_DIR}/${building})
        
        if ((${use_cppunittest}) AND (WIN32))
            set(building dll)
            add_subdirectory(${test_folder} ${test_folder}/${BINARY_DIR}/${building})
        endif()
    else()
        #message("test_folder is ${test_folder} NOT BUILDING")
    endif()
 
endfunction()

#drop in replacement for build_c_tests :)
function(build_test_artifacts whatIsBuilding use_gballoc solution_folder )
    if(${use_gballoc})
        add_definitions(-DGB_MEASURE_MEMORY_FOR_THIS -DGB_DEBUG_ALLOC)
    endif()
    
    if(${building} STREQUAL "lib")
        build_lib(${whatIsBuilding} ${solution_folder} ${ARGN}) 
    elseif(${building} STREQUAL "dll")
        build_dll(${whatIsBuilding} ${solution_folder} ${ARGN})
    elseif(${building} STREQUAL "exe")
        build_exe(${whatIsBuilding} ${solution_folder} ${ARGN})
    else()
        MESSAGE(FATAL_ERROR "not an expected value: building=${building} test_folder=${test_folder} ARGN=${ARGN}")
    endif()
endfunction()

########################################################################
########################################################################
########################################################################
########################################################################
########################################################################
########################################################################


function(c_windows_tests_add_dll whatIsBuilding folder)
    link_directories(${whatIsBuilding}_dll $ENV{VCInstallDir}UnitTest/lib)

    add_library(${whatIsBuilding}_testsonly_lib STATIC
            ${${whatIsBuilding}_test_files}
    )
    SET(VAR 1)
    foreach(file ${${whatIsBuilding}_test_files})
        set_source_files_properties(${file} PROPERTIES COMPILE_FLAGS -DCPPUNITTEST_SYMBOL=some_symbol_for_cppunittest_${VAR})
        MATH(EXPR VAR "${VAR}+1")
    endforeach()

    set_target_properties(${whatIsBuilding}_testsonly_lib
               PROPERTIES
               FOLDER ${folder} )

    target_include_directories(${whatIsBuilding}_testsonly_lib PUBLIC ${sharedutil_include_directories} $ENV{VCInstallDir}UnitTest/include)
    target_compile_definitions(${whatIsBuilding}_testsonly_lib PUBLIC -DCPP_UNITTEST)
    target_compile_options(${whatIsBuilding}_testsonly_lib PUBLIC /TP /EHsc)

    add_library(${whatIsBuilding}_dll SHARED
        ${${whatIsBuilding}_cpp_files}
        ${${whatIsBuilding}_h_files}
        ${${whatIsBuilding}_c_files}
        ${build_c_tests_internal_dir}/nothing.cpp
    )

    set_target_properties(${whatIsBuilding}_dll
               PROPERTIES
               FOLDER ${folder})

    set_source_files_properties(${${whatIsBuilding}_c_files}
               PROPERTIES
               COMPILE_FLAGS /TC)

    set_source_files_properties(${${whatIsBuilding}_cpp_files}
               PROPERTIES
               COMPILE_FLAGS /TP)

    if (TARGET azure_c_logging)
        target_link_libraries(${whatIsBuilding}_dll azure_c_logging)
    endif()
    if (TARGET umock_c)
        target_link_libraries(${whatIsBuilding}_dll umock_c)
    endif()
    if (TARGET ctest)
        target_link_libraries(${whatIsBuilding}_dll ctest)
    endif()
    if (TARGET testrunnerswitcher)
        target_link_libraries(${whatIsBuilding}_dll testrunnerswitcher)
    endif()

    target_link_libraries(${whatIsBuilding}_dll ${whatIsBuilding}_testsonly_lib )

    set(PARSING_ADDITIONAL_LIBS OFF)
    set(PARSING_VALGRIND_SUPPRESSIONS_FILE OFF)
    set(VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER)
    set(ARG_PREFIX "none")
    foreach(f ${ARGN})
        set(skip_to_next FALSE)
        if(${f} STREQUAL "ADDITIONAL_LIBS")
            SET(PARSING_ADDITIONAL_LIBS ON)
            SET(PARSING_VALGRIND_SUPPRESSIONS_FILE OFF)
            set(ARG_PREFIX "none")
            #also unset all the other states
            set(skip_to_next TRUE)
        elseif(${f} STREQUAL "VALGRIND_SUPPRESSIONS_FILE")
            SET(PARSING_ADDITIONAL_LIBS OFF)
            SET(PARSING_VALGRIND_SUPPRESSIONS_FILE ON)
            set(skip_to_next TRUE)
        endif()

        if(NOT skip_to_next)
            if(PARSING_ADDITIONAL_LIBS)
                if((${f} STREQUAL "debug") OR (${f} STREQUAL "optimized") OR (${f} STREQUAL "general"))
                    SET(ARG_PREFIX ${f})
                else()
                    target_link_libraries_with_arg_prefix(${ARG_PREFIX} ${whatIsBuilding}_dll ${f})
                    target_link_libraries_with_arg_prefix(${ARG_PREFIX} ${whatIsBuilding}_testsonly_lib ${f})
                    set(ARG_PREFIX "none")
                endif()
            endif()
        endif()

    endforeach()

    SET(SPACES " ")
    SET(VAR 1)
    foreach(file ${${whatIsBuilding}_test_files})
        # for x64 the underscore is not needed
        if (ARCHITECTURE STREQUAL "x86_64" OR ARCHITECTURE STREQUAL "ARM")
            set_property(TARGET ${whatIsBuilding}_dll APPEND_STRING PROPERTY LINK_FLAGS ${SPACES}/INCLUDE:"some_symbol_for_cppunittest_${VAR}")
        else()
            set_property(TARGET ${whatIsBuilding}_dll APPEND_STRING PROPERTY LINK_FLAGS ${SPACES}/INCLUDE:"_some_symbol_for_cppunittest_${VAR}")
        endif()
        MATH(EXPR VAR "${VAR}+1")
    endforeach()
endfunction()

function(c_windows_tests_add_exe whatIsBuilding folder)
    add_executable(${whatIsBuilding}_exe
        ${${whatIsBuilding}_test_files}
        ${${whatIsBuilding}_cpp_files}
        ${${whatIsBuilding}_h_files}
        ${${whatIsBuilding}_c_files}
        ${CMAKE_CURRENT_LIST_DIR}/main.c
    )
    set_target_properties(${whatIsBuilding}_exe
               PROPERTIES
               FOLDER ${folder})

    target_compile_definitions(${whatIsBuilding}_exe PUBLIC -DUSE_CTEST)
    target_include_directories(${whatIsBuilding}_exe PUBLIC ${sharedutil_include_directories})
    if (TARGET azure_c_logging)
        target_link_libraries(${whatIsBuilding}_exe azure_c_logging)
    endif()
    if (TARGET umock_c)
        target_link_libraries(${whatIsBuilding}_exe umock_c)
    endif()
    if (TARGET ctest)
        target_link_libraries(${whatIsBuilding}_exe ctest)
    endif()
    if (TARGET testrunnerswitcher)
        target_link_libraries(${whatIsBuilding}_exe testrunnerswitcher)
    endif()

    set(PARSING_ADDITIONAL_LIBS OFF)
    set(PARSING_VALGRIND_SUPPRESSIONS_FILE OFF)
    set(VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER)
    set(ARG_PREFIX "none")
    foreach(f ${ARGN})
        set(skip_to_next FALSE)
        if(${f} STREQUAL "ADDITIONAL_LIBS")
            SET(PARSING_ADDITIONAL_LIBS ON)
            SET(PARSING_VALGRIND_SUPPRESSIONS_FILE OFF)
            set(ARG_PREFIX "none")
            #also unset all the other states
            set(skip_to_next TRUE)
        elseif(${f} STREQUAL "VALGRIND_SUPPRESSIONS_FILE")
            SET(PARSING_ADDITIONAL_LIBS OFF)
            SET(PARSING_VALGRIND_SUPPRESSIONS_FILE ON)
            set(skip_to_next TRUE)
        endif()

        if(NOT skip_to_next)
            if(PARSING_ADDITIONAL_LIBS)
                if((${f} STREQUAL "debug") OR (${f} STREQUAL "optimized") OR (${f} STREQUAL "general"))
                    SET(ARG_PREFIX ${f})
                else()
                    target_link_libraries_with_arg_prefix(${ARG_PREFIX} ${whatIsBuilding}_exe ${f})
                    set(ARG_PREFIX "none")
                endif()
            endif()
        endif()

    endforeach()

    add_test(NAME ${whatIsBuilding} COMMAND ${whatIsBuilding}_exe)
endfunction()

#this function takes more than the 1 mandatory argument (whatIsBuilding)
#the parameters are separated by "known" separators
#for example, ADDITIONAL_LIBS starts a list of needed libraries
function(c_linux_tests_add_exe whatIsBuilding folder)

    add_executable(${whatIsBuilding}_exe
        ${${whatIsBuilding}_test_files}
        ${${whatIsBuilding}_cpp_files}
        ${${whatIsBuilding}_h_files}
        ${${whatIsBuilding}_c_files}
        ${CMAKE_CURRENT_LIST_DIR}/main.c
    )
    set_target_properties(${whatIsBuilding}_exe
               PROPERTIES
               FOLDER ${folder})

    target_compile_definitions(${whatIsBuilding}_exe PUBLIC -DUSE_CTEST)
    target_include_directories(${whatIsBuilding}_exe PUBLIC ${sharedutil_include_directories})

    #this part detects
    #       - the additional libraries that might be needed.
    #     additional libraries are started by ADDITIONAL_LIBS parameter and ended by any other known parameter (or end of variable arguments)
    #   - a valgrind suppression file (VALGRIND_SUPPRESSIONS_FILE) for memcheck
    #     the file name follows immediately after

    set(PARSING_ADDITIONAL_LIBS OFF)
    set(PARSING_VALGRIND_SUPPRESSIONS_FILE OFF)
    set(VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER)
    set(ARG_PREFIX "none")
    foreach(f ${ARGN})
        set(skip_to_next FALSE)
        if(${f} STREQUAL "ADDITIONAL_LIBS")
            SET(PARSING_ADDITIONAL_LIBS ON)
            SET(PARSING_VALGRIND_SUPPRESSIONS_FILE OFF)
            set(ARG_PREFIX "none")
            #also unset all the other states
            set(skip_to_next TRUE)
        elseif(${f} STREQUAL "VALGRIND_SUPPRESSIONS_FILE")
            SET(PARSING_ADDITIONAL_LIBS OFF)
            SET(PARSING_VALGRIND_SUPPRESSIONS_FILE ON)
            set(skip_to_next TRUE)
        endif()

        if(NOT skip_to_next)
            if(PARSING_ADDITIONAL_LIBS)
                if((${f} STREQUAL "debug") OR (${f} STREQUAL "optimized") OR (${f} STREQUAL "general"))
                    SET(ARG_PREFIX ${f})
                else()
                    target_link_libraries_with_arg_prefix(${ARG_PREFIX} ${whatIsBuilding}_exe ${f})
                    set(ARG_PREFIX "none")
                endif()
            elseif(PARSING_VALGRIND_SUPPRESSIONS_FILE)
                set(VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER "--suppressions=${f}")
            endif()
        endif()

    endforeach()

    if (TARGET azure_c_logging)
        target_link_libraries(${whatIsBuilding}_exe azure_c_logging)
    endif()
    if (TARGET umock_c)
        target_link_libraries(${whatIsBuilding}_exe umock_c)
    endif()
    if (TARGET ctest)
        target_link_libraries(${whatIsBuilding}_exe ctest)
    endif()
    if (TARGET testrunnerswitcher)
        target_link_libraries(${whatIsBuilding}_exe testrunnerswitcher)
    endif()
    target_link_libraries(${whatIsBuilding}_exe m)

    add_test(NAME ${whatIsBuilding} COMMAND $<TARGET_FILE:${whatIsBuilding}_exe>)

    if(${run_valgrind})
        find_program(VALGRIND_FOUND NAMES valgrind)
        if(${VALGRIND_FOUND} STREQUAL VALGRIND_FOUND-NOTFOUND)
            message(WARNING "run_valgrind was TRUE, but valgrind was not found - there will be no tests run under valgrind")
        else()
            add_test(NAME ${whatIsBuilding}_valgrind COMMAND valgrind                 --gen-suppressions=all --num-callers=100 --error-exitcode=1 --leak-check=full --track-origins=yes ${VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER} $<TARGET_FILE:${whatIsBuilding}_exe>)
            add_test(NAME ${whatIsBuilding}_helgrind COMMAND valgrind --tool=helgrind --gen-suppressions=all --num-callers=100 --error-exitcode=1 ${VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER} $<TARGET_FILE:${whatIsBuilding}_exe>)
            add_test(NAME ${whatIsBuilding}_drd      COMMAND valgrind --tool=drd      --gen-suppressions=all --num-callers=100 --error-exitcode=1 ${VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER} $<TARGET_FILE:${whatIsBuilding}_exe>)
        endif()
    endif()
endfunction()

function(build_c_tests whatIsBuilding use_gballoc folder)

    #the first argument is what is building
    #the second argument is whether the tests should be build with gballoc #defines or not
    #the following arguments are a list of libraries to link with

    if(${use_gballoc})
        add_definitions(-DGB_MEASURE_MEMORY_FOR_THIS -DGB_DEBUG_ALLOC)
    else()
    endif()

    #setting #defines
    if(WIN32)
        add_definitions(-D_CRT_SECURE_NO_WARNINGS)
    else()
    endif()

    #setting includes
    set(sharedutil_include_directories ${sharedutil_include_directories} ${TESTRUNNERSWITCHER_INCLUDES} ${CTEST_INCLUDES} ${UMOCK_C_INCLUDES} ${AZURE_C_SHARED_UTILITY_INCLUDES})
    set(sharedutil_include_directories ${sharedutil_include_directories} ${MICROMOCK_INC_FOLDER} ${UMOCK_C_INC_FOLDER} ${TESTRUNNERSWITCHER_INC_FOLDER} ${CTEST_INC_FOLDER} ${SAL_INC_FOLDER} ${SHARED_UTIL_INC_FOLDER} ${SHARED_UTIL_SRC_FOLDER})
    if(WIN32)
    else()
        include_directories(${sharedutil_include_directories})
    endif()

    #setting output type
    if(WIN32)
        if(
            (("${whatIsBuilding}" MATCHES ".*ut.*") AND ${run_unittests}) OR
            (("${whatIsBuilding}" MATCHES ".*e2e.*") AND ${run_e2e_tests}) OR
            (("${whatIsBuilding}" MATCHES ".*int.*") AND ${run_int_tests}) OR
            (("${whatIsBuilding}" MATCHES ".*perf.*") AND ${run_perf_tests})
        )
            if (${use_cppunittest})
                c_windows_tests_add_dll(${whatIsBuilding} ${folder} ${ARGN})
            endif()
            c_windows_tests_add_exe(${whatIsBuilding} ${folder} ${ARGN})
        else()
            if(
                (("${whatIsBuilding}" MATCHES ".*e2e.*") AND ("${nuget_e2e_tests}" STREQUAL "ON"))
            )
                c_windows_tests_add_exe(${whatIsBuilding}_nuget ${folder} ${ARGN})
            else()
                #do nothing
            endif()
        endif()
    else()
        if(
            (("${whatIsBuilding}" MATCHES ".*ut.*") AND ${run_unittests}) OR
            (("${whatIsBuilding}" MATCHES ".*e2e.*") AND ${run_e2e_tests}) OR
            (("${whatIsBuilding}" MATCHES ".*int.*") AND ${run_int_tests}) OR
            (("${whatIsBuilding}" MATCHES ".*perf.*") AND ${run_perf_tests})
        )
            c_linux_tests_add_exe(${whatIsBuilding} ${folder} ${ARGN})
        endif()
    endif()
endfunction()

macro(set_default_build_options)
    # System-specific compiler flags
    if(MSVC)
        #use _CRT_SECURE_NO_WARNINGS by default
        add_definitions(-D_CRT_SECURE_NO_WARNINGS)

        # warning C4200: nonstandard extension used: zero-sized array in struct/union : looks very standard in C99 and it is called flexible array. Documentation-wise is a flexible array, but called "unsized" in Microsoft's docs
        # https://msdn.microsoft.com/en-us/library/b6fae073.aspx
        # /WX is "treats all compiler warnings as error". (https://docs.microsoft.com/en-us/cpp/build/reference/compiler-option-warning-level?view=vs-2019)
        # /bigobj is "increase number of sections in .obj file" (https://docs.microsoft.com/en-us/cpp/build/reference/bigobj-increase-number-of-sections-in-dot-obj-file?view=vs-2019)
        # /Zc:preprocessor means using the "conformant" (similar to gcc/clang) rather than the "trditional" preprocessor which is Microsoft's invention (https://docs.microsoft.com/en-us/cpp/build/reference/zc-preprocessor?view=vs-2019)
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /WX /wd4200 /bigobj /Zc:preprocessor")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /WX /wd4200 /bigobj /Zc:preprocessor")
        
        # replace other warning levels (CMake will add by default /W3) with /W4 (warning level 4)
        string(REGEX REPLACE "/W[1-3]" "/W4" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
        string(REGEX REPLACE "/W[1-3]" "/W4" CMAKE_C_FLAGS "${CMAKE_C_FLAGS}")
        
    elseif(UNIX) #LINUX OR APPLE
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Werror")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Werror")
    endif()

    if (WIN32)
        if (${use_segment_heap})
            set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} /MANIFEST:EMBED /MANIFESTINPUT:${build_c_tests_internal_dir}/manifest.xml")
            #link.exe complains in the presence of both /MANIFESTFILE and /MANIFESTINPUT
            string(REGEX REPLACE "/MANIFESTFILE" "" CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS}")
            
            set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} /MANIFEST:EMBED /MANIFESTINPUT:${build_c_tests_internal_dir}/manifest.xml")
            #link.exe complains in the presence of both /MANIFESTFILE and /MANIFESTINPUT
            string(REGEX REPLACE "/MANIFESTFILE" "" CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS}")
        endif()

        set(CMAKE_EXE_LINKER_FLAGS "/INCREMENTAL:NO ${CMAKE_EXE_LINKER_FLAGS} /LTCG /IGNORE:4075")
        set(CMAKE_SHARED_LINKER_FLAGS "/INCREMENTAL:NO ${CMAKE_SHARED_LINKER_FLAGS} /LTCG /IGNORE:4075")

        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /GL")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /GL")
    endif()

    enable_testing()
endmacro()

macro(compileAsC99)
  if (CMAKE_VERSION VERSION_LESS "3.1")
    if (CMAKE_C_COMPILER_ID STREQUAL "GNU")
      set (CMAKE_C_FLAGS "--std=c99 ${CMAKE_C_FLAGS}")
      if (CXX_FLAG_CXX11)
        set (CMAKE_CXX_FLAGS "--std=c++11 ${CMAKE_CXX_FLAGS}")
      else()
        set (CMAKE_CXX_FLAGS "--std=c++0x ${CMAKE_CXX_FLAGS}")
      endif()
    endif()
  else()
    set (CMAKE_C_STANDARD 99)
    set (CMAKE_CXX_STANDARD 11)
  endif()
endmacro(compileAsC99)

macro(compileAsC11)
    if (CMAKE_VERSION VERSION_LESS "3.1")
        if (CMAKE_C_COMPILER_ID STREQUAL "GNU")
            set (CMAKE_C_FLAGS "--std=c11 ${CMAKE_C_FLAGS}")
            set (CMAKE_C_FLAGS "-D_POSIX_C_SOURCE=200112L ${CMAKE_C_FLAGS}")
            set (CMAKE_CXX_FLAGS "--std=c++11 ${CMAKE_CXX_FLAGS}")
        endif()
    else()
        set (CMAKE_C_STANDARD 11)
        set (CMAKE_CXX_STANDARD 11)
    endif()
endmacro(compileAsC11)

function(compileTargetAsC99 theTarget)
  if (CMAKE_VERSION VERSION_LESS "3.1")
    if (CMAKE_C_COMPILER_ID STREQUAL "GNU")
      set_target_properties(${theTarget} PROPERTIES COMPILE_FLAGS "--std=c99")
    endif()
  else()
    set_target_properties(${theTarget} PROPERTIES C_STANDARD 99)
    set_target_properties(${theTarget} PROPERTIES CXX_STANDARD 11)
  endif()
endfunction()

function(compileTargetAsC11 theTarget)
  if (CMAKE_VERSION VERSION_LESS "3.1")
    if (CMAKE_C_COMPILER_ID STREQUAL "GNU")
      if (CXX_FLAG_CXX11)
        set_target_properties(${theTarget} PROPERTIES COMPILE_FLAGS "--std=c11 -D_POSIX_C_SOURCE=200112L")
      else()
        set_target_properties(${theTarget} PROPERTIES COMPILE_FLAGS "--std=c99 -D_POSIX_C_SOURCE=200112L")
      endif()
    endif()
  else()
    set_target_properties(${theTarget} PROPERTIES C_STANDARD 11)
    set_target_properties(${theTarget} PROPERTIES CXX_STANDARD 11)
  endif()
endfunction()


