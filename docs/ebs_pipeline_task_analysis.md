# EBS Repository Pipeline Task Analysis

## Summary

This report analyzes all YAML pipeline files in the `d:\r_arm\ebs` repository to identify Azure DevOps tasks and their usage patterns, with a focus on tasks that would benefit from ARM64 native wrapping.

## YAML Files Found

### Main Pipeline Files
| File | Purpose |
|------|---------|
| `build/devops_gated.yml` | Main gated PR pipeline orchestration |
| `build/devops_gated_ll.yml` | Low-level gated pipeline with allocator variants |
| `build/devops_gated_passthrough.yml` | Passthrough allocator variant |
| `build/devops_gated_jemalloc.yml` | Jemalloc allocator variant |
| `build/devops_gated_docs.yml` | Documentation build pipeline |
| `build/onebranch_gated.yml` | OneBranch PR pipeline |
| `build/onebranch_daily.yml` | OneBranch daily official build |
| `build/inc_version_with_build_id.yml` | Version increment pipeline |
| `CodeQL.yml` | CodeQL path exclusion configuration |

### Gated Job Templates
| File | Purpose |
|------|---------|
| `build/gated_jobs/build_bs.yml` | Main build job for binaries |
| `build/gated_jobs/run_unit_tests.yml` | Unit test execution |
| `build/gated_jobs/run_int_tests_one_suite.yml` | Service Fabric integration tests (one at a time) |
| `build/gated_jobs/run_non_sf_int_tests_parallel.yml` | Non-SF integration tests (parallel execution) |
| `build/gated_jobs/run_non_sf_int_tests_one_by_one.yml` | Non-SF integration tests (sequential) |
| `build/gated_jobs/run_perf_tests_single_machine.yml` | Single-machine performance tests |
| `build/gated_jobs/run_perf_tests_multi_machine.yml` | Multi-machine performance tests |
| `build/gated_jobs/run_dot_net_tests.yml` | .NET test execution |
| `build/gated_jobs/run_upgrade.yml` | Service Fabric upgrade testing |
| `build/gated_jobs/run_upload_unload.yml` | SF upload/unload testing |
| `build/gated_jobs/run_endurance.yml` | Endurance testing |
| `build/gated_jobs/run_configure_metrics.yml` | Metrics configuration |
| `build/gated_jobs/iwyu_include_check.yml` | Include-what-you-use check |
| `build/gated_jobs/misc.yml` | Miscellaneous checks (VLD, backticks) |

### Daily Job Templates
| File | Purpose |
|------|---------|
| `build/daily_jobs/build_official_nuget.yml` | Official NuGet package build and signing |

### Shared Templates
| File | Purpose |
|------|---------|
| `build/templates/setup_job.yml` | Common job setup (VS vars, git clean, etc.) |
| `build/templates/build_native_solution.yml` | Native build steps |
| `build/templates/dump_config.yml` | Configuration dumping |
| `build/templates/inc_version_with_build_id.yml` | Version increment |
| `build/templates/init_storage_emulator.yml` | Azurite storage emulator setup |
| `build/templates/kill_storage_emulator.yml` | Azurite cleanup |
| `build/templates/setup_sf_runtime.yml` | Service Fabric runtime setup |
| `build/templates/create_cert.yml` | Certificate creation |
| `build/templates/remove_cert.yml` | Certificate removal |
| `build/templates/remove_sf_service.yml` | SF service removal |
| `build/templates/import_python_dependencies.yml` | Python dependency setup |
| `build/templates/run_traceability.yml` | Traceability tool execution |
| `build/templates/setup_safe_directories.yml` | Git safe directory setup |
| `build/templates/update_c_build_tools.yml` | Update c-build-tools dependency |
| `build/templates/update_manifest_and_upgrade.yml` | Manifest update and SF upgrade |
| `build/templates/upload_logs_on_fail.yml` | Log upload on failure |
| `build/templates/validate_nuget.yml` | NuGet package validation |

---

## Azure DevOps Tasks Analysis

### 🔴 HIGH PRIORITY - Build/Compilation Tasks (ARM64 Native Critical)

