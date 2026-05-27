// Copyright (c) Microsoft. All rights reserved.
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

using Microsoft.VisualStudio.TestTools.UnitTesting;
using System.Threading.Tasks;

namespace RepoValidation.Tests
{
    [TestClass]
    public class CSharpAaaTests
    {
        [TestMethod]
        public void TestMethodHasAaa()
        {
            // arrange
            int value = 1;

            // act
            int actual = value;

            // assert
            Assert.AreEqual(1, actual);
        }

        [DataTestMethod]
        [DataRow(1)]
        public async Task DataTestMethodHasAaaAsync(int value)
        {
            // arrange
            await Task.CompletedTask;

            // act
            int actual = value;

            // assert
            Assert.AreEqual(value, actual);
        }

        [TestMethod]
        public async ValueTask ValueTaskMethodHasAaaAsync()
        {
            // arrange
            await ValueTask.CompletedTask;

            // act
            int actual = 1;

            // assert
            Assert.AreEqual(1, actual);
        }

        [TestMethod]
        public void
            MultilineSignatureHasAaa()
        {
            // arrange
            int value = 1;

            // act
            int actual = value;

            // assert
            Assert.AreEqual(1, actual);
        }

        [TestMethod]
        public void TestMethodUsesHelpersForAaa()
        {
            int value = ArrangeValue();
            int actual = ActOnValue(value);
            AssertValue(value, actual);
        }

        [TestMethod] // no-aaa
        public void IntentionalExemption() => Assert.IsTrue(true);

        private int ArrangeValue()
        {
            // arrange
            return 1;
        }

        private int ActOnValue(int value)
        {
            // act
            return value;
        }

        private void AssertValue(int expected, int actual)
        {
            // assert
            Assert.AreEqual(expected, actual);
        }
    }
}
