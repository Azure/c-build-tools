# Task Wrapper Templates

This folder contains wrapper templates for common Azure DevOps build tasks that use **native tools discovered by `discover_native_tools.yml`**.

## Problem

Azure DevOps built-in tasks (`CMake@1`, `MSBuild@1`, `VSBuild@1`, `VSTest@2`) rely on tools being in the system PATH or use their own discovery logic that may not work across all pool images and Visual Studio versions. This causes:
- **Missing tools on newer images**: Pool images with VS 2026 may not have cmake in PATH
- **Version-specific failures**: `VSTest@2` only supports VS [17.0, 18.0) and fails on VS 2026
- **Hardcoded paths**: Some templates hardcode VS installation paths that break on new versions

## Solution

These wrapper templates use `discover_native_tools.yml` to find the correct tool paths at runtime, then invoke them directly via PowerShell. This works consistently across all architectures (x64, x86, ARM64) and VS versions.

## Prerequisites

All wrappers require the `discover_native_tools.yml` template to be called first, which sets:
- `$(cmakePath)` - cmake.exe from the VS installation
- `$(ctestPath)` - ctest.exe from the VS installation
- `$(msbuildPath)` - MSBuild.exe (architecture-specific)
- `$(vstestPath)` - vstest.console.exe (architecture-specific)
- `$(cmakeGenerator)` - CMake generator string (e.g., "Visual Studio 18 2026")
- `$(cmakeArch)` - CMake architecture flag (x64, Win32, ARM64)
- `$(targetPlatform)` - MSBuild platform (x64, Win32, ARM64)

## Available Wrappers

| Wrapper | Original Task | Description |
|---------|---------------|-------------|
| `cmake.yml` | `CMake@1` | CMake project generation |
| `msbuild.yml` | `MSBuild@1` | MSBuild compilation |
| `vsbuild.yml` | `VSBuild@1` | Visual Studio build |
| `vstest.yml` | `VSTest@2`/`VSTest@3` | Test execution |
| `ctest.yml` | `CmdLine@2` (ctest) | CTest execution |

## Usage

### From another repository (consuming c-build-tools)

```yaml
resources:
  repositories:
    - repository: c_build_tools
      type: git
      name: MyProject/c-build-tools

steps:
  # First, discover native tools
  - template: discover_native_tools.yml@c_build_tools
    parameters:
      architecture: 'ARM64'

  # Then use wrappers instead of direct tasks
  - template: tasks/cmake.yml@c_build_tools
    parameters:
      architecture: 'ARM64'
      sourceDirectory: '$(Build.SourcesDirectory)'
      buildDirectory: '$(Build.BinariesDirectory)/build'
      cmakeArgs: '-DCMAKE_BUILD_TYPE=Release'

  - template: tasks/msbuild.yml@c_build_tools
    parameters:
      architecture: 'ARM64'
      solution: '$(Build.BinariesDirectory)/build/*.sln'
      configuration: 'Release'
```

### From within c-build-tools

```yaml
steps:
  - template: discover_native_tools.yml
    parameters:
      architecture: 'ARM64'

  - template: tasks/cmake.yml
    parameters:
      architecture: 'ARM64'
      sourceDirectory: '$(Build.SourcesDirectory)'
      buildDirectory: '$(Build.BinariesDirectory)/build'
```

## Migration Guide

### CMake@1 → tasks/cmake.yml

**Before:**
```yaml
- task: CMake@1
  inputs:
    workingDirectory: 'build'
    cmakeArgs: '-DCMAKE_BUILD_TYPE=Release'
```

**After:**
```yaml
- template: tasks/cmake.yml@c_build_tools
  parameters:
    architecture: '${{ parameters.ARCH_TYPE }}'
    sourceDirectory: '$(Build.SourcesDirectory)'
    buildDirectory: 'build'
    cmakeArgs: '-DCMAKE_BUILD_TYPE=Release'
```

### VSBuild@1 / MSBuild@1 → tasks/msbuild.yml

**Before:**
```yaml
- task: VSBuild@1
  inputs:
    solution: '**/*.sln'
    msbuildArgs: '/t:restore /t:build'
    platform: 'x64'
    configuration: 'Release'
```

**After:**
```yaml
- template: tasks/msbuild.yml@c_build_tools
  parameters:
    architecture: '${{ parameters.ARCH_TYPE }}'
    solution: '**/*.sln'
    msbuildArgs: '/t:restore /t:build'
    configuration: 'Release'
```

### VSTest@2 → tasks/vstest.yml

**Before:**
```yaml
- task: VSTest@2
  inputs:
    testAssemblyVer2: '**/*_ut_*.dll'
    platform: 'x64'
    configuration: 'Release'
```

**After:**
```yaml
- template: tasks/vstest.yml@c_build_tools
  parameters:
    architecture: '${{ parameters.ARCH_TYPE }}'
    testAssemblies: '**/*_ut_*.dll'
    configuration: 'Release'
```

## Notes

- All architectures use discovered native tool paths via PowerShell
- Tools are found inside the Visual Studio installation by `discover_native_tools.yml`
- No dependency on cmake, msbuild, or vstest being in the system PATH
- Code coverage via vstest uses `/collect:"Code Coverage"` in `otherConsoleOptions`
