// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace RepoValidation.Tests
{
    [TestClass]
    public class CSharpCombinedActAssertTests
    {
        [TestMethod]
        public void CombinedActAssertIsRejected()
        {
            // arrange
            int value = 1;

            // Act & Assert
            Assert.AreEqual(1, value);
        }
    }
}
