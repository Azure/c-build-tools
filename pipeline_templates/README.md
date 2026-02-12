# Pipeline Templates

## Overview

This folder contains pipeline yml templates for devops pipelines.

## Templates

- start_logman.yml
  - Starts the logman tracing on the machine.
  - By default includes only the provider `DAD29F36-0A48-4DEF-9D50-8EF9036B92B4`, but this may be overridden by a providers.txt file specified in parameter `providers_file`.
  - Requires the path to this repository root.
- stop_logman.yml
  - Stops the logmane tracing on the machine.
  - If the job was canceled or failed then these ETL logs are published as artifacts.
  - Requires the path to this repository root.
- dump_drive_usage_on_failure.yml
  - For a given drive (default c), dump the largest directories/files recursively when they are at least a certain size (1GB by default) and down to a certain depth (6 by default).
  - Run only when the job failed.
- tttracer_start.yml
  - Starts tttracer for a given process to collect time-travel traces.
- tttracer_stop.yml
  - Stops tttraces for the process to stop collecting time-travel traces. Then publishes the trace and reboots the machine.
- run_ctests_with_appverifier.yml
  - Runs tests under ctest with app verifier enabled
- disable_appverifier.yml
  - Only the cleanup portion of run_ctests_with_appverifier.yml, which may be used for a cleanup step during setup
- codeql3000_init.yml
  - Initializes CodeQL3000 and disables strong name verification (needed for running Sarif results checker).
- codeql3000_finalize.yml
  - Finalize portion of CodeQL3000 (build steps should be between the `codeql3000_init` and `codeql3000_finalize` wrappers).
  - It runs Sarif results checker to verify that there are no errors and fails the build
  - Runs SarifBob to pretty print all the errors in the Sarif in case of failures.
- run_with_crash_reports.yml
  - Wraps a test script with Linux crash report collection (enable, run with ulimit, collect, publish, disable).
  - Automatically injects `ulimit -c unlimited` before running the test script.
  - Test step display names get the suffix `[crash reports enabled]`.
- enable_linux_crash_reports.yml
  - Sets `kernel.core_pattern` to write core files to the crash reports directory.
  - Creates the crash reports output directory.
  - Run this BEFORE tests to ensure core dumps are captured.
- collect_linux_crash_reports.yml
  - Collects crash reports from the crash reports directory, `/var/crash` (Ubuntu apport system), and core files from the build directory.
  - Publishes collected crash reports as build artifacts on failure (uses `condition: failed()`).
- disable_linux_crash_reports.yml
  - Restores default `kernel.core_pattern`.
  - Run this AFTER collecting crash reports to clean up system-level changes.

## How to Consume

In order to use these templates in another repository, you must add this resource to the yaml:

```yaml
resources:
  repositories:
    - repository: c_build_tools
      type: github
      name: azure/c-build-tools
      endpoint: github.com_azure
      ref: refs/heads/master
    - repository: self
      clean: true
```

Note that `c_build_tools` is the name given above and will be used in this guide, but any name may be specified.

