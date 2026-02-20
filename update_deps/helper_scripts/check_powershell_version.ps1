# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Check PowerShell version and environment compatibility

function check-powershell-version
{
    Write-Host "Checking PowerShell environment..." -ForegroundColor Cyan

    $minMajor = 5
    $minMinor = 1

    $currentMajor = $PSVersionTable.PSVersion.Major
    $currentMinor = $PSVersionTable.PSVersion.Minor
    $currentVersion = "$currentMajor.$currentMinor"

    # Check version
    if ($currentMajor -lt $minMajor -or
        ($currentMajor -eq $minMajor -and $currentMinor -lt $minMinor))
    {
        Write-Host ""
        Write-Host "ERROR: PowerShell $minMajor.$minMinor or higher is required." -ForegroundColor Red
        Write-Host "Current version: $currentVersion" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please upgrade PowerShell:" -ForegroundColor Yellow
        Write-Host "  - Windows: Install Windows Management Framework 5.1 or PowerShell 7+" -ForegroundColor Yellow
        Write-Host "  - Download: https://aka.ms/powershell" -ForegroundColor Cyan
        Write-Host ""
        throw "PowerShell version $currentVersion is not supported. Minimum required: $minMajor.$minMinor"
    }

    # Check for PowerShell ISE (limited console support)
    if ($host.Name -eq 'Windows PowerShell ISE Host')
    {
        Write-Host ""
        Write-Host "WARNING: Running in PowerShell ISE." -ForegroundColor Yellow
        Write-Host "Some features (like animations) may not work properly." -ForegroundColor Yellow
        Write-Host "Consider using Windows Terminal or PowerShell console instead." -ForegroundColor Yellow
        Write-Host ""
    }

    Write-Host "PowerShell $currentVersion - OK" -ForegroundColor Green
}
