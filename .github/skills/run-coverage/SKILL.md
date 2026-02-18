---
name: run-coverage
description: Run MSVC code coverage on unit test executables using Microsoft.CodeCoverage.Console. Use this skill when the user wants to check code coverage, see uncovered lines, measure test coverage percentage, or identify untested code paths. Triggers include "coverage", "code coverage", "uncovered lines", "test coverage", "coverage report".
argument-hint: "<module_name> or <test_exe_path> [source filter patterns]"
---

# Code Coverage with MSVC

Run native C/C++ code coverage using `Microsoft.CodeCoverage.Console.exe` (Visual Studio Enterprise) and parse Cobertura XML results.

## Prerequisites

- Visual Studio Enterprise installed (provides `Microsoft.CodeCoverage.Console.exe`)
- Unit test executable already built (Debug configuration)

## Script Location

The coverage script is at `#file:../../scripts/run_coverage.ps1` (in the c-build-tools `.github/scripts/` directory).

For projects that consume c-build-tools as a submodule, the path is:
```
<repo_root>/deps/c-build-tools/.github/scripts/run_coverage.ps1
```

## Workflow

### Step 1: Identify the Test Executable

The test executable path follows the pattern:
```
$env:BUILD_BINARIESDIRECTORY\Debug\<target_name>\<target_name>.exe
```

Where `<target_name>` is typically `<module_name>_ut_exe_<project_name>` (e.g., `peer_library_ut_exe_zrpc`).

If the user provides just a module name, construct the full path:
```powershell
$testExe = "$env:BUILD_BINARIESDIRECTORY\Debug\<module>_ut_exe_<project>\<module>_ut_exe_<project>.exe"
```

Verify the executable exists before running coverage.

### Step 2: Determine Source Filter

The source filter uses wildcard patterns (`-like` matching) to select which source files appear in the report:
- Single file: `"*src\<module_name>.c"`
- All source files: `"*src\*.c"`
- Multiple patterns: `"*src\module1.c", "*src\module2.c"`

### Step 3: Run Coverage

Locate the script via the c-build-tools submodule path and run it. Always use `-ShowFunctions` and `-ShowUncoveredLines` for maximum detail.

```bash
pwsh -NoProfile -ExecutionPolicy Bypass -File "<repo_root>/deps/c-build-tools/.github/scripts/run_coverage.ps1" -TestExe "<test_exe_path>" -SourceFilter "*src\<module_name>.c" -ShowFunctions -ShowUncoveredLines
```

### Step 4: Analyze Results

The script outputs:
1. **Per-file summary table** - Lines, Covered, Uncovered, Pct% (color-coded: green >=80%, yellow >=50%, red <50%)
2. **Per-function coverage** (with `-ShowFunctions`) - Shows each function's coverage, sorted worst-first
3. **Uncovered line ranges** (with `-ShowUncoveredLines`) - Groups consecutive uncovered lines into ranges (e.g., "Lines: 45-52, 78, 90-95")
4. **Cobertura XML file** - Saved to `<script_dir>/coverage/` with timestamp

### Step 5: Report to User

Summarize:
- Overall coverage percentage
- Functions with lowest coverage (potential areas to add tests)
- Specific uncovered line ranges that may need test coverage

If the user wants to improve coverage, read the uncovered lines from the source file to understand what code paths are not exercised, then suggest specific test cases.

## Script Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-TestExe` | Yes | Path to the unit test executable |
| `-SourceFilter` | No | Wildcard patterns to filter source files (e.g., `"*src\module.c"`) |
| `-OutputDir` | No | Directory for coverage output (default: `<script_dir>/coverage/`) |
| `-ShowFunctions` | No | Show per-function coverage breakdown |
| `-ShowUncoveredLines` | No | List uncovered line numbers/ranges |
| `-SettingsFile` | No | XML settings file for fine-grained instrumentation control |

## Examples

### Coverage for a single module
```bash
pwsh -NoProfile -ExecutionPolicy Bypass -File "deps/c-build-tools/.github/scripts/run_coverage.ps1" -TestExe "$BUILD_BINARIESDIRECTORY/Debug/my_module_ut_exe_myproject/my_module_ut_exe_myproject.exe" -SourceFilter "*src\my_module.c" -ShowFunctions -ShowUncoveredLines
```

### Coverage for all source files in a test
```bash
pwsh -NoProfile -ExecutionPolicy Bypass -File "deps/c-build-tools/.github/scripts/run_coverage.ps1" -TestExe "$BUILD_BINARIESDIRECTORY/Debug/my_module_ut_exe_myproject/my_module_ut_exe_myproject.exe" -SourceFilter "*src\*.c" -ShowFunctions
```

### Quick summary (no function/line detail)
```bash
pwsh -NoProfile -ExecutionPolicy Bypass -File "deps/c-build-tools/.github/scripts/run_coverage.ps1" -TestExe "$BUILD_BINARIESDIRECTORY/Debug/my_module_ut_exe_myproject/my_module_ut_exe_myproject.exe" -SourceFilter "*src\my_module.c"
```

## Troubleshooting

- **"vswhere.exe not found"**: Visual Studio is not installed
- **"Microsoft.CodeCoverage.Console.exe not found"**: VS Enterprise is required (Community/Professional don't include this tool)
- **"Coverage file was not created"**: The test executable crashed or failed. Run the test directly to see the error.
- **"No source files matched the filter"**: Check the `-SourceFilter` pattern. Use `*src\*.c` to see all files, then narrow down. Patterns use `-like` (wildcard), not regex.
- **Test failures in output**: Coverage is still collected even if some tests fail. The coverage report reflects whatever code paths were executed.

## Output Location

Coverage XML files are saved with timestamped names:
```
<script_dir>/coverage/<test_name>_<YYYYMMDD_HHmmss>.cobertura.xml
```
