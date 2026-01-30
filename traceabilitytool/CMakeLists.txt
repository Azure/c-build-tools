#Copyright (C) Microsoft Corporation. All rights reserved.

enable_language(CSharp)

# csharp_sdk_fix is required for .NET 8+ projects
add_subdirectory(csharp_sdk_fix)

remove_definitions(-DBUILD_CONFIG=$<CONFIG>)

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

# Use .NET 8 for command-line application
build_as_csharp_net8_project(traceabilitytool)

# Override RuntimeIdentifier to use lowercase format required by .NET 8+
string(TOLOWER "${CMAKE_VS_PLATFORM_NAME}" platform_lower)
set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_RuntimeIdentifier "win-${platform_lower}"
)

# Disable assembly signing since MSSharedLibSN1024.snk doesn't exist in this repo
set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_SignAssembly false
)

set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_DelaySign false
)

# Disable auto-generation of assembly info attributes that conflict with assemblyinfo.cs
set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_GenerateAssemblyInfo false
)

# Add required package references
set_property(TARGET traceabilitytool
    PROPERTY VS_PACKAGE_REFERENCES 
        "DocumentFormat.OpenXml_2.9.1"
)

set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_CompilerGeneratedFilesOutputPath Generated
)
