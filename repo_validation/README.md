# Repository Validation

This directory contains validation scripts and CMake functions to perform various checks on the repository.

## Overview

The repository validation framework provides a standardized way to run validation checks across the entire repository. These validations ensure code quality, consistency, and adherence to project standards.

## Usage

### CMake Options

Two CMake options control the repository validation behavior:

- **`run_repo_validation`** (default: OFF) - Set to ON to enable the repository validation target
- **`fix_repo_validation_errors`** (default: OFF) - Set to ON to automatically fix validation errors when running validation

### Adding Validation to Your Project

To add repository validation to your CMakeLists.txt:

```cmake
# Include c-build-tools (if not already included)
add_subdirectory(deps/c-build-tools)

# Add repository validation target
add_repo_validation(your_project_name)
```

This will create a CMake target named `your_project_name_repo_validation` **only if** `run_repo_validation=ON`.

### Customizing Excluded Folders

You can specify which folders to exclude from validation:

```cmake
# Exclude specific folders from validation
add_repo_validation(my_project EXCLUDE_FOLDERS deps cmake build external)

# Only exclude cmake folder and deps (default if not specified)
add_repo_validation(my_project EXCLUDE_FOLDERS cmake deps)
```

**Default exclusions**: If `EXCLUDE_FOLDERS` is not specified, the default is `cmake deps`.

**How Exclusions Work:**
- The `EXCLUDE_FOLDERS` parameter completely controls which folders are excluded
- If not specified, defaults to `cmake deps`
- You can override with any list of folders: `EXCLUDE_FOLDERS .git build external`
- Exclusions are relative paths from repository root
- Matching is done on path prefixes (e.g., `deps` excludes `deps/` and all subdirectories)

This approach ensures that:
- You have full control over which directories are excluded
- Common patterns (cmake, deps) are excluded by default for convenience
- You can add project-specific exclusions as needed

### Generating with Validation Enabled

```bash
# Enable validation during CMake generation
cmake -S . -B build -Drun_repo_validation=ON
```

### Running Repo Validation

To run all repo validation checks:

```bash
# Using CMake (validation only, report errors)
cmake --build . --target your_project_name_repo_validation

# Or using Visual Studio
# Build the "your_project_name_repo_validation" target from the solution
```

### Auto-Fixing Validation Errors

When you configure CMake with `-Dfix_repo_validation_errors=ON`, the validation scripts will automatically attempt to fix any validation errors they encounter:

```bash
# Configure with fix mode enabled
cmake -S . -B build -Drun_repo_validation=ON -Dfix_repo_validation_errors=ON

# Run validation (will fix errors)
cmake --build build --target your_project_name_repo_validation
```

**Note**: The `-Fix` parameter is automatically passed to all validation scripts when `fix_repo_validation_errors=ON`.

## Available Validations

### File Ending Newline Validation

**Script:** `scripts/validate_file_endings.ps1`

**Purpose:** Ensures all source code files (`.h`, `.hpp`, `.c`, `.cpp`, `.cs`) end with a newline character (CRLF on Windows).

**Exclusions:** 
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**Rationale:** Source files must end with a newline to comply with:
- C language standards (files should end with a newline)
- Consistent file formatting across the codebase

**Fix Mode:** When run with `-Fix` parameter, the script automatically corrects files:
- Adds CRLF to files that end abruptly without any newline
- Converts LF-only endings to CRLF (Windows standard)
- Converts CR-only endings to CRLF
- **Does not modify any files in excluded directories**

**Git Configuration Considerations:**
This validation enforces CRLF line endings on Windows to ensure consistency across the codebase. To work effectively with this validation:

- **Recommended Git setting**: `git config core.autocrlf input` 
  - This preserves CRLF in working directory but converts to LF in repository
  - Prevents Git from auto-converting line endings and potentially breaking the validation