Note that `github.com_azure` must be a "Service Connection" in the devops project settings, see [Create a Service Connection](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints?view=azure-devops&tabs=yaml#create-a-service-connection).
This one has been created in the `msazure` project.

Templates from this project may then be used in the yaml files by specifying the repo name like:

```yaml
  - template : pipeline_templates/stop_logman.yml@c_build_tools
```

Note again that `c_build_tools` is the name we specified above.

## Dependencies

In case a template requires external files or scripts, the consuming repo has two options:

1. Use a submodule of c-build-tools and specify that path
2. Checkout the c-build-tools repo in the yaml and specify the path as `$(Build.SourcesDirectory)/repo_name`

The second option requires the following snippet near where the `checkout: self` line is:

```yaml
  steps:
  - checkout: c_build_tools
```

Note that in this case the variable `$(Build.SourcesDirectory)` will not point to the "self" repository code anymore so this option may not be ideal.
See [Predefined Variables](https://learn.microsoft.com/en-us/azure/devops/pipelines/build/variables?view=azure-devops&tabs=yaml) for notes.

## Specific Template Notes

### run_ctests_with_appverifier.yml

This template does 3 things:
1. Enable Application Verifier for all tests found by running `ctest -N`
2. Run any steps in the specified steps list (name will say "[appverifier enabled]")
3. Disable Application Verifier for everything

Example running all tests (where the test binaries are named test_name_exe_ebs.exe):

```yaml
  steps:
  - template : pipeline_templates/run_ctests_with_appverifier.yml@c_build_tools
    parameters:
      repo_root: $(Build.SourcesDirectory)/deps/c-build-tools
      binary_name_suffix: "_exe_ebs.exe"
      ctest_tests_bin_directory: $(Build.BinariesDirectory)\c
      steps:
       - task: CmdLine@1
         displayName: 'Run ctest'
         inputs:
           filename: '"C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\ctest.exe"'
           arguments: '-C "${{ parameters.test_configuration }}" -V --output-on-failure --no-tests=error -j $(NUMBER_OF_PROCESSORS)'
           workingFolder: $(Build.BinariesDirectory)\c
```

Example running Cuzz tests on my_test_1.exe:

See [Cuzz](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/application-verifier-tests-within-application-verifier#cuzz)

```yaml
  steps:
  - template : pipeline_templates/run_ctests_with_appverifier.yml@c_build_tools
    parameters:
      repo_root: $(Build.SourcesDirectory)/deps/c-build-tools
      ctest_additional_args: '-R my_test_1'
      binary_name_suffix: ".exe"
      app_verifier_enable: 'cuzz'
      appVerifierAdditionalProperties: 'FuzzingLevel=4 RandomSeed=0'
      ctest_tests_bin_directory: $(Build.BinariesDirectory)\c
      steps:
       - task: CmdLine@1
         displayName: 'Run ctest'
         inputs:
           filename: '"C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\ctest.exe"'
           arguments: '-C "${{ parameters.test_configuration }}" -R my_test_1 -V --output-on-failure --no-tests=error -j $(NUMBER_OF_PROCESSORS)'
           workingFolder: $(Build.BinariesDirectory)\c
```

### run_with_crash_reports.yml

This template wraps a test script with Linux crash report collection:
1. Enable crash reports (`kernel.core_pattern` + directory setup)
2. Run the test script with `ulimit -c unlimited` automatically injected (name will say "[crash reports enabled]")
3. Collect core files from the crash reports directory and build directory
4. Publish crash reports as artifacts (only on failure/cancel)
5. Restore default `kernel.core_pattern`

The template automatically injects `ulimit -c unlimited` before your test script, so you don't need to manage it yourself.

Example usage:

```yaml
  steps:
  - template: pipeline_templates/run_with_crash_reports.yml@c_build_tools
    parameters:
      build_directory: $(Build.Repository.LocalPath)/cmake_linux
      test_script: |
        ./build/linux/build_linux.sh $(Build.Repository.LocalPath)
      test_displayName: 'Build and run tests'
      test_workingDirectory: '$(Build.Repository.LocalPath)'
```

Parameters:
- `crash_reports_directory`: Directory to store crash reports (default: `$(Build.ArtifactStagingDirectory)/crash_reports`)
- `build_directory`: Directory to search for core files (default: `$(Build.SourcesDirectory)`)
- `search_depth`: How deep to search for core files (default: 4)
- `artifact_name`: Name for the published artifact (default: `Linux_crash_reports`)
- `test_script`: The test script to run (required, string)
- `test_displayName`: Display name for the test step (default: `Run tests`)
- `test_workingDirectory`: Working directory for the test script (default: `$(Build.SourcesDirectory)`)

### Linux crash report templates (standalone)

Three standalone templates work together to capture Linux crash dumps in CI pipelines for consumers who need custom flows:
- `enable_linux_crash_reports.yml` - sets `kernel.core_pattern` to write core files to the crash reports directory
- `collect_linux_crash_reports.yml` - collects core files and publishes as artifacts
- `disable_linux_crash_reports.yml` - restores default core dump settings

The enable template sets `kernel.core_pattern` (a system-level kernel setting) so core dumps are written to a known directory. The disable template restores the default `core_pattern` afterward.

**Important**: `ulimit -c unlimited` must be run in the **same shell/step** that executes the tests. `ulimit` is per-process and does not persist across pipeline steps. The enable template only sets `core_pattern` (which tells the kernel *where* to write core files); `ulimit` controls *whether* core files are written at all.

Example usage in a Linux job:

```yaml
  steps:
  # Enable core dumps before running tests
  - template: pipeline_templates/enable_linux_crash_reports.yml@c_build_tools
    parameters:
      crash_reports_directory: $(Build.ArtifactStagingDirectory)/crash_reports

  # Run tests (ulimit -c unlimited must be in the same shell that runs tests)
  - bash: |
      ulimit -c unlimited
      ctest -j $(nproc) --output-on-failure
    displayName: 'Run tests'
    workingDirectory: $(Build.SourcesDirectory)/cmake_linux

  # Collect and publish crash reports
  - template: pipeline_templates/collect_linux_crash_reports.yml@c_build_tools
    parameters:
      crash_reports_directory: $(Build.ArtifactStagingDirectory)/crash_reports
      build_directory: $(Build.SourcesDirectory)/cmake_linux
      search_depth: 4
      artifact_name: Linux_crash_reports

  # Restore default core dump settings
  - template: pipeline_templates/disable_linux_crash_reports.yml@c_build_tools
```

Parameters for `enable_linux_crash_reports.yml`:
- `crash_reports_directory`: Directory to store crash reports (default: `$(Build.ArtifactStagingDirectory)/crash_reports`)

Parameters for `collect_linux_crash_reports.yml`:
- `crash_reports_directory`: Directory where crash reports are stored (default: `$(Build.ArtifactStagingDirectory)/crash_reports`)
- `build_directory`: Directory to search for core files (default: `$(Build.SourcesDirectory)`)
- `search_depth`: How deep to search for core files (default: 4)
- `artifact_name`: Name for the published artifact (default: `Linux_crash_reports`)

`disable_linux_crash_reports.yml` has no parameters.