#### **CmdLine@2** (CMake/CTest Execution)
**Used in:** `build_bs.yml`, `run_unit_tests.yml`, `run_non_sf_int_tests_parallel.yml`, `run_int_tests_one_suite.yml`, `build_native_solution.yml`, `build_official_nuget.yml`, `validate_nuget.yml`, `run_upgrade.yml`, `misc.yml`, `setup_job.yml`

**Usage Pattern:**
```yaml
- task: CmdLine@2
  displayName: 'CMake ...'
  inputs:
    script: 'cmake.exe $(Build.SourcesDirectory) -G "Visual Studio 17 2022" -A x64 ...'
    workingDirectory: '$(Build.BinariesDirectory)\c'
```

**Common parameters:**
- `script`: Command to execute
- `workingDirectory`: Working directory for command
- `failOnStderr`: (implicit) - Not commonly set

**Notes for ARM64:**
- Currently hardcoded to `-A x64` architecture
- Would need `-A ARM64` for ARM64 native builds
- CMake generator always uses `"Visual Studio 17 2022"`
- All CMake invocations use absolute paths from VS 2022 location

---

#### **VSBuild@1**
**Used in:** `build_bs.yml`, `run_unit_tests.yml`, `build_native_solution.yml`, `validate_nuget.yml`

**Usage Pattern:**
```yaml
- task: VSBuild@1
  displayName: 'Build solution $(Build.BinariesDirectory)\*.sln'
  inputs:
    solution: '$(Build.BinariesDirectory)\c\*.sln'
    vsVersion: "17.0"
    msbuildArgs: '/t:build'
    platform: x64
    configuration: ${{ parameters.build_configuration }}
    clean: false
    maximumCpuCount: true
```

**Common parameters:**
- `solution`: Solution file path
- `vsVersion`: `"17.0"` (VS 2022)
- `msbuildArgs`: `/t:build`
- `platform`: **Always `x64`** ⚠️
- `configuration`: `Debug`, `RelWithDebInfo`
- `clean`: `true`/`false`
- `maximumCpuCount`: `true`

**Notes for ARM64:**
- Platform is hardcoded to `x64`
- Would need `ARM64` platform support
- Currently no ARM64 build configuration

---

#### **MSBuild@1**
**Used in:** `build_official_nuget.yml`

**Usage Pattern:**
```yaml
- task: MSBuild@1
  displayName: 'Build ebs.sln'
  inputs:
    solution: '$(Build.SourcesDirectory)\build\ebs.sln'
    msbuildLocationMethod: 'location'
    msbuildLocation: 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe'
    platform: 'x64'
    configuration: 'RelWithDebInfo'
    msbuildArguments: '/v:n /nr:false /flp1:Verbosity=d;...'
    clean: true
    maximumCpuCount: true
    logProjectEvents: true
```

**Notes for ARM64:**
- Uses explicit MSBuild location (may need ARM64 MSBuild path)
- Platform is hardcoded to `x64`

---

### 🟠 MEDIUM PRIORITY - Testing Tasks (ARM64 Native Important)

#### **VSTest@2**
**Used in:** `run_unit_tests.yml`, `run_dot_net_tests.yml`

**Usage Pattern:**
```yaml
- task: VSTest@2
  displayName: 'VsTest - testAssemblies'
  inputs:
    testAssemblyVer2: |
      $(Build.BinariesDirectory)\${{ parameters.test_configuration }}\**\*_ut_*.dll
    runInParallel: true
    runTestsInIsolation: true
    codeCoverageEnabled: false
    otherConsoleOptions: '-- RunConfiguration.ExecutionThreadApartmentState=MTA'
  env:
    BLOCK_STORAGE_BLOB_CONNECTION_STRING: $(BLOCK_STORAGE_BLOB_CONNECTION_STRING)
```

**Common parameters:**
- `testAssemblyVer2`: Test DLL patterns
- `runInParallel`: `true`
- `runTestsInIsolation`: `true`
- `codeCoverageEnabled`: `false`
- `otherConsoleOptions`: `/Platform:x64`, MTA settings
- `rerunFailedTests`: `false`
- `failOnMinTestsNotRun`: `true`
- `testFilterCriteria`: Class name filters

**Notes for ARM64:**
- Uses `/Platform:x64` in `otherConsoleOptions`
- Would need `/Platform:ARM64` for ARM64 test runs