- **Repository uses**: `* text=auto` in `.gitattributes` (auto line ending normalization)
- **Mixed line endings**: Many repositories currently contain a mix of CRLF and LF endings
- **Goal**: Standardize all source files to CRLF endings on Windows for consistency

**Note**: The `autocrlf=input` setting works best with this validation because it preserves the CRLF endings that the script enforces while still normalizing to LF for storage in Git.

**Manual Fix Options:**
- **Manual Verification**: Check that the cursor can move one line past the last line of code in your editor
- **Manual Fix**: Add a final newline (CRLF on Windows) at the end of the file
- **Automated Prevention**: Configure `.editorconfig` with `insert_final_newline = true`

### Requirements Document Naming Validation

**Script:** `scripts/validate_requirements_naming.ps1`

**Purpose:** Ensures that requirement documents in `devdoc` folders follow the naming convention `{module_name}_requirements.md`.

**Detection:** A markdown file in a `devdoc` folder is considered a requirements document if it contains SRS (Software Requirements Specification) tags matching the pattern: `SRS_{MODULE}_{DEVID}_{REQID}` (e.g., `SRS_MY_MODULE_01_001`)

**Exclusions:**
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**Rationale:** Consistent naming conventions for requirement documents:
- Makes requirements easier to locate by module name
- Clearly identifies files as containing formal requirements
- Improves traceability tooling and automation
- Follows established project conventions

**Fix Mode:** When run with `-Fix` parameter, the script automatically renames files:
- Appends `_requirements` to the base filename (e.g., `module.md` → `module_requirements.md`)
- Preserves the original module name from the filename
- **Does not rename if target file already exists** (to prevent overwriting)
- **Does not modify any files in excluded directories**

**Manual Fix Options:**
- Rename requirement documents to follow `{module_name}_requirements.md` convention
- Ensure the module name matches the component being documented

### SRS Requirement Consistency Validation

**Script:** `scripts/validate_srs_consistency.ps1`

**Purpose:** Ensures that SRS (Software Requirements Specification) requirement text is identical between requirement documents and C code comments.

**Detection:** The script:
1. Extracts all SRS tags from markdown files in `devdoc/` folders (pattern: `**SRS_MODULE_ID_NUM: [** text **]**`)
2. Finds corresponding SRS tags in C source files (patterns: `/* Codes_SRS_MODULE_ID_NUM: [ text ]*/` or `/* Tests_SRS_MODULE_ID_NUM: [ text ]*/`)
3. Strips markdown formatting (backticks, bold, italics) from markdown text
4. Compares the cleaned text content for exact matches

**Exclusions:**
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**Rationale:** Keeping requirements synchronized between documentation and code:
- Ensures code comments accurately reflect documented requirements
- Maintains traceability between specifications and implementation
- Prevents drift between requirements and actual code behavior
- Supports requirement coverage analysis tools

**Fix Mode:** When run with `-Fix` parameter, the script automatically updates C code comments:
- Replaces C comment text with the text from requirement documents (after stripping markdown)
- Updates both `Codes_SRS_` and `Tests_SRS_` prefixed comments
- Preserves comment structure and formatting
- **Does not modify any files in excluded directories**
- **Does not modify markdown requirement documents** (they are the source of truth)

**Common Inconsistencies Detected:**
- Wrong variable/function names in C comments (e.g., `state` vs `waiter_state`)
- Missing or incomplete text in C comments
- Extra or missing whitespace
- Typographical errors in C comments

**Manual Fix Options:**
- Update C code comments to match the requirement document text exactly
- Ensure markdown formatting is used correctly in requirement documents

### Tab Character Validation

**Script:** `scripts/validate_no_tabs.ps1`

**Purpose:** Ensures that source code files do not contain tab characters (ASCII 9).

**Rationale:** Tab characters should not be used in source files because:
- Different editors render tabs with different widths (2, 4, or 8 spaces)
- Causes inconsistent code alignment and formatting
- Can break code that depends on specific indentation
- Mixing tabs and spaces creates confusing visual formatting
- Standard coding conventions require spaces for indentation

