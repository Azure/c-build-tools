#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

$reals_check = $args[0]
$build_dir = $args[1]
$config = $args[2]

.$reals_check $build_dir/reals_check/test/$config/reals_check_test.lib
if($LASTEXITCODE -ne 0){
    Write-Error "reals_check.ps1 returns non-zero exit code for correct lib with only original symbols."
    exit 1
}

.$reals_check $build_dir/reals_check/test/reals/$config/reals_check_test_reals.lib 
if($LASTEXITCODE -ne 0){
    Write-Error "reals_check.ps1 returns non-zero exit code for correct lib with only real symbols."
    exit 1
}

.$reals_check $build_dir/reals_check/test/both/$config/reals_check_test_both_int_lib.lib
if($LASTEXITCODE -ne 1){
    Write-Error "reals_check.ps1 does not return exit code 1 for lib with original and real symbols."
    exit 1
}

exit 0
