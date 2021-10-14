# reals check 

This tool checks if the given libraries contain a pair of symbols of the form `[symbol]` and `real_[symbol]`. 

If the given libraries contain no such pair, the tool returns exit code `0`.
If the given libraries contain such a pair, the tool prints these symbols to stderror and returns exit code `1`.
If the tool is unable to determine if the libraries contain such a pair, it returns exit code `2`.


## Usage

```
PS> reals_check.ps1 lib1 lib2 ...
```

## Adding to CMake

To add reals check to a project, add the following snippet to the root `CMakelists.txt` of the project:

```
if(${run_reals_check})
    add_reals_check_target([base_name])
endif()
```

Replace `\[base_name\]` with the name of the project. CMake will then create a target `\[base_name\]_reals_check`.