**Exclusions:**
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**File Types Checked:** `.h`, `.hpp`, `.c`, `.cpp`, `.cs`

**Fix Mode:** When run with `-Fix` parameter, the script automatically replaces all tabs with 4 spaces:
- Replaces every tab character (`\t`) with exactly 4 space characters
- Preserves file encoding (uses UTF-8 without BOM)
- **Does not modify any files in excluded directories**

**Manual Fix Options:**
- Configure your editor to use spaces instead of tabs
- Set tab width to 4 spaces in editor settings
- Use "Convert Indentation to Spaces" feature in your editor


### VLD Include Validation

**Script:** `scripts/validate_no_vld_include.ps1`

**Purpose:** Ensures that source code files do not explicitly include `vld.h` (Visual Leak Detector header).

**Rationale:** VLD should be integrated through the build system, not included directly in source files:
- Prevents VLD from being accidentally enabled in production builds
- Ensures VLD integration is controlled via CMake options (`use_vld`)
- Avoids hardcoded dependencies on debugging tools in source code
- Allows conditional VLD enabling without modifying source files
- Follows best practice of separating debug tooling from production code

**Exclusions:**
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**File Types Checked:** `.h`, `.hpp`, `.c`, `.cpp`, `.txt`

**Detection:** The script scans for any form of `#include` directive that references `vld.h`:
- `#include "vld.h"`
- `#include <vld.h>`
- `#  include "vld.h"` (with extra whitespace)
- Reports the line number and content of each violation

**Fix Mode:** When run with `-Fix` parameter, the script automatically removes lines containing `vld.h` includes:
- Removes all lines matching the `#include` pattern for `vld.h`
- Preserves file encoding (uses UTF-8 without BOM)
- **Does not modify any files in excluded directories**

**Manual Fix Options:**
- Remove explicit `#include "vld.h"` or `#include <vld.h>` directives from source files
- Use the `add_vld_if_defined()` CMake function to enable VLD integration when the `use_vld` option is set
- VLD will be automatically linked to executables through the build system when enabled


### ENABLE_MOCKS Pattern Validation

**Script:** `scripts/validate_enable_mocks_pattern.ps1`

**Purpose:** Ensures that source code files use the modern include-based pattern for enabling/disabling mocks instead of deprecated preprocessor directives.

**Rationale:** The modern pattern using include files provides several advantages:
- More explicit and searchable mock enable/disable markers in code
- Easier to track and maintain mock regions with consistent comments
- Reduces preprocessor macro pollution in the global namespace
- Better integration with modern build systems and tools
- Clear visual separation of mock sections with comment markers
- Follows established conventions in Azure C libraries

**Exclusions:**
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**File Types Checked:** `.h`, `.c`, `.cpp`

**Detection:** The script scans for deprecated patterns:
- `#define ENABLE_MOCKS` (with optional whitespace)
- `#undef ENABLE_MOCKS` (with optional whitespace)

**Correct Pattern:** Files should use:
```c
#include "umock_c/umock_c_ENABLE_MOCKS.h"  // ============================== ENABLE_MOCKS
// ... mock includes here ...
#include "umock_c/umock_c_DISABLE_MOCKS.h" // ============================== DISABLE_MOCKS
```

**Deprecated Pattern:** Files should NOT use:
```c
#define ENABLE_MOCKS
// ... mock includes here ...
#undef ENABLE_MOCKS
```

**Fix Mode:** When run with `-Fix` parameter, the script automatically replaces deprecated patterns:
- Replaces `#define ENABLE_MOCKS` with `#include "umock_c/umock_c_ENABLE_MOCKS.h" // ============================== ENABLE_MOCKS`
- Replaces `#undef ENABLE_MOCKS` with `#include "umock_c/umock_c_DISABLE_MOCKS.h" // ============================== DISABLE_MOCKS`
- Preserves file encoding (uses UTF-8 without BOM)
- Handles multiple mock sections in the same file
- **Does not modify any files in excluded directories**

