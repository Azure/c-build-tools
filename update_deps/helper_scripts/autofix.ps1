# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# AutoFix: uses GitHub Copilot CLI to diagnose and fix build failures.

$global:MAX_AUTOFIX_ATTEMPTS = 2

# Fetch build logs for failed checks. Returns a string with error context.
function get-failed-build-logs
{
    param(
        [string] $repo_name,
        [string] $pr_url
    )
    $logs = ""

    $repo_type = get-repo-type $repo_name

    if ($repo_type -eq "github")
    {
        # Get failed check details from GitHub
        $checks_output = gh pr checks --json name,state,bucket,link 2>$null
        if ($LASTEXITCODE -eq 0 -and $checks_output)
        {
            $checks = $checks_output | ConvertFrom-Json
            $failed = @($checks | Where-Object { $_.bucket -eq "fail" })
            if ($failed.Count -gt 0)
            {
                $log_lines = @("Failed checks:")
                foreach ($check in $failed)
                {
                    $log_lines += "- $($check.name): $($check.link)"
                }

                # Try to get job logs for the failed run
                $run_output = gh run list --branch (git rev-parse --abbrev-ref HEAD 2>$null) --status failure --limit 1 --json databaseId --jq '.[0].databaseId' 2>$null
                if ($LASTEXITCODE -eq 0 -and $run_output)
                {
                    $run_id = $run_output.Trim()
                    $job_logs = gh run view $run_id --log-failed 2>$null
                    if ($LASTEXITCODE -eq 0 -and $job_logs)
                    {
                        # Truncate to last 200 lines to keep prompt manageable
                        $log_tail = ($job_logs -split "`n" | Select-Object -Last 200) -join "`n"
                        $log_lines += ""
                        $log_lines += "Build log (last 200 lines):"
                        $log_lines += $log_tail
                    }
                    else
                    {
                        # couldn't get logs
                    }
                }
                else
                {
                    # no failed run found
                }
                $logs = $log_lines -join "`n"
            }
            else
            {
                # no failed checks
            }
        }
        else
        {
            # couldn't get check data
        }
    }
    elseif ($repo_type -eq "azure")
    {
        # Get build logs from Azure DevOps
        if ($pr_url -match "/pullrequest/(\d+)")
        {
            $pr_id = [int]$matches[1]
            $azure_info = get-azure-org-project $repo_name
            $org = $azure_info.Organization

            # Get policies to find the failed build ID
            $policy_output = az repos pr policy list `
                --id $pr_id `
                --organization $org `
                --query "[?status=='rejected'].{BuildId:context.buildId}" `
                --output json 2>$null
            if ($LASTEXITCODE -eq 0 -and $policy_output)
            {
                $policies = @($policy_output | ConvertFrom-Json)
                $build_ids = @($policies | Where-Object { $_.BuildId } | ForEach-Object { $_.BuildId })
                if ($build_ids.Count -gt 0)
                {
                    $build_id = $build_ids[0]
                    # Get the build log
                    $log_output = az devops invoke `
                        --area build `
                        --resource builds `
                        --route-parameters project=$($azure_info.Project) buildId=$build_id `
                        --org $org `
                        --api-version 7.1 `
                        --query "{result:result, validationResults:validationResults}" `
                        -o json 2>$null
                    if ($LASTEXITCODE -eq 0 -and $log_output)
                    {
                        $build_info = $log_output | ConvertFrom-Json
                        $log_lines = @("Build ID: $build_id, Result: $($build_info.result)")

                        # Include validation errors (YAML validation failures show here)
                        if ($build_info.validationResults)
                        {
                            $log_lines += ""
                            $log_lines += "Validation errors:"
                            foreach ($v in $build_info.validationResults)
                            {
                                $log_lines += "- $($v.message)"
                            }
                        }
                        else
                        {
                            # no validation results
                        }

                        # Try to get the timeline for failed job details
                        $timeline = az devops invoke `
                            --area build `
                            --resource timeline `
                            --route-parameters project=$($azure_info.Project) buildId=$build_id `
                            --org $org `
                            --api-version 7.1 `
                            -o json 2>$null
                        if ($LASTEXITCODE -eq 0 -and $timeline)
                        {
                            $records = ($timeline | ConvertFrom-Json).records
                            $failed_records = @($records | Where-Object { $_.result -eq "failed" -and $_.issues })
                            if ($failed_records.Count -gt 0)
                            {
                                $log_lines += ""
                                $log_lines += "Failed steps:"
                                foreach ($rec in $failed_records)
                                {
                                    $log_lines += "- $($rec.name):"
                                    foreach ($issue in $rec.issues)
                                    {
                                        $log_lines += "    $($issue.message)"
                                    }
                                }
                            }
                            else
                            {
                                # no failed records with issues
                            }
                        }
                        else
                        {
                            # couldn't get timeline
                        }

                        $logs = $log_lines -join "`n"
                    }
                    else
                    {
                        # couldn't get build info
                    }
                }
                else
                {
                    # no failed builds found
                }
            }
            else
            {
                # couldn't get policies
            }
        }
        else
        {
            # couldn't parse PR ID
        }
    }
    else
    {
        # unknown repo type
    }

    return $logs
}

