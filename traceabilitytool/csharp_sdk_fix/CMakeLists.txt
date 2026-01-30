#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Note this is a separate file to include as early as possible in the root project when it is needed

# This is not needed with cmake version 4.2 or newer
# Once all build machines are updated, we should remove this entirely

# So the SDK style projects we generate for C# .NET6 have a weird quirk in cmake (prior to version 4.2).
# Cmake will generate the sln file such that ALL of these build as "Any CPU" and there is no way to avoid it
# The symptom in Visual Studio is that the build solution will show many projects as "skipped" because we want to build x64
# As a horrible hack, we can modify the sln file after Cmake is done.
# How? Well, SO to the rescue: https://stackoverflow.com/questions/7091447/run-command-after-generation-step-in-cmake
# "all" we have to do is recursively call cmake itself (relying on any options passed to be cached)
# then we can have "post-generate" step commands, which we will use to hack up the sln and replace "Any CPU" with "x64"
# BUT we can't do this from a clean cmake directory, cmake needs to run normally at least once
# This macro must be added near the top of any project using .NET 8+ projects (or any SDK style C#)
# Users must generate the project normally and then enable FIX_ANY_CPU
macro(enable_net8_sln_anycpu_fix)
    if (${CMAKE_VERSION} VERSION_GREATER_EQUAL "4.2.0")
        message(NOTICE "CMake version ${CMAKE_VERSION} detected, no need to enable ANY_CPU fix for .NET 8+ SDK projects, this macro can be removed")
    else()
        option(FIX_ANY_CPU "Enable work-around to fix AnyCPU generated in sln, must run cmake once without this first" OFF)
        option(RECURSIVE_GENERATE "Recursive call to cmake" OFF)
        if(FIX_ANY_CPU AND NOT RECURSIVE_GENERATE)
            message(NOTICE "ANY_CPU fix enabled, will patch sln file. Note that you must run cmake with FIX_ANY_CPU OFF at least once to populate the cache")
            message(CHECK_START "Recursive generate")
            # Propagate the log level to the recursive call if possible
            set(current_log_level STATUS)
            if(${CMAKE_VERSION} VERSION_GREATER_EQUAL "3.25.0")
                cmake_language(GET_MESSAGE_LOG_LEVEL current_log_level)
            endif()
            execute_process(COMMAND ${CMAKE_COMMAND}
                -G "${CMAKE_GENERATOR}"
                -T "${CMAKE_GENERATOR_TOOLSET}"
                -A "${CMAKE_GENERATOR_PLATFORM}"
                -DRECURSIVE_GENERATE:BOOL=ON
                ${CMAKE_SOURCE_DIR}
                --log-level=${current_log_level}
                RESULT_VARIABLE recursive_result)
            if (${recursive_result} EQUAL 0)
                message(CHECK_PASS "done")
            else()
                message(CHECK_FAIL "failed!")
                message(FATAL_ERROR "Recursive generate failed!")
            endif()

            # post-generate steps here
            message(CHECK_START "Fixing the csproj mess of AnyCPU...")
            execute_process(COMMAND
                powershell -Command "(Get-Content ${CMAKE_BINARY_DIR}/${CMAKE_PROJECT_NAME}.sln) -replace 'Any CPU', '${CMAKE_VS_PLATFORM_NAME}' | Out-File ${CMAKE_BINARY_DIR}/${CMAKE_PROJECT_NAME}.sln"
                RESULT_VARIABLE any_cpu_fix_result)
            if (${any_cpu_fix_result} EQUAL 0)
                message(CHECK_PASS "done")
            else()
                message(CHECK_FAIL "failed!")
            endif()

            # exit without doing anything else, since it already happened
            return()
        elseif(NOT FIX_ANY_CPU)
            message(NOTICE "ANY_CPU fix disabled, sln will contain ANY_CPU entries and some projects will NOT build in Visual Studio. Recommend running cmake again with FIX_ANY_CPU ON")
        endif()
    endif()
endmacro()