**Manual Fix Options:**
- Replace `#define ENABLE_MOCKS` with the include statement for `umock_c_ENABLE_MOCKS.h`
- Replace `#undef ENABLE_MOCKS` with the include statement for `umock_c_DISABLE_MOCKS.h`
- Ensure the comment markers are included for easy visual identification


### SRS Tag Uniqueness Validation

**Script:** `scripts/validate_srs_uniqueness.ps1`

**Purpose:** Ensures that all SRS (Software Requirements Specification) requirement tags are unique across all requirement documents in the repository.

**Rationale:** Each SRS tag must be unique to:
- Prevent ambiguity in requirement tracking and traceability
- Ensure accurate mapping between requirements, implementation, and tests
- Avoid confusion when referencing requirements in code comments
- Maintain integrity of the requirements management system

**Exclusions:**
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**File Types Checked:** Markdown files (`.md`) in `devdoc/` directories

**Fix Mode:** **This script NEVER auto-fixes duplicate SRS tags**, even when run with `-Fix` parameter:
- Duplicate SRS tags require manual resolution by the developer
- The script will display an informational message that fix mode is ignored
- Exit code 1 is always returned when duplicates are found
- **Rationale**: Fixing duplicate SRS IDs requires understanding the requirements to determine if they should be:
  - Merged (if truly the same requirement)
  - Renumbered (if different requirements with accidentally duplicated IDs)

**Detection:** The script scans all markdown files in `devdoc/` folders and reports:
- Each duplicate SRS tag found
- File names and line numbers for both occurrences
- Clear error messages indicating manual action is required

**Manual Fix Required:**
When duplicates are found, resolve them by:
1. **If requirements are identical**: Consolidate into a single requirement and update all code references
2. **If requirements are different**: Assign a new unique SRS ID to one of the duplicate tags and update code comments

**Example Error Output:**
```
[ERROR] Duplicate SRS tag: SRS_MODULE_01_001
        First occurrence: module_a_requirements.md:45
        Duplicate found in: module_b_requirements.md:123

[VALIDATION FAILED]
Please manually resolve the duplicates by:
1. Assigning new unique SRS IDs to duplicate requirements
2. Or consolidating duplicate requirements if they are truly the same
```

### Unit Test Spec Tag Validation

**Script:** `scripts/validate_test_spec_tags.ps1`

**Purpose:** Ensures that all unit test functions (`TEST_FUNCTION`) in `*_ut.c` files are tagged with at least one SRS specification tag (`Tests_SRS_*`) in a comment immediately preceding the test function.

**Rationale:** Test functions should be linked to specific software requirements to:
- Maintain traceability between requirements and test coverage
- Ensure all requirements have corresponding tests
- Document what requirement each test is verifying
- Support automated requirement coverage analysis tools
- Identify orphan tests that don't verify any documented requirements

**Exclusions:**
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**File Types Checked:** Unit test files matching pattern `*_ut.c`

**Detection:** The script scans for `TEST_FUNCTION` declarations and verifies each has at least one `Tests_SRS_*` tag in the preceding comments:

**Correct Pattern:**
```c
/*Tests_SRS_MODULE_01_001: [ function shall return 0 on success. ]*/
TEST_FUNCTION(test_function_returns_0_on_success)
{
    // Test implementation
}

// Tests_SRS_MODULE_01_002: [ function shall fail if param is NULL. ]
TEST_FUNCTION(test_function_fails_when_param_is_null)
{
    // Test implementation
}

/*Tests_SRS_MODULE_01_003: [ First requirement. ]*/
/*Tests_SRS_MODULE_01_004: [ Second requirement. ]*/
TEST_FUNCTION(test_covering_multiple_requirements)
{
    // Test implementation
}
```

