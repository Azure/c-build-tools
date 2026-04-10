// Integration test C# file in .IntTests directory with *Tests.cs naming
using System;

namespace MyProject.IntTests
{
    public class DotnetModuleIntTests
    {
        // Tests_SRS_DOTNET_MODULE_88_003: [ DotnetModule.Dispose shall release all resources. ]
        public void WhenDisposedThenResourcesAreReleased()
        {
            // arrange
            var module = DotnetModule.Create("test");

            // act
            module.Dispose();

            // assert
        }
    }
}
