#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

set(build_c_tests_internal_dir ${CMAKE_CURRENT_LIST_DIR} CACHE INTERNAL "")

#add_custom_target... below exists so that a project (called "c_build_functions") is created in Visual Studio so it can be edited easily in the IDE
add_custom_target(c_build_functions SOURCES ${CMAKE_CURRENT_LIST_FILE})

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
    #compile the code as C17
    set(CMAKE_C_STANDARD 17)

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
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Werror -Wall -Wno-unused-function -Wno-missing-braces -g -fPIC")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Werror -Wall -Wno-unused-function -Wno-missing-braces -g -fPIC")
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

        # /guard:cf is Enable Control Flow Guard https://docs.microsoft.com/en-us/cpp/build/reference/guard-enable-control-flow-guard, working for compiler and the linker
        # /CETCOMPAT (CET Shadow Stack compatible) https://learn.microsoft.com/en-us/cpp/build/reference/cetcompat. Also mitigates: warning BA2025: 'latency_test_server.exe' does not enable the Control-flow Enforcement Technology (CET) Shadow Stack mitigation. To resolve this issue, pass /CETCOMPAT on the linker command lines.
        # /LTCG is Link-time Code Generation https://docs.microsoft.com/en-us/cpp/build/reference/ltcg-link-time-code-generation?view=msvc-160
        if(${use_ltcg})
            set(CMAKE_EXE_LINKER_FLAGS "/INCREMENTAL:NO ${CMAKE_EXE_LINKER_FLAGS} /LTCG /IGNORE:4075 /WX /guard:cf /CETCOMPAT")
            set(CMAKE_SHARED_LINKER_FLAGS "/INCREMENTAL:NO ${CMAKE_SHARED_LINKER_FLAGS} /LTCG /IGNORE:4075 /WX /guard:cf /CETCOMPAT")
        else()
            set(CMAKE_EXE_LINKER_FLAGS "/INCREMENTAL:NO ${CMAKE_EXE_LINKER_FLAGS} /IGNORE:4075 /WX /guard:cf /CETCOMPAT")
            set(CMAKE_SHARED_LINKER_FLAGS "/INCREMENTAL:NO ${CMAKE_SHARED_LINKER_FLAGS} /IGNORE:4075 /WX /guard:cf /CETCOMPAT")
        endif()

        set(CMAKE_STATIC_LINKER_FLAGS "${CMAKE_STATIC_LINKER_FLAGS} /WX")


        # /sdl (Enable Additional Security Checks) https://learn.microsoft.com/en-us/cpp/build/reference/sdl-enable-additional-security-checks. This also mitigates  warning BA2026: 'geo_replication_service.exe' is a Windows PE that wasn't compiled with recommended Security Development Lifecycle (SDL) checks. As a result some critical compile-time and runtime checks may be disabled, increasing the possibility of an exploitable runtime issue [...]
        # /GL (Whole Program Optimization) https://docs.microsoft.com/en-us/cpp/build/reference/gl-whole-program-optimization?view=msvc-160 Note: GL and LTCG are together used.
        if(${use_ltcg})
            set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /GL /guard:cf /sdl")
            set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /GL /guard:cf /sdl")
        else()
            set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /guard:cf /sdl")
            set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /guard:cf /sdl")
        endif()

    endif()

    if (WIN32 AND (CMAKE_GENERATOR MATCHES "Visual Studio") AND (${use_vld}))
        include_directories("$ENV{ProgramFiles\(x86\)}/Visual Leak Detector/include")
        if (${ARCHITECTURE} STREQUAL "x86_64")
            link_directories("$ENV{ProgramFiles\(x86\)}/Visual Leak Detector/lib/Win64")
        else()
            link_directories("$ENV{ProgramFiles\(x86\)}/Visual Leak Detector/lib/Win32")
        endif()
    endif()

    if (WIN32 AND (CMAKE_GENERATOR MATCHES "Visual Studio") AND (${fsanitize_address}))
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /fsanitize=address")
        set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /fsanitize=address")
    endif()

    enable_testing()
endmacro()

