
# Build defaults

`set_default_build_options()` uses C17 and at least C++23; a newer caller-selected C++ standard is kept. MSVC uses `/std:c++23` (19.52+) or `/std:c++23preview` (19.43-19.51). Visual Studio generators set the project's C++ Language Standard to `stdcpp23` instead, which MSBuild applies only to C++ sources and emits as `/std:c++23` on toolsets that support it.

# Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.microsoft.com.

When you submit a pull request, a CLA-bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., label, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

