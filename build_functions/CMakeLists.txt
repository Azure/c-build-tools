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

function(set_output_folder_properties target_name)
    foreach(config_iter DEBUG RELWITHDEBINFO RELEASE MINSIZEREL)
        set_target_properties(${target_name}
                PROPERTIES
                RUNTIME_OUTPUT_DIRECTORY_${config_iter} "${CMAKE_RUNTIME_OUTPUT_DIRECTORY_${config_iter}}/${target_name}")
    endforeach()
endfunction()

function(copy_disable_vld_ini target output_directory)
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${build_c_tests_internal_dir}/disable_vld.ini" "${output_directory}/vld.ini" )
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

    target_link_directories(${whatIsBuilding}_dll PRIVATE $ENV{VCInstallDir}auxiliary/vs/unittest/lib $ENV{VCInstallDir}unittest/lib)

    target_include_directories(${whatIsBuilding}_dll PUBLIC ${sharedutil_include_directories} $ENV{VCInstallDir}auxiliary/vs/unittest/include $ENV{VCInstallDir}unittest/include)
    target_compile_definitions(${whatIsBuilding}_dll PUBLIC -DCPP_UNITTEST)
    target_compile_options(${whatIsBuilding}_dll PUBLIC /EHsc)

    set_target_properties(${whatIsBuilding}_dll
               PROPERTIES
               FOLDER ${solution_folder})

    set_output_folder_properties(${whatIsBuilding}_dll)

    if (TARGET c_logging)
        target_link_libraries(${whatIsBuilding}_dll c_logging)
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

    copy_disable_vld_ini(${whatIsBuilding}_dll $<TARGET_FILE_DIR:${whatIsBuilding}_dll>)
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

    set_output_folder_properties(${whatIsBuilding}_exe)

    target_compile_definitions(${whatIsBuilding}_exe PUBLIC -DUSE_CTEST)
    target_include_directories(${whatIsBuilding}_exe PUBLIC ${sharedutil_include_directories})

    if (TARGET c_logging)
        target_link_libraries(${whatIsBuilding}_exe c_logging)
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
        if(${run_valgrind} OR ${run_helgrind} OR ${run_drd})
            find_program(VALGRIND_FOUND NAMES valgrind)
            if(${VALGRIND_FOUND} STREQUAL VALGRIND_FOUND-NOTFOUND)
                message(WARNING "Running with run_valgrind/run_helgrind/run_drd, but valgrind was not found - there will be no tests run under valgrind")
            else()
                if(${run_valgrind})
                    add_test(NAME ${whatIsBuilding}_valgrind COMMAND valgrind                 --gen-suppressions=all --num-callers=100 --error-exitcode=1 --leak-check=full --track-origins=yes ${VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER} --suppressions=${build_c_tests_internal_dir}/common_suppresions.sup $<TARGET_FILE:${whatIsBuilding}_exe>)
                endif()
                if(${run_helgrind})
                    add_test(NAME ${whatIsBuilding}_helgrind COMMAND valgrind --tool=helgrind --gen-suppressions=all --num-callers=100 --error-exitcode=1 ${VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER} --suppressions=${build_c_tests_internal_dir}/common_suppresions.sup $<TARGET_FILE:${whatIsBuilding}_exe>)
                endif()
                if(${run_drd})
                    add_test(NAME ${whatIsBuilding}_drd      COMMAND valgrind --tool=drd      --gen-suppressions=all --num-callers=100 --error-exitcode=1 ${VALGRIND_SUPPRESSIONS_FILE_EXTRA_PARAMETER} --suppressions=${build_c_tests_internal_dir}/common_suppresions.sup $<TARGET_FILE:${whatIsBuilding}_exe>)
                endif()
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

#this is the function used to add all the needed targets for one test project
#(invoked from the CMakeLists where the test suite lives)
# Note: the test folder has to be added by using build_test_folder, not add_subdirectory!
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

