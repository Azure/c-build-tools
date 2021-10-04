#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

$real_check = $args[0]
$build_dir = $args[1]
$config = $args[2]

.$real_check $build_dir\real_check\test\$config\real_check_test.lib
if($LASTEXITCODE -ne 0){
    Write-Error "real_check.ps1 returns non-zero exit code for correct lib with only original symbols."
    exit 1
}

.$real_check $build_dir\real_check\test\reals\$config\real_check_test_reals.lib 
if($LASTEXITCODE -ne 0){
    Write-Error "real_check.ps1 returns non-zero exit code for correct lib with only real symbols."
    exit 1
}

.$real_check $build_dir\real_check\test\both\$config\real_check_test_both.lib
if($LASTEXITCODE -ne 1){
    Write-Error "real_check.ps1 does not return exit code 1 for lib with original and real symbols."
    exit 1
}

exit 0