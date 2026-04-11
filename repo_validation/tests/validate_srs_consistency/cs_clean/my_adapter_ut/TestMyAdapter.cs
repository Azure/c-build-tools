// Test C# file with correct Tests_SRS_ tags
using System;

namespace TestModule.Tests
{
    public class TestMyAdapter
    {
        // Tests_SRS_CS_MODULE_88_001: [ MyAdapter.Start shall validate parameters. ]
        public void WhenParamIsNullThenStartThrows()
        {
            var adapter = new MyAdapter();
            Assert.ThrowsException<ArgumentNullException>(() => adapter.Start(null));
        }

        // Tests_SRS_CS_MODULE_88_002: [ MyAdapter.Start shall allocate resources. ]
        public void WhenAllOkThenStartSucceeds()
        {
            var adapter = new MyAdapter();
            adapter.Start(new object());
        }
    }
}
