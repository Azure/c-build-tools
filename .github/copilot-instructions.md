# c-build-tools AI Coding Instructions

## Project Overview
This is a comprehensive C/C++ build infrastructure and quality assurance toolkit for Azure projects. It provides reusable CMake functions, Azure DevOps pipeline templates, C# analysis tools, and VS Code extensions for requirement tracking.

## Architecture & Key Components

### Build Functions (`build_functions/CMakeLists.txt`)
- **Core Purpose**: Centralized CMake utilities for consistent cross-project builds
- **Key Functions**: `set_default_build_options()`, `use_vcpkg()`, `build_as_csharp_net6_project()`
- **Compiler Flags**: Enforces `/W4 /WX /guard:cf /sdl` for MSVC, security-first defaults
- **VLD Integration**: Automatic Visual Leak Detector linking via `add_vld_if_defined()`

### Pipeline Templates (`pipeline_templates/`)
- **Usage Pattern**: Consumed via DevOps resources as `@c_build_tools` reference
- **Critical Templates**: `run_ctests_with_appverifier.yml`, `codeql3000_*.yml`, `logman_*.yml`
- **AppVerifier Workflow**: Enables → Run Tests → Disable (see template docs for binary suffix patterns)

### Quality Tools
- **Sarif Results Checker** (`sarif_results_checker/`): .NET 6 console app that fails builds on security violations
- **Traceability Tool** (`traceabilitytool/`): WinForms .NET 6 app for requirement-to-code mapping
- **Reals Check** (`reals_check/reals_check.ps1`): PowerShell script ensuring no unintended real function calls in test mocks

### vcpkg Integration
- **Custom Triplets**: `x64-windows-static-cbt.cmake` with security flags (`/guard:cf`) and ABI workarounds
- **Overlay Ports**: Custom package definitions in `overlay_ports/`
- **Cache Strategy**: Azure DevOps artifact feeds for binary caching via `VCPKG_BINARY_SOURCES`

## Development Workflows

### CMake Project Setup
```cmake
# Standard consumption pattern
if ((NOT TARGET c_build_tools) AND (EXISTS ${CMAKE_CURRENT_LIST_DIR}/deps/c-build-tools/CMakeLists.txt))
    add_subdirectory(deps/c-build-tools)
endif()

# Then call at end of root CMakeLists.txt
add_vld_if_defined(${CMAKE_CURRENT_SOURCE_DIR})
```

### Build Configuration
- **Environment Variable**: `BUILD_BINARIESDIRECTORY` controls output paths (maps to Azure DevOps `Build.BinariesDirectory`)
- **Key Options**: `use_vld`, `fsanitize_address`, `run_unittests`, `use_ltcg`, `use_guard_cf`
- **Architecture Detection**: Automatic via compiler symbol checks (`_M_AMD64`, `__x86_64__`, etc.)

### C# Projects
- Must include `csharp_sdk_fix/` subdirectory
- Use `build_as_csharp_net6_project()` helper
- Strong name signing with `MSSharedLibSN1024.snk`
- Only builds with Visual Studio generators (not Ninja)

### VS Code SRS Extension (`srs_extension/`)
- **Purpose**: Requirement tag insertion in markdown documents
- **Tag Format**: `SRS_SOMESTRING_<DEVID>_<REQID>`
- **Key Commands**: Alt+F8 (insert next), Alt+F9 (tag selected lines), Alt+F10 (strip tags)
- **Package Build**: `vsce package` after version bump in `package.json`

## Testing & Quality Gates

### Test Categories
- Unit tests: `run_unittests=ON`
- Integration: `run_int_tests=ON` 
- Performance: `run_perf_tests=ON`
- E2E: `run_e2e_tests=ON`

### Memory Analysis
- **VLD**: Set `use_vld=ON`, auto-links to executables (not C# projects)
- **AddressSanitizer**: `fsanitize_address=ON` (incompatible with VLD)
- **Valgrind**: Linux only, controlled via `run_valgrind`/`run_helgrind`/`run_drd`

### Static Analysis
- **Reals Check**: Scans static libraries for unexpected "real" function symbols
- **CodeQL3000**: Pipeline integration with SARIF validation
- **Traceability**: Requirement coverage analysis across Word docs and source

## Dependency Management

### Update Propagation (`update_deps/`)
- **Workflow**: `build_graph.ps1` → `propagate_updates.ps1` for bottom-up dependency updates
- **Requires**: Azure PAT with Code permissions, GitHub CLI authentication
- **Ignores**: Repository exclusions defined in `ignores.json`

## Project Conventions

### File Patterns
- Test executables: `*_ut_lib`, `*_int_lib`, `*_perf_lib` suffixes
- Binary naming: Often ends with `_exe_ebs.exe` in AppVerifier scenarios
- C# assemblies: Auto-signed, delay-signed with strong names

### Security Defaults
- Control Flow Guard always enabled (`/guard:cf`)
- CET Shadow Stack compatible (`/CETCOMPAT`)
- SDL security checks (`/sdl`)
- Segment heap via manifest embedding (Windows)

### Cross-Platform Notes
- MSVC: Full feature set with security hardening
- Linux/Unix: Valgrind integration, `-Werror -Wall` enforcement
- Architecture detection works across MSVC/GCC/Clang toolchains

## Common Patterns
- **Pipeline Integration**: Always use `@c_build_tools` resource reference, specify `repo_root` parameter
- **VLD Setup**: Call `add_vld_if_defined()` after all targets defined, auto-skips C# projects
- **vcpkg Usage**: Call `use_vcpkg(path)` with overlay triplets for consistent package management
- **Error Handling**: All builds treat warnings as errors (`/WX`, `-Werror`)
