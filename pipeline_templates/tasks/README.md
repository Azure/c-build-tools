# Task Wrapper Templates

This folder contains wrapper templates for common Azure DevOps tasks that provide **transparent ARM64 native support**.

## Problem

On ARM64 1ES build pools, Azure DevOps agent and many built-in tasks run under x86 emulation (WoW64). This causes:
- **Performance degradation**: x86 emulated processes are significantly slower
- **Tool version mismatches**: Tasks may invoke x64/x86 tools instead of native ARM64 tools
- **Failures**: Some tasks (like VSTest@2) don't support ARM64 at all

## Solution

These wrapper templates:
1. **Detect the target architecture** at template expansion time
2. **x64/x86**: Pass through to the original Azure DevOps task (unchanged behavior)
3. **ARM64**: Use PowerShell to invoke native ARM64 tools directly, bypassing emulation

## Prerequisites

All wrappers require the `discover_native_tools.yml` template to be called first, which sets:
- `$(cmakePath)` - Native cmake.exe
- `$(ctestPath)` - Native ctest.exe
- `$(msbuildPath)` - Native MSBuild.exe
- `$(cmakeGenerator)` - CMake generator string (e.g., "Visual Studio 17 2022")
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

- Wrappers preserve all functionality of the original tasks for x64/x86 builds
- ARM64 paths use native tools discovered by `discover_native_tools.yml`
- Some features (like VSTest code coverage on ARM64) may have limitations until ADO tasks add native support