---

#### **CTest Execution via CmdLine@2**
**Pattern:**
```yaml
- task: CmdLine@2
  displayName: 'Run ctest'
  inputs:
    script: '"C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\ctest.exe" -C "${{ parameters.test_configuration }}" -V --output-on-failure --no-tests=error -j $(NUMBER_OF_PROCESSORS)'
    workingDirectory: $(Build.BinariesDirectory)\c
```

**Notes for ARM64:**
- Uses VS 2022's bundled CMake
- Architecture is implicit from build configuration

---

### 🟡 LOWER PRIORITY - Utility Tasks

#### **BatchScript@1**
**Used in:** `build_bs.yml`, `run_int_tests_one_suite.yml`, `run_upgrade.yml`, `misc.yml`, `setup_job.yml`, `run_traceability.yml`

**Usage Pattern:**
```yaml
- task: BatchScript@1
  displayName: 'Git checkout'
  inputs:
    filename: 'C:\Program Files\Git\bin\git.exe'
    arguments: "checkout -f ${{ parameters.build_sourceversion }}"
```

Also used for VS vars setup:
```yaml
- task: BatchScript@1
  displayName: 'Setup VS Vars for 64 bit'
  inputs:
    filename: '"c:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat"'
    arguments: 'x64'
    modifyEnvironment: true
```

**Notes for ARM64:**
- `vcvarsall.bat` would need `arm64` argument instead of `x64`
- `vcvars64.bat` specifically targets x64 - would need `vcvarsarm64.bat`

---

#### **PowerShell@2**
**Used in:** Almost all templates

**Usage Pattern:**
```yaml
- task: PowerShell@2
  displayName: 'Create folder for cmake'
  inputs:
    targetType: 'inline'
    script: 'New-Item -ItemType Directory -Force -Path "$(Build.BinariesDirectory)\c"'
```

Also for file execution:
```yaml
- task: PowerShell@2
  displayName: 'PowerShell Script - Run tests'
  inputs:
    targetType: filePath
    filePath: './test_scripts/run_block_store_single_machine_perf_tests.ps1'
    arguments: '-instanceId $(Build.BuildId)_$(System.JobAttempt)'
```

**Notes for ARM64:**
- Generally architecture-agnostic
- May need review for any hardcoded x64 paths

---

### 🟢 Package Management Tasks

#### **DotNetCoreCLI@2** (NuGet Restore)
**Used in:** `build_bs.yml`, `run_unit_tests.yml`, `build_native_solution.yml`, `build_official_nuget.yml`

**Usage Pattern:**
```yaml
- task: DotNetCoreCLI@2
  displayName: 'NuGet restore'
  inputs:
    command: 'restore'
    projects: '$(Build.BinariesDirectory)\c\*.sln'
    feedsToUse: 'config'
    nugetConfigPath: '$(Build.SourcesDirectory)/nuget.config'
    noCache: true
```

**Notes for ARM64:**
- Generally architecture-agnostic for restore operations

---

#### **NuGetCommand@2**
**Used in:** `build_official_nuget.yml`, `validate_nuget.yml`

**Usage Pattern:**
```yaml
- task: NuGetCommand@2
  displayName: 'NuGet pack'
  inputs:
    command: pack
    packagesToPack: '$(Build.BinariesDirectory)/RelWithDebInfo/.../Azure.Messaging.BlockStorageClient_NetFx.nuspec'
    configuration: RelWithDebInfo
    packDestination: '$(Build.BinariesDirectory)/packages'
    versioningScheme: byEnvVar
    versionEnvVar: BSNugetPackageVersion
```

---

### 🔵 Artifact Management Tasks

#### **PublishPipelineArtifact@1**
**Used in:** `build_bs.yml`, `run_unit_tests.yml`, `build_official_nuget.yml`, `upload_logs_on_fail.yml`

**Usage Pattern:**
```yaml
- task: PublishPipelineArtifact@1
  displayName: 'Publish Artifacts'
  inputs:
    targetPath: '$(Build.BinariesDirectory)/${{ parameters.build_configuration }}'
    artifactName: '${{ parameters.name }}${{ parameters.BUILD_SUFFIX}}'
    parallel: true
```

