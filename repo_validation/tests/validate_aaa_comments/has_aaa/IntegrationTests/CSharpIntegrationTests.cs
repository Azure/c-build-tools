// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace RepoValidation.IntegrationTests
{
    [TestClass]
    public class CSharpIntegrationAaaTests
    {
        [TestMethod]
        public void IntegrationStyleTestHasAaa()
        {
            // arrange
            string expected = "value";

            // act
            string actual = expected;

            // assert
            Assert.AreEqual(expected, actual);
        }
    }
}
