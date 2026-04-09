# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# AutoFix: uses GitHub Copilot CLI to diagnose and fix build failures.

$global:MAX_AUTOFIX_ATTEMPTS = 2

# Invoke Copilot CLI to fix build errors in the current repo.
# Must be called from inside the repo directory on the PR branch.
# Returns $true if Copilot ran and pushed a fix, $false otherwise.
function invoke-copilot-autofix
{
    param(
        [string] $repo_name,
        [string] $branch_name,
        [string] $pr_url
    )
    $result = $false

    Write-Host "`n  AutoFix: Launching Copilot CLI to diagnose build failure..." -ForegroundColor Magenta

    $prompt = @"
The CI build failed for a pull request in this repository.
PR: $pr_url
Branch: $branch_name

Your task:
1. Build the project locally to reproduce the failure (use cmake and the build system in this repo)
2. Diagnose the build errors from the output
3. Fix the code to resolve the build errors
4. Commit the fix with message "AutoFix: resolve build errors"
5. Push the fix to the branch: git push origin $branch_name

Important:
- Only fix build errors, do not refactor or change unrelated code
- If you cannot reproduce or fix the error, exit without making changes
- The branch already exists and is checked out
"@

    try
    {
        # Run Copilot with output streaming to the console.
        # Use Out-Host to prevent PowerShell from capturing stdout as function return value.
        copilot -p $prompt --autopilot --allow-all --no-ask-user | Out-Host
        $copilot_exit = $LASTEXITCODE

        if ($copilot_exit -eq 0)
        {
            # Check if Copilot actually pushed a new commit
            $local_sha = (git rev-parse HEAD 2>$null)
            git fetch origin $branch_name 2>$null
            $remote_sha = (git rev-parse "origin/$branch_name" 2>$null)

            if ($local_sha -eq $remote_sha)
            {
                Write-Host "  AutoFix: Copilot pushed a fix" -ForegroundColor Green
                $result = $true
            }
            else
            {
                Write-Host "  AutoFix: Copilot finished but no new commit was pushed" -ForegroundColor Yellow
            }
        }
        else
        {
            Write-Host "  AutoFix: Copilot exited with code $copilot_exit" -ForegroundColor Yellow
        }
    }
    catch
    {
        Write-Host "  AutoFix: Error running Copilot: $_" -ForegroundColor Yellow
    }

    return $result
}