function(build_as_csharp_net6_project_with_framework targetname framework)
    set_target_properties(${targetname} PROPERTIES
        DOTNET_SDK "Microsoft.NET.Sdk"
        DOTNET_TARGET_FRAMEWORK ${framework}
        VS_GLOBAL_RuntimeIdentifier "win10-${CMAKE_VS_PLATFORM_NAME}"
        VS_GLOBAL_SelfContained true
        VS_GLOBAL_AppendRuntimeIdentifierToOutputPath false
        VS_GLOBAL_AppendTargetFrameworkToOutputPath false
        VS_GLOBAL_PlatformTarget ${CMAKE_VS_PLATFORM_NAME}
        VS_GLOBAL_Platforms ${CMAKE_VS_PLATFORM_NAME}
        VS_GLOBAL_Configurations "Debug;Release;RelWithDebInfo;MinSizeRel"
        VS_GLOBAL_AssemblyOriginatorKeyFile "${PROJECT_SOURCE_DIR}/MSSharedLibSN1024.snk"
        VS_GLOBAL_SignAssembly true
        VS_GLOBAL_DelaySign true
        VS_GLOBAL_TreatWarningsAsErrors true
        VS_GLOBAL_WarningLevel 4
        VS_GLOBAL_GenerateAssemblyVersionAttribute false
        VS_GLOBAL_GenerateAssemblyFileVersionAttribute false
        VS_GLOBAL_GenerateAssemblyInformationalVersionAttribute false)
    # Enable native debugging in the managed projects
    set(PROFILE_NAME ${targetname})
    configure_file(${build_c_tests_internal_dir}/launchSettings.json.in ${CMAKE_CURRENT_BINARY_DIR}/Properties/launchSettings.json @ONLY)
    # As of cmake 3.24-3.26 (not sure exactly), this is required or Debug will be warning level 3 and Release will be warning level 1
    target_compile_options(${targetname} PRIVATE /warn:4)
endfunction()

# The following helper will enable C# .NET6 for projects
# Assumes MSSharedLibSN1024.snk is available at the project root
# Note: csharp_sdk_fix must be used in the project
function(build_as_csharp_net6_project targetname)
    build_as_csharp_net6_project_with_framework(${targetname} "net6.0")
endfunction()

# The following helper will enable C# .NET6 for Windows only projects
# Assumes MSSharedLibSN1024.snk is available at the project root
# Note: csharp_sdk_fix must be used in the project
function(build_as_csharp_net6_windows_project targetname)
    build_as_csharp_net6_project_with_framework(${targetname} "net6.0-windows")
endfunction()

# variable to store list of libs that must be checked for reals
set(LIBS_TO_BE_REAL_CHECKED CACHE INTERNAL "LIBS_TO_BE_CHECKED")

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

function(get_all_targets_except_deps _result _dir)
    if(NOT ${CMAKE_CURRENT_LIST_DIR} MATCHES "/deps/")
        get_property(_subdirs DIRECTORY "${_dir}" PROPERTY SUBDIRECTORIES)
        foreach(_subdir IN LISTS _subdirs)
            get_all_targets_except_deps(${_result} "${_subdir}")
        endforeach()

        get_directory_property(_sub_targets DIRECTORY "${_dir}" BUILDSYSTEM_TARGETS)
        set(${_result} ${${_result}} ${_sub_targets} PARENT_SCOPE)
    endif()
endfunction()

function(init_libs_to_be_real_checked)
    get_all_targets_except_deps(all_targets_to_check ${PROJECT_SOURCE_DIR})

    foreach(lib ${all_targets_to_check})
        get_target_property(lib_type ${lib} TYPE)
        if(
            (${lib_type} STREQUAL "STATIC_LIBRARY") AND # only check static libs
            (NOT ${lib} MATCHES "_(ut|int|perf)_lib") # ignore test libs
            )
            # appending lib to LIBS_TO_BE_REAL_CHECKED
            set(LIBS_TO_BE_REAL_CHECKED "${LIBS_TO_BE_REAL_CHECKED};${lib}" CACHE INTERNAL "LIBS_TO_BE_CHECKED")
        endif()
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

        init_libs_to_be_real_checked()

        get_target_files(lib_paths ${LIBS_TO_BE_REAL_CHECKED})
        add_custom_command(TARGET ${reals_check_target} POST_BUILD
            COMMAND
            powershell.exe ${script_path}/reals_check.ps1 ${lib_paths}
        )
    endif()
endfunction()

# signature: install_library_includes(<theTarget> <includePrefix> [ <public_header>... ]])
# Creates an install target excluding libs for library with a subdirectory and optional public header files.
function(install_library_includes theTarget includePrefix)

    if(ARGN)
        set_target_properties(${theTarget} PROPERTIES PUBLIC_HEADER "${ARGN}")
    endif()

    # Set CMAKE_INSTALL_* if not defined
    include(GNUInstallDirs)

    if(NOT DEFINED CMAKE_INSTALL_LIBDIR)
        set(CMAKE_INSTALL_LIBDIR "lib")
    endif()

    set(package_location "cmake")

    # Make an installation build target for theTarget
    install(TARGETS ${theTarget} EXPORT ${theTarget}Targets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR} EXCLUDE_FROM_ALL
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR} EXCLUDE_FROM_ALL
        RUNTIME DESTINATION ${CMAKE_INSTALL_LIBDIR}/../bin EXCLUDE_FROM_ALL
        PUBLIC_HEADER DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/${includePrefix}
    )