**Exemption Pattern:** Tests that intentionally do not require spec tags can be exempted:
```c
// Helper test or infrastructure test
TEST_FUNCTION(negative_tests) // no-srs
{
    // Test infrastructure that doesn't test specific requirements
}

TEST_FUNCTION(another_helper) /* no-srs */
{
    // Also exempted
}
```

**Fix Mode:** **This script does NOT auto-fix missing spec tags**, even when run with `-Fix` parameter:
- Determining which specification requirements a test covers requires human analysis
- The script will display an informational message and continue to report violations
- Exit code 1 is always returned when violations are found
- **Rationale**: Adding spec tags requires understanding what requirements each test verifies

**Manual Fix Required:**
When violations are found, resolve them by:
1. **Identify the requirement**: Determine which requirement in the devdoc the test is verifying
2. **Add the tag**: Add a `/*Tests_SRS_MODULE_XX_YYY: [ ... ]*/` comment before the `TEST_FUNCTION`
3. **Or exempt**: If the test is infrastructure/helper code, add `// no-srs` to the `TEST_FUNCTION` line

**Example Error Output:**
```
========================================
TEST FUNCTIONS MISSING SPEC TAGS
========================================

Each TEST_FUNCTION should be preceded by at least one Tests_SRS_* specification tag.
Example:
  /*Tests_SRS_MODULE_01_001: [ Description of requirement ]*/
  TEST_FUNCTION(test_name)

To exempt a test from this requirement, add '// no-srs' to the TEST_FUNCTION line:
  TEST_FUNCTION(test_name) // no-srs

  module_ut.c:45
    TEST_FUNCTION(test_missing_spec_tag)

[FAILED] 1 test function(s) are missing spec tags.
```

### AAA Comment Validation

**Script:** `scripts/validate_aaa_comments.ps1`

**Purpose:** Ensures that all test functions (`TEST_FUNCTION`, `TEST_METHOD`, `CTEST_FUNCTION`) in unit test (`*_ut.c`) files contain AAA (Arrange, Act, Assert) comments in the correct order.

**Note:** Integration test files (`*_int.c`) are **not** validated by this script. Integration tests often have more complex structures (setup/teardown across multiple functions, scenario-based testing, etc.) that don't fit the simple AAA pattern.

**Rationale:** The AAA pattern provides a clear structure for test functions:
- **Arrange**: Set up the test preconditions and inputs
- **Act**: Execute the code being tested
- **Assert**: Verify the expected outcomes

Using AAA comments consistently:
- Makes tests easier to read and understand
- Ensures tests follow a consistent structure
- Helps identify missing test setup or verification
- Provides clear documentation of test intent

**Exclusions:**
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**File Types Checked:** Unit test files (`*_ut.c`) only

**Test Function Macros Detected:** `TEST_FUNCTION`, `TEST_METHOD`, `CTEST_FUNCTION`

**Comment Styles Accepted:** All common C comment styles (case-insensitive):
- `// arrange`, `// act`, `// assert`
- `/// arrange`, `/// act`, `/// assert`
- `/* arrange */`, `/* act */`, `/* assert */`

**Order Requirement:** Comments must appear in the order: Arrange → Act → Assert

**Correct Pattern:**
```c
TEST_FUNCTION(test_function_succeeds)
{
    // arrange
    int input = 5;

    // act
    int result = double_value(input);

    // assert
    ASSERT_ARE_EQUAL(int, 10, result);
}

// With optional cleanup
TEST_FUNCTION(test_with_cleanup)
{
    // arrange
    int* ptr = malloc(sizeof(int));

    // act
    *ptr = 42;

    // assert
    ASSERT_ARE_EQUAL(int, 42, *ptr);

    // cleanup (optional, not validated)
    free(ptr);
}
```

