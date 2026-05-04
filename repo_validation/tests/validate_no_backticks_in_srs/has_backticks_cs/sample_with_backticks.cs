// C# file with SRS tags containing backticks (violation)
using System;

public class BadModule
{
    // Codes_SRS_BAD_CS_01_001: [ `BadModule.Init` shall validate `parameters`. ]
    public void Init(object param) { }

    // Codes_SRS_BAD_CS_01_002: [ `BadModule.Init` shall return `true` on success. ]
    public bool Init2() { return true; }
}
