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

## How to configure and build this repo

This is a C repository that uses CMake. Follow these steps:

1. Configure CMake (generate into cmake/ directory, use Visual Studio generator):
   cmake -S . -B cmake -G "Visual Studio 17 2022" -A x64 -Drun_unittests=ON -Drun_repo_validation=ON -Duse_ltcg=OFF

2. Build the solution:
   cmake --build cmake --config Debug

3. If only specific targets fail, build just those targets:
   cmake --build cmake --config Debug --target <target_name>

4. If repo validation or traceability fails, build those targets:
   cmake --build cmake --config Debug --target <project>_repo_validation
   cmake --build cmake --config Debug --target <project>_traceability

## Your task

1. Build the project locally to reproduce the CI failure
2. Read the build errors carefully and diagnose the root cause
3. Fix the code to resolve the build errors
4. Verify the fix by rebuilding
5. Commit the fix with message "AutoFix: resolve build errors"
6. Push the fix to the branch: git push origin $branch_name

## Important rules

- Only fix build errors, do not refactor or change unrelated code
- If you cannot reproduce or fix the error, exit without making changes
- The branch already exists and is checked out
- Do not use any custom skills or external tools — use only the shell commands above
"@

    try
    {
        # Set console encoding to UTF-8 so Copilot's emoji/icons render correctly
        $prev_encoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

        # Run Copilot with output visible to user.
        # Use ForEach-Object + Write-Host to prevent PowerShell from capturing
        # stdout as function return value while preserving UTF-8 encoding.
        copilot -p $prompt --autopilot --allow-all --no-ask-user --no-custom-instructions 2>&1 | ForEach-Object { Write-Host $_ }
        $copilot_exit = $LASTEXITCODE

        [Console]::OutputEncoding = $prev_encoding

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
