# c-build-tools AI Coding Instructions

## General Coding Standards
**IMPORTANT**: All code changes must follow the comprehensive coding standards defined in #file:./general_coding_instructions.md This includes:
- Function naming conventions (snake_case, module prefixes, internal function patterns)
- Parameter validation rules and error handling patterns
- Variable naming and result variable conventions
- Header inclusion order and memory management requirements
- Requirements traceability system (SRS/Codes_SRS/Tests_SRS patterns)
- Async callback patterns and goto usage rules
- Indentation, formatting, and code structure guidelines

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
  - **Configuration**: Add to CMakeLists.txt with `add_custom_target(project_traceability ALL COMMAND traceabilitytool -buildcheck ...)`
  - **Exclusions**: Use separate `-e` options for each excluded directory (e.g., `-e ${CMAKE_CURRENT_LIST_DIR}/deps -e ${CMAKE_CURRENT_LIST_DIR}/.github`)
  - **Includes**: Use `-i ${CMAKE_CURRENT_LIST_DIR}` to specify root directory to scan
  - **Common Exclusions**: Always exclude `deps/` (dependencies) and `.github/` (documentation) folders
- **Reals Check** (`reals_check/reals_check.ps1`): PowerShell script ensuring no unintended real function calls in test mocks
- **Repository Validation** (`repo_validation/`): Extensible framework for repository-wide validation checks
  - **Purpose**: Runs standardized validation scripts across the entire repository
  - **Dependency Exclusion**: Automatically excludes specified directories from scanning and modification
  - **CMake Options**:
    - `run_repo_validation=ON` - Enable the validation target (default is OFF)
    - `fix_repo_validation_errors=ON` - Automatically fix validation errors (default is OFF)
  - **Usage**: Call `add_repo_validation(project_name [EXCLUDE_FOLDERS folder1 folder2 ...])` in CMakeLists.txt
    - Default exclusions if not specified: `cmake deps`
  - **Examples**: 
    - `add_repo_validation(my_project)` - Uses default exclusions (cmake, deps)
    - `add_repo_validation(my_project EXCLUDE_FOLDERS deps cmake external)` - Custom exclusions
  - **Running**: `cmake --build . --target project_name_repo_validation`
  - **Fix Mode**: When `fix_repo_validation_errors=ON`, scripts receive `-Fix` parameter to auto-correct issues (excluding specified directories)
  - **Available Validations**: 
    - **File Ending Newline** (`validate_file_endings.ps1`): Ensures source files (`.h`, `.hpp`, `.c`, `.cpp`, `.cs`) end with proper newline (CRLF on Windows)
    - **Requirements Document Naming**: Ensures requirement documents in `devdoc/` folders follow `{module_name}_requirements.md` convention (detects files with SRS tags)
    - **SRS Requirement Consistency** (`validate_srs_consistency.ps1`): Validates that SRS requirement text matches between markdown documentation and C code comments (`Codes_SRS_` and `Tests_SRS_` patterns). Preserves original prefix (Tests_ or Codes_) when fixing inconsistencies.
    - **SRS Tag Uniqueness** (`validate_srs_uniqueness.ps1`): Detects duplicate SRS tags across all requirement documents. **Never auto-fixes** - requires manual resolution to ensure proper requirement management.
    - **Tab Character Validation** (`validate_no_tabs.ps1`): Ensures source files do not contain tab characters (replaces with 4 spaces in fix mode)
    - **VLD Include Validation** (`validate_no_vld_include.ps1`): Ensures source files (`.h`, `.hpp`, `.c`, `.cpp`) do not explicitly include `vld.h`. VLD should be integrated through the build system via `add_vld_if_defined()` CMake function, not hardcoded in source files.
    - See `repo_validation/README.md` for complete list and details
  - **Adding Validations**: Create `.ps1` scripts in `repo_validation/scripts/` accepting `-RepoRoot`, `-ExcludeFolders`, and optional `-Fix` parameters
  - **Testing Requirements**: **Every new validation script MUST include corresponding test cases** following the established template:
    - Create test module directory: `repo_validation/tests/validate_your_feature/`
    - Include realistic test data with positive cases (compliant files) and negative cases (files with violations)
    - Create `CMakeLists.txt` with three test targets following the pattern:
      - **Detection test**: Verify script correctly identifies violations in negative test cases
      - **Clean test**: Verify script doesn't modify files that are already compliant  
      - **Fix test**: Verify script correctly fixes violations and files pass validation afterward
    - Follow naming pattern: `test_validate_your_feature_detection`, `test_validate_your_feature_clean`, `test_validate_your_feature_fix`
    - Use temporary directories for fix tests to avoid contamination between test runs
    - Test targets must be available via `cmake --build . --target test_validate_your_feature`
    - Tests automatically registered with CTest when `run_unittests=ON`
    - Reference existing test modules (e.g., `validate_no_tabs/`, `validate_file_endings/`) for implementation patterns
  - **CI/CD Integration**: Include in pipelines with `-Drun_repo_validation=ON` to enforce validation as quality gate

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
- **Traceability**: Requirement coverage analysis across .md files and source
  - **Purpose**: Ensures all SRS requirements have corresponding Codes_SRS implementations and Tests_SRS test coverage
  - **Exclusion Strategy**: Use multiple `-e` flags to exclude directories that shouldn't be scanned (deps, .github, build artifacts)
  - **Quality Gate**: Build fails if requirements are duplicated, missing implementation, or missing tests

## Dependency Management

### Update Propagation (`update_deps/`)
- **Workflow**: `build_graph.ps1` → `propagate_updates.ps1` for bottom-up dependency updates
- **Requires**: Azure PAT with Code permissions, GitHub CLI authentication
- **Ignores**: Repository exclusions defined in `ignores.json`

## Project Conventions

### File Patterns
- Test executables: `*_ut_lib`, `*_int_lib`, `*_perf_lib` suffixes
- Binary naming: Often ends with `_exe_X.exe`, where X is the name of the project (for example, ebs, zrpc, etc.)
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

