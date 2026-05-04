// Production C# file with correct Codes_SRS_ tags
using System;

namespace TestModule
{
    public class MyAdapter
    {
        // Codes_SRS_CS_MODULE_88_001: [ MyAdapter.Start shall validate parameters. ]
        public void Start(object param)
        {
            if (param == null)
            {
                throw new ArgumentNullException(nameof(param));
            }

            // Codes_SRS_CS_MODULE_88_002: [ MyAdapter.Start shall allocate resources. ]
            var resource = new object();
        }
    }
}