macro(set_default_build_options)
    # Make sure we have a runtime output directory always set
    if (NOT CMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG)
        set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG ${CMAKE_BINARY_DIR}/Debug)
    endif()
    if (NOT CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE)
        set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE ${CMAKE_BINARY_DIR}/Release)
    endif()
    if (NOT CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO)
        set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO ${CMAKE_BINARY_DIR}/RelWithDebInfo)
    endif()
    if (NOT CMAKE_RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL)
        set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL ${CMAKE_BINARY_DIR}/MinSizeRel)
    endif()

    # System-specific compiler flags
    if(MSVC)
        #use _CRT_SECURE_NO_WARNINGS by default
        add_definitions(-D_CRT_SECURE_NO_WARNINGS)

        # warning C4200: nonstandard extension used: zero-sized array in struct/union : looks very standard in C99 and it is called flexible array. Documentation-wise is a flexible array, but called "unsized" in Microsoft's docs
        # https://msdn.microsoft.com/en-us/library/b6fae073.aspx
        # /WX is "treats all compiler warnings as error". (https://docs.microsoft.com/en-us/cpp/build/reference/compiler-option-warning-level?view=vs-2019)
        # /bigobj is "increase number of sections in .obj file" (https://docs.microsoft.com/en-us/cpp/build/reference/bigobj-increase-number-of-sections-in-dot-obj-file?view=vs-2019)
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /WX /wd4200 /bigobj")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /WX /wd4200 /bigobj")

        if(${CMAKE_GENERATOR} STREQUAL "Visual Studio 15 2017")
            #do nothing about preprocesor - automatically for C/C++ the "traditional preprocessor will be used
        else()
            #for what we suppose it is VS 2019 and forward, use the conformant preprocessor
            # /Zc:preprocessor means using the "conformant" (similar to gcc/clang) rather than the "traditional" preprocessor which is Microsoft's invention (https://docs.microsoft.com/en-us/cpp/build/reference/zc-preprocessor?view=vs-2019)
            # /wd5105 avoids in winbase.h "warning C5105: macro expansion producing 'defined' has undefined behavior" around #define MICROSOFT_WINDOWS_WINBASE_H_DEFINE_INTERLOCKED_CPLUSPLUS_OVERLOADS (_WIN32_WINNT >= 0x0502 || !defined(_WINBASE_)). Note how the macro expands to something that contains "defined"
            set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /Zc:preprocessor /wd5105")
            set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /Zc:preprocessor /wd5105")
        endif()


        # replace other warning levels (CMake will add by default /W3) with /W4 (warning level 4)
        string(REGEX REPLACE "/W[1-3]" "/W4" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
        string(REGEX REPLACE "/W[1-3]" "/W4" CMAKE_C_FLAGS "${CMAKE_C_FLAGS}")

    elseif(UNIX) #LINUX OR APPLE
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Werror -g")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Werror -g")
    endif()

    if(${run_valgrind} OR ${run_helgrind} OR ${run_drd})
        add_definitions(-DUSE_VALGRIND)
    endif()

    if (WIN32)
        if (${use_segment_heap})
            if (CMAKE_GENERATOR MATCHES "Visual Studio")
                set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} /MANIFEST:EMBED /MANIFESTINPUT:${build_c_tests_internal_dir}/manifest.xml")
                #link.exe complains in the presence of both /MANIFESTFILE and /MANIFESTINPUT
                string(REGEX REPLACE "/MANIFESTFILE" "" CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS}")

                set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} /MANIFEST:EMBED /MANIFESTINPUT:${build_c_tests_internal_dir}/manifest.xml")
                #link.exe complains in the presence of both /MANIFESTFILE and /MANIFESTINPUT
                string(REGEX REPLACE "/MANIFESTFILE" "" CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS}")
            else()
                message(WARNING "Building with some other generator than Visual Studio, will not embed manifest! If you need to use segment heap then use Visual Studio!")
            endif()
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
