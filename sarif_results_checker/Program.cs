// //------------------------------------------------------------
// // Copyright (c) Microsoft Corporation.  All rights reserved.
// //------------------------------------------------------------

namespace Azure.Messaging.SarifResultsChecker
{
    using CommandLine;
    using Microsoft.CodeAnalysis.Sarif;
    using System;
    using System.Collections.Generic;
    using System.IO;
    using System.Text;

    internal class Program
    {
        static string resultInfoToString(Result result)
        {
            StringBuilder stringBuilder = new StringBuilder();
            stringBuilder.AppendLine($"{{");
            stringBuilder.AppendLine($"  RuleId: {result.RuleId}");
            stringBuilder.AppendLine($"  Level: {result.Level}");
            stringBuilder.AppendLine($"  Kind: {result.Kind}");
            stringBuilder.AppendLine($"  Message: {result.Message.Text}");
            stringBuilder.AppendLine($"  Locations:");

            foreach (Location location in result.Locations)
            {
                stringBuilder.AppendLine($"    {location.PhysicalLocation.ArtifactLocation.Uri.OriginalString}");
            }
            stringBuilder.AppendLine($"}}");
            return stringBuilder.ToString();
        }
        static void Main(string[] args)
        {
            Parser.Default.ParseArguments<Options>(args)
                .WithParsed((options) =>
                {
                    // Print the options that we're running with
                    Console.WriteLine($"Running with options:");
                    Console.WriteLine($"  SarifPath: {options.SarifPath}");
                    Console.WriteLine($"  IgnorePaths: {options.IgnorePaths}");

                    // Enumerate all files in the folder
                    IEnumerable<string> files = Directory.EnumerateFiles(options.SarifPath, "*.sarif", SearchOption.AllDirectories);
                    bool errorsDetected = false;

                    // create an array with paths to be ignored
                    string[] pathsToIgnore = options.IgnorePaths.Split(';');

                    foreach (string file in files)
                    {
                        Console.WriteLine($"Looking at file {file}");
                        SarifLog log = SarifLog.Load(file);

                        // check and print errors
                        foreach (Result result in log.Runs[0].Results)
                        {
                            if ((result.Level == FailureLevel.Error) ||
                                (result.Level == FailureLevel.Warning))
                            {
                                // check if there are any suppressions for this error
                                bool isSuppressed = false;

                                if (!result.TryIsSuppressed(out isSuppressed))
                                {
                                    // could not get suppression status, assuming not suppressed
                                }

                                if (!isSuppressed)
                                {
                                    // check if all locations are ignored
                                    bool allLocationsIgnored = true;

                                    foreach (Location location in result.Locations)
                                    {
                                        // check if this location is ignored
                                        bool locationIsIgnored = false;
                                        foreach (string pathToIgnore in pathsToIgnore)
                                        {
                                            if (location.PhysicalLocation.ArtifactLocation.Uri.OriginalString.StartsWith(pathToIgnore))
                                            {
                                                locationIsIgnored = true;
                                                break;
                                            }
                                        }

                                        if (!locationIsIgnored)
                                        {
                                            allLocationsIgnored = false;
                                            break;
                                        }
                                    }

                                    if (allLocationsIgnored)
                                    {
                                        isSuppressed = true;
                                    }
                                }

                                if (!isSuppressed)
                                {
                                    Console.WriteLine($"Will fail check due to result: {resultInfoToString(result)}");
                                    errorsDetected = true;
                                }
                            }
                        }
                    }

                    if (errorsDetected)
                    {
                        throw new InvalidOperationException("Errors detected in SARIF files.");
                    }
                });
        }
    }
}
