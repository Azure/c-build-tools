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

Example running all tests:

```yaml
  steps:
  - template : pipeline_templates/run_ctests_with_appverifier.yml@c_build_tools
    parameters:
      repo_root: $(Build.SourcesDirectory)/deps/c-build-tools
      ctest_tests_bin_directory: $(Build.BinariesDirectory)\c
      steps:
       - task: CmdLine@1
         displayName: 'Run ctest'
         inputs:
           filename: '"C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\ctest.exe"'
           arguments: '-C "${{ parameters.test_configuration }}" -V --output-on-failure --no-tests=error -j $(NUMBER_OF_PROCESSORS)'
           workingFolder: $(Build.BinariesDirectory)\c
```

Example running Cuzz tests on my_test_1:

See [Cuzz](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/application-verifier-tests-within-application-verifier#cuzz)

```yaml
  steps:
  - template : pipeline_templates/run_ctests_with_appverifier.yml@c_build_tools
    parameters:
      repo_root: $(Build.SourcesDirectory)/deps/c-build-tools
      ctest_additional_args: '-R my_test_1'
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