---

#### **DownloadPipelineArtifact@2**
**Used in:** `run_int_tests_one_suite.yml`, `run_perf_tests_single_machine.yml`, `run_non_sf_int_tests_parallel.yml`, `run_dot_net_tests.yml`, `run_upgrade.yml`

**Usage Pattern:**
```yaml
- task: DownloadPipelineArtifact@2
  displayName: 'Download binaries'
  inputs:
    buildType: current
    artifactName: ${{ parameters.test_configuration }}${{ parameters.BUILD_SUFFIX }}
    downloadPath: '$(Build.BinariesDirectory)/${{ parameters.test_configuration }}'
    itemPattern: |
      **
```

---

#### **PublishBuildArtifacts@1**
**Used in:** `upload_logs_on_fail.yml`

---

#### **PublishSymbols@2**
**Used in:** `build_bs.yml`

**Usage Pattern:**
```yaml
- task: PublishSymbols@2
  displayName: 'Publish symbols'
  inputs:
    SymbolsFolder: '$(Build.BinariesDirectory)'
    IndexSources: false
    SearchPattern: |
      **/*.pdb
      !**/vc143.pdb
    symbolServerType: 'TeamServices'
```

---

### Other Utility Tasks

#### **DeleteFiles@1**
**Used in:** `setup_job.yml`, `run_unit_tests.yml`, and many others

#### **CopyFiles@2**
**Used in:** `upload_logs_on_fail.yml`, `validate_nuget.yml`, `run_upgrade.yml`

#### **UseDotNet@2**
**Used in:** `run_dot_net_tests.yml`, `build_official_nuget.yml`, `run_upgrade.yml`

#### **ComponentGovernanceComponentDetection@0**
**Used in:** `misc.yml`

---

## ARM64 Migration Recommendations

### Critical Changes Required

1. **CMake Configuration**
   - Replace `-A x64` with `-A ARM64` or parameterize
   - Example: `-A ${{ parameters.ARCH }}`

2. **VSBuild Platform**
   - Change `platform: x64` to `platform: ARM64` or parameterize
   - Example: `platform: ${{ parameters.PLATFORM }}`

3. **MSBuild Platform**
   - Same as VSBuild - parameterize platform

4. **vcvarsall.bat Arguments**
   - Change `x64` argument to `arm64`
   - Or use `vcvarsarm64.bat` instead of `vcvars64.bat`

5. **VSTest Platform**
   - Change `/Platform:x64` to `/Platform:ARM64`

### Suggested Parameterization

Add architecture parameters to pipeline files:
```yaml
parameters:
  - name: ARCH_TYPE_VALUES
    type: object
    default: ["x64", "ARM64"]
```

Update CMake invocations:
```yaml
- task: CmdLine@2
  displayName: 'CMake'
  inputs:
    script: 'cmake.exe $(Build.SourcesDirectory) -G "Visual Studio 17 2022" -A ${{ parameters.ARCH }} ...'
```

### Tasks Requiring ARM64 Native Tools

| Task | ARM64 Requirement |
|------|-------------------|
| `CmdLine@2` (cmake.exe) | ARM64 CMake binary |
| `CmdLine@2` (ctest.exe) | ARM64 CTest binary |
| `VSBuild@1` | ARM64 MSBuild and platform support |
| `MSBuild@1` | ARM64 MSBuild path |
| `VSTest@2` | ARM64 VSTest adapter |
| `BatchScript@1` (vcvarsall.bat) | ARM64 VS developer command prompt |

---

## Appendix: Template Reference from c-build-tools

The EBS repository uses templates from `c_build_tools`:
- `pipeline_templates/run_ctests_with_appverifier.yml`
- `pipeline_templates/start_logman.yml`
- `pipeline_templates/stop_logman.yml`
- `pipeline_templates/disable_appverifier.yml`
- `pipeline_templates/setup_nuget_tools.yml`
- `pipeline_templates/dump_drive_usage_on_failure.yml`
- `pipeline_templates/clean_ado_folders.yml`
- `pipeline_templates/run_master_check.yml`
- `pipeline_templates/codeql3000_init.yml`
- `pipeline_templates/codeql3000_finalize.yml`

These templates may also need ARM64 updates.
