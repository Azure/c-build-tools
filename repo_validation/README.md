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

**Base exclusions**: The following directories are always excluded regardless of `EXCLUDE_FOLDERS`:
- `.git` - Git metadata
- `dependencies` - Alternative dependency directory name
- `build` - Build artifacts

This approach ensures that:
- Critical directories like `.git` are always protected
- Common dependency patterns are excluded by default
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
- Base exclusions (always excluded): `.git`, `dependencies`, `build`
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
- Base exclusions (always excluded): `.git`, `dependencies`, `build`
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

## Adding New Validations

To add a new validation script:

1. Create a PowerShell script in the `scripts/` directory
2. The script **must** accept a `-RepoRoot` parameter (mandatory)
3. The script **should** accept an optional `-ExcludeFolders` parameter (comma-separated string)
4. The script **should** accept an optional `-Fix` switch parameter
5. **Must exclude dependency directories** from scanning and modification
6. Return exit code 0 for success, non-zero for failure
7. Follow the naming convention: `validate_*.ps1`

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

# Base excluded directories (always excluded)
$baseExcludeDirs = @("deps", "dependencies", ".git", "cmake", "build")

# Parse and add custom excluded directories
$customExcludeDirs = @()
if ($ExcludeFolders -ne "") {
    $customExcludeDirs = $ExcludeFolders -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

# Combine base and custom exclusions
$excludeDirs = $baseExcludeDirs + $customExcludeDirs

# Your validation logic here
Write-Host "Running validation..."
Write-Host "Excluded directories: $($excludeDirs -join ', ')"

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
