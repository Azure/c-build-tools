#Copyright (C) Microsoft Corporation. All rights reserved.

find_program(NUGET nuget)
if(NOT NUGET)
    message(FATAL "CMake could not find the nuget command line tool. Please install it!")
else()
    add_custom_target(traceabilitytool-nuget-restore
        COMMAND ${NUGET} restore ${CMAKE_CURRENT_LIST_DIR}/traceability_tool/packages.config -PackagesDirectory ${CMAKE_CURRENT_LIST_DIR}/packages -Verbosity detailed
    )
endif()

include_external_msproject(
    traceabilitytool ${CMAKE_CURRENT_LIST_DIR}/traceability_tool/traceabilitytool.csproj
    TYPE FAE04EC0-301F-11D3-BF4B-00C04F79EFBC)

add_dependencies(traceabilitytool traceabilitytool-nuget-restore)