# Invoke Copilot CLI to fix build errors in the current repo.
# Must be called from inside the repo directory on the PR branch.
# Returns $true if Copilot ran and pushed a fix, $false otherwise.
function invoke-copilot-autofix
{
    param(
        [string] $repo_name,
        [string] $branch_name,
        [string] $pr_url,
        [string] $build_logs = ""
    )
    $result = $false

    Write-Host "`n  AutoFix: Launching Copilot CLI to diagnose build failure..." -ForegroundColor Magenta

    # Fetch build logs if not provided by caller
    if (-not $build_logs)
    {
        Write-Host "  AutoFix: Fetching build logs..." -ForegroundColor Magenta
        Push-Location $global:work_dir
        $build_logs = get-failed-build-logs -repo_name $repo_name -pr_url $pr_url
        Pop-Location
    }
    else
    {
        # logs provided by caller
    }
    if ($build_logs)
    {
        Write-Host "  AutoFix: Got build logs ($($build_logs.Length) chars)" -ForegroundColor Magenta
    }
    else
    {
        Write-Host "  AutoFix: No build logs available, Copilot will build locally" -ForegroundColor Yellow
        $build_logs = "(no build logs available - build locally to reproduce)"
    }

    # Detect the default CMake Visual Studio generator
    $vs_generator = "Visual Studio 17 2022"
    $cmake_help = cmake --help 2>$null
    if ($cmake_help)
    {
        $default_gen = $cmake_help | Select-String '^\*\s+(Visual Studio .+?)\s+=' | Select-Object -First 1
        if ($default_gen -and $default_gen.Matches[0].Groups[1].Value)
        {
            $vs_generator = $default_gen.Matches[0].Groups[1].Value
        }
        else
        {
            # no default VS generator found, use fallback
        }
    }
    else
    {
        # cmake not found, use fallback
    }

    $prompt = @"
The CI build failed for a pull request in this repository.
PR: $pr_url
Branch: $branch_name

## How to configure and build this repo

This is a C repository that uses CMake with the "$vs_generator" generator. Use EXACTLY these commands:

1. Configure CMake:
   cmake -S . -B cmake -G "$vs_generator" -A x64 -Drun_unittests=ON -Drun_repo_validation=ON -Duse_ltcg=OFF

2. Build the solution:
   cmake --build cmake --config Debug

3. If only specific targets fail, build just those targets:
   cmake --build cmake --config Debug --target <target_name>

4. If repo validation or traceability fails, build those targets:
   cmake --build cmake --config Debug --target <project>_repo_validation
   cmake --build cmake --config Debug --target <project>_traceability

Do NOT try other generators or configurations. The generator above is correct.

## CI build failure logs

$build_logs

## Your task

1. Read the CI build failure logs above carefully
2. If the error is clear from the logs (e.g., YAML validation error), fix it directly
3. If the error requires local reproduction, build the project locally using the commands above
4. Fix the code to resolve the errors
5. Verify the fix by rebuilding locally
6. Commit the fix with message "AutoFix: resolve build errors"
7. Push the fix to the branch: git push origin $branch_name

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

                # Trigger CI pipeline for GitHub repos (Azure pipelines trigger automatically on push)
                $repo_type = get-repo-type $repo_name
                if ($repo_type -eq "github")
                {
                    Write-Host "  AutoFix: Triggering pipeline..." -ForegroundColor Magenta
                    $null = gh pr comment --body "/AzurePipelines run" 2>&1
                }
                else
                {
                    # Azure repos trigger CI automatically on push
                }

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
