#Copyright (C) Microsoft Corporation. All rights reserved.

enable_language(CSharp)

set(CMAKE_CSharp_FLAGS "/langversion:latest /platform:${CMAKE_VS_PLATFORM_NAME}")

remove_definitions(-DBUILD_CONFIG=$<CONFIG>)

# Convert platform name to lowercase for NuGet RuntimeIdentifier
string(TOLOWER "${CMAKE_VS_PLATFORM_NAME}" PLATFORM_NAME_LOWER)

add_executable(traceabilitytool assemblyinfo.cs
    consolereportwriter.cs
    csvreportwriter.cs
    filefinder.cs
    invalidreqdictionary.cs
    mainform.cs
    mainform.designer.cs
    program.cs
    reportgenerator.cs
    reportwriter.cs
    reqpathmatrix.cs
    resources.designer.cs
    settings.designer.cs
)

set_property(TARGET traceabilitytool
    PROPERTY VS_PACKAGE_REFERENCES "DocumentFormat.OpenXml_2.9.1"
)

set_property(TARGET traceabilitytool
    PROPERTY DOTNET_TARGET_FRAMEWORK_VERSION "v4.8.1"
)

set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_RuntimeIdentifier "win-${PLATFORM_NAME_LOWER}"
)

# Include base 'win' RID for NuGet package compatibility
set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_RuntimeIdentifiers "win;win-${PLATFORM_NAME_LOWER}"
)

# Set PlatformTarget for native code generation
set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_PlatformTarget "${CMAKE_VS_PLATFORM_NAME}"
)

set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_CompilerGeneratedFilesOutputPath Generated
)

set_property(TARGET traceabilitytool PROPERTY VS_DOTNET_REFERENCES
    "Microsoft.CSharp"
    "System"
    "System.Core"
    "System.Data"
    "System.Drawing"
    "System.Windows.Forms"
)
