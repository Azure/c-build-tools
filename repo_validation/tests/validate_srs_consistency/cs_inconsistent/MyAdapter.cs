// Production C# file with inconsistent SRS tag text
using System;

namespace TestModule
{
    public class MyAdapter
    {
        // Codes_SRS_CS_INCONSISTENT_88_001: [ MyAdapter.Start shall validate parameters. ]
        public void Start(object param)
        {
            if (param == null)
            {
                throw new ArgumentNullException(nameof(param));
            }

            // Codes_SRS_CS_INCONSISTENT_88_002: [ MyAdapter.Start shall allocate initial resources. ]
            var resource = new object();
        }
    }
}
