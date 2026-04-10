// Production C# file with Codes_SRS_ tags
using System;

namespace MyProject
{
    public class DotnetModule
    {
        // Codes_SRS_DOTNET_MODULE_88_001: [ DotnetModule.Create shall validate the input parameters. ]
        public static DotnetModule Create(string name)
        {
            if (name == null) throw new ArgumentNullException(nameof(name));
            return new DotnetModule();
        }

        // Codes_SRS_DOTNET_MODULE_88_002: [ DotnetModule.Create shall allocate resources. ]
        private DotnetModule()
        {
        }

        // Codes_SRS_DOTNET_MODULE_88_003: [ DotnetModule.Dispose shall release all resources. ]
        public void Dispose()
        {
        }
    }
}