endfunction()

# signature: install_library_with_prefix(<theTarget> <includePrefix> [ <public_header>... ]])
# Creates an install target for library with a subdirectory and optional public header files.
function(install_library_with_prefix theTarget includePrefix)

    if(ARGN)
        set_target_properties(${theTarget} PROPERTIES PUBLIC_HEADER "${ARGN}")
    endif()

    # Set CMAKE_INSTALL_* if not defined
    include(GNUInstallDirs)

    if(NOT DEFINED CMAKE_INSTALL_LIBDIR)
        set(CMAKE_INSTALL_LIBDIR "lib")
    endif()

    set(package_location "cmake")

    # Make an installation build target for theTarget
    install(TARGETS ${theTarget} EXPORT ${theTarget}Targets
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_LIBDIR}/../bin
        PUBLIC_HEADER DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/${includePrefix}
    )

endfunction()

# signature: install_library(<theTarget> [ <public_header>... ]])
# Creates an install target for library with optional public header files.
function(install_library theTarget )
    install_library_with_prefix(${theTarget} "" ${ARGN})
endfunction()

# This function is used to add the vcpkg cmake (it lives at `vcpkgPath`) to the current project
# It also sets the VCPKG_OVERLAY_TRIPLETS to the common c build tools path and selects the corresponding triplet
macro(use_vcpkg vcpkgPath)
    # Only obtain assets from Terrapin project. See Asset Caching (https://vcpkg.io/en/docs/users/assetcaching.html)
    set(ENV{X_VCPKG_ASSET_SOURCES} "clear;x-azurl,https://vcpkg.storage.devpackages.microsoft.io/artifacts/;x-block-origin")

    #Use vcpkg package caching into an ADO artifact feed
    set(ENV{VCPKG_BINARY_SOURCES} "clear;nuget,https://msazure.pkgs.visualstudio.com/One/_packaging/azure-messagingstore-vcpkg-cache/nuget/v3/index.json,readwrite")

    if (EXISTS ${vcpkgPath}/scripts/buildsystems/vcpkg.cmake)
        set(VCPKG_OVERLAY_TRIPLETS "${build_c_tests_internal_dir}/../vcpkg_triplets/")
        if (${ARCHITECTURE} STREQUAL "x86_64")
            if(${fsanitize_address})
                set(VCPKG_TARGET_TRIPLET "x64-windows-static-cbt-asan")
            else()
                set(VCPKG_TARGET_TRIPLET "x64-windows-static-cbt")
            endif()
        else()
        if(${fsanitize_address})
            set(VCPKG_TARGET_TRIPLET "x86-windows-static-cbt-asan")
        else()
            set(VCPKG_TARGET_TRIPLET "x86-windows-static-cbt")
        endif()
    endif()
        include(deps/vcpkg/scripts/buildsystems/vcpkg.cmake)
    endif()

    set(VCPKG_OVERLAY_PORTS "${build_c_tests_internal_dir}/../overlay_ports;${VCPKG_OVERLAY_PORTS}")
endmacro()

function(add_source_if_no_cs target additional_source)
    # Get the list of source files for the target
    get_target_property(SOURCES ${target} SOURCES)
    
    # Check if any source files end with .cs
    set(FOUND_CS FALSE)
    foreach(src IN LISTS SOURCES)
        if(src MATCHES "\\.cs$")
            set(FOUND_CS TRUE)
            break()
        endif()
    endforeach()
    
    # Conditionally add the additional source file
    if(NOT FOUND_CS)
        target_sources(${target} PRIVATE ${additional_source})
        #message(STATUS "Added ${additional_source} to ${target}")
    endif()
endfunction()

#Function to parse all targets in a given directory and its subdirectories
function(add_vld_if_defined DIR)
    if(${use_vld})
        get_property(TARGETS DIRECTORY "${DIR}" PROPERTY BUILDSYSTEM_TARGETS)
        foreach(TGT IN LISTS TARGETS)
            get_target_property(TARGET_TYPE ${TGT} TYPE)
            if(TARGET_TYPE STREQUAL "EXECUTABLE")
                #if the target is an executable which is not build from any .cs files then assume vld would work... 
                add_source_if_no_cs(${TGT} ${CMAKE_CURRENT_SOURCE_DIR}/use_vld.c)
            endif()
        endforeach()

        # Get all subdirectories
        get_property(SUBDIRS DIRECTORY "${DIR}" PROPERTY SUBDIRECTORIES)
        foreach(SUBDIR IN LISTS SUBDIRS)
            add_vld_if_defined("${SUBDIR}")
        endforeach()
    endif()
endfunction()