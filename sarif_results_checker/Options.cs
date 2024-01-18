// //------------------------------------------------------------
// // Copyright (c) Microsoft Corporation.  All rights reserved.
// //------------------------------------------------------------

namespace Azure.Messaging.SarifResultsChecker
{
    using CommandLine;

    internal class Options
    {
        internal const string DefaultSarifPath = ".";
        internal const string DefaultIgnorePaths = "";

        [Option('f', "sarifPath", Default = DefaultSarifPath, HelpText = "Path where Sarif files to be checked exist.")]
        public string SarifPath
        {
            get;
            set;
        }
        [Option('i', "ignorePaths", Default = DefaultIgnorePaths, HelpText = "Paths to folders containing files to be ignored during the check (semicolon delimited).")]
        public string IgnorePaths
        {
            get;
            set;
        }
    }
}