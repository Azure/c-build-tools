# tttracer in azure pipelines

Sometimes it is **impossible** to get a local repro for a build failure in the gate. 

The solution is to (hopefully) record a trace of the failing test in the gate using tttracer and then downloading that trace (and the binaries) for further analysis locally.

There are 2 templates provided: `tttracer_start.yml` and `tttracer_stop.yml`. They should be used in pairs.

Typical usage 
1) insert `tttracer_start.yml` before the execution of the test
2) insert `tttracer_stop.yml` after the execution of the test

Note: `tttracer_stop.yml` will reboot the build machine.

Here's an example:

```yml
  - template: templates/tttracer_start.yml
    parameters: 
      tttracer_target: cert_alt_name_entry_helper_ut_exe_zrpc.exe

  - task: CmdLine@1
    displayName: 'Run ctest'
    inputs:
      filename: ctest
      arguments: '-C "Debug" -V --output-on-failure'
      workingFolder: 'build_x86'

  - template: templates/tttracer_stop.yml
```

In the above example we are interested in getting a trace for the test `cert_alt_name_entry_helper_ut_exe_zrpc.exe process`.

Here's another example, where `testhost.x86.exe` is recorded:

![record_testhoist.x86](./record_testhost.x86.exe.jpg)

Note: VsTest tasks require recording of the host process, that is, either `testhost.exe` (for x64) or `testhost.x86.exe` (for x32).


The pipeline will indicate that the templates are active by showing a list of tasks preceeded by [tttracer], like in the picture below:

![templates](./active_templates.jpg)

The recorded trace and the symbols can be then found after the complete pipeline has run under "Artifacts":

![download](./artifacts.jpg)

Here's a typical content of the artifacts container:

![artifacts](./artifacts2.jpg)



