#Copyright (C) Microsoft Corporation. All rights reserved.

enable_language(CSharp)

set(CMAKE_CSharp_FLAGS "/langversion:latest /platform:x64")

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

set_property(TARGET traceabilitytool
    PROPERTY VS_PACKAGE_REFERENCES "DocumentFormat.OpenXml_2.9.1"
)

set_property(TARGET traceabilitytool
    PROPERTY DOTNET_TARGET_FRAMEWORK_VERSION "v4.7.2"
)

set_property(TARGET traceabilitytool
    PROPERTY VS_GLOBAL_RuntimeIdentifier "win-${CMAKE_VS_PLATFORM_NAME}"
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
