#Copyright (C) Microsoft Corporation. All rights reserved.

add_executable(Azure.Messaging.SarifResultsChecker
    Program.cs
    Options.cs
    App.config)

set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY VS_PACKAGE_REFERENCES
        "CommandLineParser_2.9.1"
        "Sarif.Sdk_4.4.0"
        "Newtonsoft.Json_13.0.1"
        "System.Collections.Immutable_1.5.0"
)

set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY VS_GLOBAL_TreatWarningsAsErrors true
)

set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY DOTNET_TARGET_FRAMEWORK_VERSION "v4.7.2"
)

if (EXISTS $ENV{Build_SourcesDirectory}/import_for_signing.not_propz_at_all)
    set_property(TARGET Azure.Messaging.SarifResultsChecker
        PROPERTY VS_PROJECT_IMPORT $ENV{Build_SourcesDirectory}/import_for_signing.not_propz_at_all
    )
endif()

set_property(TARGET Azure.Messaging.SarifResultsChecker
    PROPERTY VS_GLOBAL_CompilerGeneratedFilesOutputPath Generated
)

set_output_folder_properties(Azure.Messaging.SarifResultsChecker)

set_target_properties(Azure.Messaging.SarifResultsChecker PROPERTIES
    FOLDER "tools")
