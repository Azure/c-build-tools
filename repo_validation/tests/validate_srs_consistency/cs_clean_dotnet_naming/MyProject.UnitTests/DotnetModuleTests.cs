// Test C# file in .UnitTests directory with *Tests.cs naming
// Both the directory name and the filename should identify this as a test file
using System;

namespace MyProject.UnitTests
{
    public class DotnetModuleTests
    {
        // Tests_SRS_DOTNET_MODULE_88_001: [ DotnetModule.Create shall validate the input parameters. ]
        public void WhenNameIsNullThenCreateThrows()
        {
            Assert.ThrowsException<ArgumentNullException>(() => DotnetModule.Create(null));
        }

        // Tests_SRS_DOTNET_MODULE_88_002: [ DotnetModule.Create shall allocate resources. ]
        public void WhenAllOkThenCreateSucceeds()
        {
            var module = DotnetModule.Create("test");
            Assert.IsNotNull(module);
        }
    }
}
