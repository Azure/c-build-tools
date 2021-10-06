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
  - template: deps\c-build-tools\build\templates\real_check_template.yml
    parameters:
      lib: '{PATH_TO_LIB}'
      reals_lib: '{PATH_TO_REALS_LIB}'
```
