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
            // arrange
            string name = null;

            // act
            // assert
            Assert.ThrowsException<ArgumentNullException>(() => DotnetModule.Create(name));
        }

        // Tests_SRS_DOTNET_MODULE_88_002: [ DotnetModule.Create shall allocate resources. ]
        public void WhenAllOkThenCreateSucceeds()
        {
            // arrange
            string name = "test";

            // act
            var module = DotnetModule.Create(name);

            // assert
            Assert.IsNotNull(module);
        }
    }
}
