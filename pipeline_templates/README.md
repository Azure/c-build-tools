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

The second step requires the following snippet near where the `checkout: self` line is:

```yaml
  steps:
  - checkout: c_build_tools
```

