# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
Watch the status of multiple GitHub and Azure DevOps PRs in a live-updating dashboard.

.DESCRIPTION
Polls PR status every 30 seconds and displays a color-coded summary for each PR.
Supports both GitHub PRs (via gh CLI) and Azure DevOps PRs (via az CLI).

Colors:
  Green   - All checks passed
  Yellow  - Checks still running
  Red     - One or more checks failed
  Magenta - PR merged/completed
  Gray    - PR closed/abandoned or fetch error

.PARAMETER PRs
Comma-separated list of PR URLs. Supports both GitHub and ADO formats:
  GitHub: https://github.com/Azure/c-logging/pull/306
  ADO:    https://msazure.visualstudio.com/One/_git/zrpc/pullrequest/15088625

.EXAMPLE
PS> .\watch_prs.ps1 -PRs "https://github.com/Azure/c-logging/pull/306,https://github.com/Azure/ctest/pull/298"

.EXAMPLE
PS> .\watch_prs.ps1 -PRs "https://github.com/Azure/c-pal/pull/557,https://msazure.visualstudio.com/One/_git/zrpc/pullrequest/15088625"
#>

param(
    [Parameter(Mandatory)][string]$PRs  # comma-separated list of PR URLs
)

$prList = $PRs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$parsed = foreach ($url in $prList) {
    if ($url -match 'github\.com/([^/]+/[^/]+)/pull/(\d+)') {
        [PSCustomObject]@{ Type='github'; Repo=$Matches[1]; Id=$Matches[2]; Url=$url }
    } elseif ($url -match 'visualstudio\.com.*/_git/([^/]+)/pullrequest/(\d+)') {
        [PSCustomObject]@{ Type='ado'; Repo=$Matches[1]; Id=$Matches[2]; Url=$url }
    }
}

while ($true) {
    Clear-Host
    Write-Host "PR Status - $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ("=" * 80)

    foreach ($p in $parsed) {
        Start-Sleep -Milliseconds 500
        if ($p.Type -eq 'github') {
            try {
                $label = "$($p.Repo)#$($p.Id)"
                # Check if PR is merged or closed
                $state = & { gh pr view $p.Id --repo $p.Repo --json state --jq '.state' } 2>$null
                if ($state -eq 'MERGED') {
                    Write-Host ("  M  {0,-40} MERGED  {1}" -f $label, $p.Url) -ForegroundColor Magenta
                    continue
                } elseif ($state -eq 'CLOSED') {
                    Write-Host ("  X  {0,-40} CLOSED  {1}" -f $label, $p.Url) -ForegroundColor DarkGray
                    continue
                }
                # Get check status
                $checks = $null
                $checks = & { gh pr checks $p.Id --repo $p.Repo --json name,bucket } 2>$null
                if (-not $checks) { throw "empty" }
                $c = $checks | ConvertFrom-Json
                $pass = ($c | Where-Object { $_.bucket -eq 'pass' }).Count
                $fail = ($c | Where-Object { $_.bucket -eq 'fail' }).Count
                $pend = ($c | Where-Object { $_.bucket -eq 'pending' }).Count
                $t = $c.Count
                $icon = if ($fail -gt 0) { "X" } elseif ($pend -gt 0) { "*" } else { [char]0x2713 }
                $color = if ($fail -gt 0) { "Red" } elseif ($pend -gt 0) { "Yellow" } else { "Green" }
                Write-Host ("  {0}  {1,-40} {2}/{3} pass  {4} fail  {5} pending  {6}" -f $icon, $label, $pass, $t, $fail, $pend, $p.Url) -ForegroundColor $color
            } catch {
                $label = "$($p.Repo)#$($p.Id)"
                Write-Host ("  ?  {0,-40} fetch error  {1}" -f $label, $p.Url) -ForegroundColor Gray
            }
        } elseif ($p.Type -eq 'ado') {
            try {
                $label = "$($p.Repo)!$($p.Id)"
                $org = "https://dev.azure.com/msazure"
                # Check if PR is merged or abandoned
                $prStatus = & { az repos pr show --id $p.Id --organization $org --query "status" -o tsv } 2>$null
                if ($prStatus -eq 'completed') {
                    Write-Host ("  M  {0,-40} MERGED  {1}" -f $label, $p.Url) -ForegroundColor Magenta
                    continue
                } elseif ($prStatus -eq 'abandoned') {
                    Write-Host ("  X  {0,-40} ABANDONED  {1}" -f $label, $p.Url) -ForegroundColor DarkGray
                    continue
                }
                # Get build policy status (ignore non-build policies like reviewer approvals)
                $pol = & { az repos pr policy list --id $p.Id --organization $org --query "[?configuration.isBlocking].{S:status,T:configuration.type.displayName}" -o json } 2>$null
                if (-not $pol) { throw "empty" }
                $c = $pol | ConvertFrom-Json
                $builds = $c | Where-Object { $_.T -like '*Build*' }
                $bPass = ($builds | Where-Object { $_.S -eq 'approved' }).Count
                $bFail = ($builds | Where-Object { $_.S -eq 'rejected' }).Count
                $bRun = ($builds | Where-Object { $_.S -eq 'running' -or $_.S -eq 'queued' }).Count
                $bTotal = $builds.Count
                $oWait = ($c | Where-Object { $_.T -notlike '*Build*' -and $_.S -ne 'approved' }).Count
                $icon = if ($bFail -gt 0) { "X" } elseif ($bRun -gt 0) { "*" } else { [char]0x2713 }
                $color = if ($bFail -gt 0) { "Red" } elseif ($bRun -gt 0) { "Yellow" } else { "Green" }
                Write-Host ("  {0}  {1,-40} builds: {2}/{3} pass {4} fail {5} run  |  {6} policies waiting  {7}" -f $icon, $label, $bPass, $bTotal, $bFail, $bRun, $oWait, $p.Url) -ForegroundColor $color
            } catch {
                $label = "$($p.Repo)!$($p.Id)"
                Write-Host ("  ?  {0,-40} fetch error  {1}" -f $label, $p.Url) -ForegroundColor Gray
            }
        }
    }

    Write-Host "`nRefreshing in 30s... (Ctrl+C to stop)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
}
