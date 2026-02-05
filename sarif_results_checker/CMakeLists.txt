#Copyright (C) Microsoft Corporation. All rights reserved.

# Convert platform name to lowercase for NuGet RuntimeIdentifier
string(TOLOWER "${CMAKE_VS_PLATFORM_NAME}" PLATFORM_NAME_LOWER)

# Use dynamic platform for native x64/ARM64 builds
set(CMAKE_CSharp_FLAGS "/langversion:latest /platform:${CMAKE_VS_PLATFORM_NAME}")

add_executable(Azure.Messaging.SarifResultsChecker
    Program.cs
    Options.cs
    App.config)

set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY VS_PACKAGE_REFERENCES
        "CommandLineParser_2.9.1"
        "Sarif.Sdk_4.4.0"
        "Newtonsoft.Json_13.0.3"
        "System.Collections.Immutable_1.5.0"
)

set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY VS_GLOBAL_TreatWarningsAsErrors true
)

set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY DOTNET_TARGET_FRAMEWORK_VERSION "v4.8.1"
)

if (EXISTS ${PROJECT_SOURCE_DIR}/MSSharedLibSN1024.snk)
    set_target_properties(Azure.Messaging.SarifResultsChecker PROPERTIES
        VS_GLOBAL_AssemblyOriginatorKeyFile "${PROJECT_SOURCE_DIR}/MSSharedLibSN1024.snk"
        VS_GLOBAL_SignAssembly true
        VS_GLOBAL_DelaySign true
    )
endif()

set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY VS_GLOBAL_CompilerGeneratedFilesOutputPath Generated
)

set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY VS_GLOBAL_RuntimeIdentifier "win-${PLATFORM_NAME_LOWER}"
)

# Include base 'win' RID for NuGet package compatibility
set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY VS_GLOBAL_RuntimeIdentifiers "win;win-${PLATFORM_NAME_LOWER}"
)

# Set PlatformTarget for native code generation
set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY VS_GLOBAL_PlatformTarget "${CMAKE_VS_PLATFORM_NAME}"
)

set_output_folder_properties(Azure.Messaging.SarifResultsChecker)

set_target_properties(Azure.Messaging.SarifResultsChecker PROPERTIES
    FOLDER "tools")
