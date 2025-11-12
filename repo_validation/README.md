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

# Enable validation AND auto-fix
cmake -S . -B build -Drun_repo_validation=ON -Dfix_repo_validation_errors=ON
```

### Running Validation

To run all validation checks:

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

**Script:** `scripts/validate_crlf_line_endings.ps1`

**Purpose:** Ensures all source code files (`.h`, `.hpp`, `.c`, `.cpp`, `.cs`) end with a newline character (CRLF on Windows).

**Exclusions:** 
- Default exclusions (if not customized): `deps`, `cmake`
- Custom exclusions can be specified via `EXCLUDE_FOLDERS` parameter in `add_repo_validation()`

**Rationale:** Source files must end with a newline to comply with:
- C/C++ language standards (files should end with a newline)
- Compiler warnings and requirements
- Git and version control best practices
- Consistent file formatting across the codebase

**Fix Mode:** When run with `-Fix` parameter, the script automatically corrects files:
- Adds CRLF to files that end abruptly without any newline
- Converts LF-only endings to CRLF (Windows standard)
- Converts CR-only endings to CRLF
- **Does not modify any files in excluded directories**

**Manual Fix Options:**
- In Visual Studio: Ensure the cursor can move one line past the last line of code
- In VS Code: Add a final newline at the end of the file
- Configure `.editorconfig` with `insert_final_newline = true`

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
