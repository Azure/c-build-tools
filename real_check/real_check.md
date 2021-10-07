# real_check 

This tool checks if a given library contains a pair of symbols of the form `[symbol]` and `real_[symbol]`. 

If the given library contains no such pair, the tool returns exit code `0`.
If the given library contains such a pair, the tool prints these symbols to stderror and returns exit code `1`.
If the tool is unable to determine if the library contains such a pair, it returns exit code `2`.


## Usage

```
PS> real_check.ps1 [lib_to_check]
```

## Devops

To add real check to the devops pipeline, add the following step to the `.yml` file and replace `PATH_TO_LIB` and `PATH_TO_REALS_LIB` with appropriate values:

```
  - template: build\templates\real_check.yml@c-build-tools
    parameters:
      lib: '{PATH_TO_LIB}'
      reals_lib: '{PATH_TO_REALS_LIB}'
```

The `resources` segment of the `.yml` file should look like this:

```
resources:
  repositories:
    - repository: self
      clean: true

    - repository: c-build-tools
      type: github
      name: Azure/c-build-tools
      endpoint: "MessagingStore GitHub connection"
```