**Helper Function Delegation:** AAA comments can be located in helper functions called by the test. The script checks functions defined in the same file:
```c
static void setup_test_data(int* value)
{
    // arrange
    *value = 42;
}

static void verify_result(int expected, int actual)
{
    // assert
    ASSERT_ARE_EQUAL(int, expected, actual);
}

TEST_FUNCTION(test_using_helpers)
{
    int value;
    setup_test_data(&value);

    // act
    int result = value * 2;

    verify_result(84, result);
}
```

**Exemption Pattern:** Tests that intentionally do not require AAA comments can be exempted:
```c
TEST_FUNCTION(infrastructure_test) // no-aaa
{
    // Test infrastructure that doesn't follow AAA pattern
}

TEST_FUNCTION(another_exempt_test) /* no-aaa */
{
    // Also exempted
}
```

**Fix Mode:** **This script does NOT auto-fix missing AAA comments**, even when run with `-Fix` parameter:
- Adding AAA comments requires understanding of the test logic
- The script will display an informational message that fix mode is not supported
- Exit code 1 is always returned when violations are found
- **Rationale**: AAA comments must be added by developers who understand the test structure

**Manual Fix Required:**
When violations are found, resolve them by:
1. **Add AAA comments**: Add `// arrange`, `// act`, and `// assert` comments to the test function in the correct order
2. **Or delegate to helpers**: Move test logic to helper functions that contain the AAA comments
3. **Or exempt**: If the test intentionally doesn't follow AAA pattern, add `// no-aaa` to the test function line

**Example Error Output:**
```
========================================
AAA Comment Validation
========================================
Repository Root: C:\repo

  [FAIL] tests/my_module_ut.c
         Line 45: TEST_FUNCTION(test_missing_aaa)
         Missing AAA comment(s): arrange, act, assert

  [FAIL] tests/my_module_ut.c
         Line 78: TEST_FUNCTION(test_wrong_order)
         AAA comments are not in correct order (should be: arrange, act, assert)

========================================
Validation Summary
========================================
Total test files checked: 5
Test functions with violations: 2

[VALIDATION FAILED]
```

## Adding New Validations

To add a new validation script:

1. Create a PowerShell script in the `scripts/` directory
2. The script **must** accept a `-RepoRoot` parameter (mandatory)
3. The script **should** accept an optional `-ExcludeFolders` parameter (comma-separated string, defaults to "deps,cmake")
4. The script **should** accept an optional `-Fix` switch parameter
5. Return exit code 0 for success, non-zero for failure
6. Follow the naming convention: `validate_*.ps1`

Example template:

```powershell
param(
    [Parameter(Mandatory=$true)]
    [string]$RepoRoot,
    
    [Parameter(Mandatory=$false)]
    [string]$ExcludeFolders = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$Fix
)

# Parse excluded directories (default: deps, cmake)
$excludeDirs = @()
if ($ExcludeFolders -eq "") {
    # Use defaults if not specified
    $excludeDirs = @("deps", "cmake")
}
else {
    $excludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

# Your validation logic here
Write-Host "Running validation..." -ForegroundColor White
Write-Host "Excluded directories: $($excludeDirs -join ', ')" -ForegroundColor White

# Check if file should be excluded
$relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
$isExcluded = $false
foreach ($excludeDir in $excludeDirs) {
    if ($relativePath -like "$excludeDir\*" -or $relativePath -like "$excludeDir/*") {
        $isExcluded = $true
        break
    }
}

if ($Fix) {
    Write-Host "Fix mode enabled, attempting to correct issues..."
    # Fix logic here - but only for non-excluded files
}

# Exit with appropriate code
if ($validationPassed) {
    Write-Host "[VALIDATION PASSED]" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "[VALIDATION FAILED]" -ForegroundColor Red
    exit 1
}
```

The CMake function will automatically discover and run all `.ps1` files in the `scripts/` directory.
When `fix_repo_validation_errors=ON`, the `-Fix` parameter is automatically passed to all scripts.

