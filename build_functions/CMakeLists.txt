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
        # /W4 displays level 1, level 2, and level 3 warnings, and all level 4 (informational) warnings that aren't off by default. (https://docs.microsoft.com/en-us/cpp/build/reference/compiler-option-warning-level?view=msvc-160)
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /W4 /WX /wd4200 /bigobj")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /W4 /WX /wd4200 /bigobj")

        if(${CMAKE_GENERATOR} STREQUAL "Visual Studio 15 2017")
            #do nothing about preprocesor - automatically for C/C++ the "traditional preprocessor will be used
        else()
            #for what we suppose it is VS 2019 and forward, use the conformant preprocessor
            # /Zc:preprocessor means using the "conformant" (similar to gcc/clang) rather than the "traditional" preprocessor which is Microsoft's invention (https://docs.microsoft.com/en-us/cpp/build/reference/zc-preprocessor?view=vs-2019)
            # /wd5105 avoids in winbase.h "warning C5105: macro expansion producing 'defined' has undefined behavior" around #define MICROSOFT_WINDOWS_WINBASE_H_DEFINE_INTERLOCKED_CPLUSPLUS_OVERLOADS (_WIN32_WINNT >= 0x0502 || !defined(_WINBASE_)). Note how the macro expands to something that contains "defined"
            set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /Zc:preprocessor /wd5105")
            set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /Zc:preprocessor /wd5105")
        endif()


        # replace other warning levels (just in case - CMake used to add /W3 in previous versions, in 3.18 magically has /W1 for projects) with /W4 (warning level 4)
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

        set(CMAKE_EXE_LINKER_FLAGS "/INCREMENTAL:NO ${CMAKE_EXE_LINKER_FLAGS} /LTCG /IGNORE:4075 /WX")
        set(CMAKE_SHARED_LINKER_FLAGS "/INCREMENTAL:NO ${CMAKE_SHARED_LINKER_FLAGS} /LTCG /IGNORE:4075 /WX")
        set(CMAKE_STATIC_LINKER_FLAGS "${CMAKE_STATIC_LINKER_FLAGS} /WX")

        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /GL")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /GL")
    endif()

    if (WIN32 AND (CMAKE_GENERATOR MATCHES "Visual Studio") AND (${use_vld}))
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /FIvld.h")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /FIvld.h")
        include_directories("$ENV{ProgramFiles\(x86\)}/Visual Leak Detector/include") 
        if (${ARCHITECTURE} STREQUAL "x86_64")
            link_directories("$ENV{ProgramFiles\(x86\)}/Visual Leak Detector/lib/Win64")
        else()
            link_directories("$ENV{ProgramFiles\(x86\)}/Visual Leak Detector/lib/Win32")
        endif()
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

# variable to store list of libs that must be checked for reals
set(LIBS_TO_BE_REAL_CHECKED CACHE INTERNAL "LIBS_TO_BE_CHECKED")

# overloading the add_library function to store name of library if it meets criteria
# overloading is not officially supported, solution was found here: https://stackoverflow.com/a/55723415/10144036
function (add_library())
    _add_library(${ARGV})
    get_target_property(lib_type ${ARGV0} TYPE)
    if( (NOT ${CMAKE_CURRENT_LIST_DIR} MATCHES "/deps/") AND # ignore dependency libs
        (NOT ${ARGV0} MATCHES "_(ut|int|perf)_lib|dll") AND # ignore test libs and all dlls
        (NOT ${lib_type} STREQUAL "INTERFACE_LIBRARY")) # ignore interface libs
        # appending lib to LIBS_TO_BE_REAL_CHECKED
        set(LIBS_TO_BE_REAL_CHECKED "${LIBS_TO_BE_REAL_CHECKED};${ARGV0}" CACHE INTERNAL "LIBS_TO_BE_CHECKED")
    endif()
endfunction()

# signature: get_target_files(var [list of targets])
# returns a list of generator expressions for paths to targets
function (get_target_files)
    set(${ARGV0} CACHE INTERNAL "")
    set(libraries "")
    list(LENGTH ARGV num_args)
    if(${num_args} GREATER 1)
        list(SUBLIST ARGV 1 -1 libraries)
    endif()
    foreach(lib ${libraries})
        set(${ARGV0} "${${ARGV0}} \$\<TARGET_FILE:${lib}\>" CACHE INTERNAL "")
    endforeach()
endfunction()

# adds ${CMAKE_PROJECT_NAME}_reals_check as target to run reals check
# signature: add_reals_check_target()
function(add_reals_check_target)
    if(NOT WIN32)
        message(WARNING "Cannot run reals check for non-Windows build.")
    else()
        set(reals_check_target "${CMAKE_PROJECT_NAME}_reals_check")
        add_custom_target(${reals_check_target} ALL)
        set(script_path)
        get_target_property(script_path reals_check SOURCE_DIR)
        get_target_files(lib_paths ${LIBS_TO_BE_REAL_CHECKED})
        add_custom_command(TARGET ${reals_check_target} POST_BUILD
            COMMAND
            powershell.exe ${script_path}/reals_check.ps1 ${lib_paths}
        )
    endif()
endfunction()
