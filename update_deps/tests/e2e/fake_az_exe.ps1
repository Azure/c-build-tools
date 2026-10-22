# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Tripwire for the interactive end-to-end tests: the runner puts an az.exe shim first on PATH, which runs
# this script. The propagation scripts must reach the Azure CLI through the az command, which the
# global:az function of fake_az.ps1 serves; running an az executable directly (cmd /c az,
# Start-Process, a .NET process) would bypass the fake and reach the real Azure DevOps.
param([string] $ArgsFile)

. (Join-Path $PSScriptRoot 'fake_services.ps1')
$fake_argv = @(Get-Content -LiteralPath $ArgsFile | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Substring(2))) })
add-fake-event @{ kind = 'az.unexpected'; reason = 'an az executable was run instead of the az command'; args = $fake_argv; cwd = (Get-Location).ProviderPath }
[Console]::Error.WriteLine('fake az.exe: the end-to-end tests only serve the az command (fake_az.ps1)')
exit 1