**Important:** Always exclude dependency directories to avoid modifying third-party code.

## Architecture

- **CMakeLists.txt**: Defines the `add_repo_validation()` CMake function
- **scripts/**: Contains PowerShell validation scripts
- Each script is executed with the repository root as a parameter
- Scripts run independently and report their own results
- The validation target fails if any script returns a non-zero exit code

## Integration with CI/CD

To include validation in your build pipeline:

```yaml
# Azure DevOps example - Validation only (fail on errors)
- task: CMake@1
  displayName: 'Configure with Repository Validation'
  inputs:
    cmakeArgs: '-S . -B build -Drun_repo_validation=ON'

- task: CMake@1
  displayName: 'Run Repository Validation'
  inputs:
    cmakeArgs: '--build build --target your_project_name_repo_validation'

# Azure DevOps example - Auto-fix mode (fix then check)
- task: CMake@1
  displayName: 'Configure with Auto-Fix Validation'
  inputs:
    cmakeArgs: '-S . -B build -Drun_repo_validation=ON -Dfix_repo_validation_errors=ON'

- task: CMake@1
  displayName: 'Run Repository Validation with Auto-Fix'
  inputs:
    cmakeArgs: '--build build --target your_project_name_repo_validation'
```

**Recommended CI/CD Strategy:**
- Use validation-only mode (without `-Fix`) in PR validation pipelines to catch issues
- Use auto-fix mode in scheduled maintenance builds or as part of automated cleanup tasks
- Always commit auto-fixed files back to the repository in fix mode

## Future Validations

Potential validations to add:
- Copyright header verification
- Code style consistency checks
- Documentation completeness
- Dependency version verification
- File naming convention checks
- Maximum file size limits

## Future Enhancements

- **Shared Helper Functions**: Refactor common functionality like SRS pattern matching, file exclusion logic, and boilerplate code into shared PowerShell helper modules to reduce duplication and improve maintainability across validation scripts.

## Testing Framework

The validation scripts include a comprehensive testing framework to ensure the validation logic works correctly and to prevent regressions.

### Running the Tests

To run validation tests:

```bash
# Configure CMake with testing enabled
cmake -S . -B build -Drun_unittests=ON

# Run individual test modules
cmake --build build --target test_validate_no_tabs
cmake --build build --target test_validate_file_endings
cmake --build build --target test_validate_srs_consistency
cmake --build build --target test_validate_requirements_naming
cmake --build build --target test_validate_enable_mocks
cmake --build build --target test_validate_aaa_comments

# Or use CTest to run all tests
cd build && ctest -C Debug
```

### Test Structure

The testing framework is organized under the `tests/` directory:

```
tests/
├── CMakeLists.txt                    # Main test coordination
├── validate_no_tabs/                 # Tab validation tests
│   ├── CMakeLists.txt
│   ├── has_tabs/                     # Files with tab characters
│   │   ├── sample.c
│   │   └── sample.h
│   └── no_tabs/                      # Files without tab characters  
│       ├── sample.c
│       └── sample.h
├── validate_file_endings/            # File ending tests
│   ├── CMakeLists.txt
│   ├── missing_crlf/                 # Files without proper endings
│   │   ├── sample.c
│   │   └── sample.h
│   └── proper_crlf/                  # Files with correct endings
│       ├── sample.c
│       └── sample.h
├── validate_srs_consistency/         # SRS consistency tests
│   ├── CMakeLists.txt
│   ├── consistent/                   # Matching SRS tags
│   │   ├── devdoc/
│   │   │   └── module_requirements.md
│   │   └── src/
│   │       └── module.c
│   └── inconsistent/                 # Mismatched SRS tags
│       ├── devdoc/
│       │   └── module_requirements.md
│       └── src/
│           └── module.c
├── validate_requirements_naming/     # Requirements naming tests
│   ├── CMakeLists.txt
│   ├── correct_naming/               # Properly named files
│   │   └── devdoc/
│   │       └── module_requirements.md
│   └── incorrect_naming/             # Improperly named files
│       └── devdoc/
│           └── module.md
└── validate_enable_mocks_pattern/    # ENABLE_MOCKS pattern tests
    ├── CMakeLists.txt
    ├── has_violations/               # Files with deprecated patterns
    │   ├── test_file.c
    │   ├── test_file.h
    │   └── multiple_patterns.cpp
    └── no_violations/                # Files with correct patterns
        ├── clean_file.c
        ├── clean_file.h
        └── multiple_correct.cpp
├── validate_aaa_comments/            # AAA comment validation tests
    ├── CMakeLists.txt
    ├── has_aaa/                      # Files with proper AAA comments
    │   ├── test_direct_aaa_ut.c
    │   ├── test_helper_aaa_ut.c
    │   ├── test_exempted_ut.c
    │   └── test_mixed_styles_ut.c
    └── missing_aaa/                  # Files missing AAA comments
        ├── test_missing_arrange_ut.c
        ├── test_missing_act_ut.c
        ├── test_missing_assert_ut.c
        ├── test_wrong_order_ut.c
        └── test_no_aaa_ut.c
```

### Test Types

Each validation script has three types of tests:

1. **Detection Tests**: Verify the script correctly identifies issues
   - Tests that violations are detected in problematic files
   - Tests that no issues are reported for compliant files

2. **Clean Tests**: Verify the script doesn't modify compliant files
   - Runs validation with `-Fix` on already-compliant files
   - Confirms no changes are made to correct files

3. **Fix Tests**: Verify the script correctly fixes issues
   - Runs validation with `-Fix` on files with violations
   - Confirms files are corrected and pass subsequent validation

### Test Implementation Details

Each test module includes:

- **Realistic test data**: Sample C/C# files, headers, and markdown documents that reflect actual project content
- **Positive test cases**: Files that should pass validation (no violations)
- **Negative test cases**: Files with deliberate violations to test detection
- **Fix mode verification**: Tests that verify auto-fix functionality works correctly
- **CMake integration**: Automated test execution with clear pass/fail reporting

### Adding Tests for New Validations

When adding a new validation script, create a corresponding test module:

1. Create a test directory: `tests/validate_your_feature/`
2. Add test data with positive and negative cases
3. Create `CMakeLists.txt` with detection, clean, and fix test targets
4. Follow the existing pattern for test structure and naming

Example test module structure:

```cmake
# tests/validate_your_feature/CMakeLists.txt

# Test that the script detects violations correctly
add_test(NAME test_validate_your_feature_detection
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File 
        "${PROJECT_SOURCE_DIR}/../scripts/validate_your_feature.ps1"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/negative_cases"
        -ExcludeFolders ""
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
)
set_tests_properties(test_validate_your_feature_detection PROPERTIES 
    WILL_FAIL TRUE  # Expect failure due to violations
)

# Test that the script doesn't modify compliant files
add_test(NAME test_validate_your_feature_clean
    COMMAND ${POWERSHELL_EXECUTABLE} -ExecutionPolicy Bypass -File 
        "${PROJECT_SOURCE_DIR}/../scripts/validate_your_feature.ps1"
        -RepoRoot "${CMAKE_CURRENT_SOURCE_DIR}/positive_cases"
        -ExcludeFolders ""
        -Fix
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
)
set_tests_properties(test_validate_your_feature_clean PROPERTIES 
    WILL_FAIL FALSE  # Expect success
)

# Test that the script fixes violations correctly
add_test(NAME test_validate_your_feature_fix
    COMMAND ${CMAKE_COMMAND} -P test_fix_validation.cmake
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
)
```

The testing framework ensures validation scripts are robust, reliable, and maintain consistent behavior across changes and updates.

