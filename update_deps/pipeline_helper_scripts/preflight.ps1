# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Preflight self-test run before any propagation work. Fails early, with actionable guidance,
# if the GitHub token is missing/invalid or if Azure DevOps cannot be reached and used as the
# build account. Requires logging.ps1 to be sourced first.

$script:AdoOrgUrl = 'https://dev.azure.com/msazure'
$script:AdoProject = 'One'

function Fail-Preflight
{
    param([string] $Message)
    Write-Log ERROR '================ PREFLIGHT FAILED ================'
    foreach ($line in ($Message -split "`n")) { Write-Log ERROR $line }
    Write-Log ERROR '================================================='
    exit 1
}

# Validate that a usable GitHub token is present and actually works against the GitHub API.
function Test-GitHubAuth
{
    Write-Log INFO 'Validating GitHub token...'
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN))
    {
        Fail-Preflight @'
No GitHub token was provided (env GH_TOKEN / pipeline variable 'ghToken' is empty).
The propagation needs a GitHub token so its gh calls work.
How to get one:
  - Run: gh auth token            (prints your current gh session token), or
  - Create a PAT at https://github.com/settings/tokens with 'repo' scope.
How to use it:
  - In the pipeline: Edit -> Variables -> add 'ghToken' (secret, "settable at queue time"),
    paste the token when you queue the run, then re-run.
'@
    }

    $result = Invoke-Logged -File 'gh' -Arguments @('api', 'user', '--jq', '.login') -MaxAttempts 3 -AllowFail
    $login = ($result.Output | Out-String).Trim()
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($login))
    {
        Fail-Preflight @"
The provided GitHub token is invalid or lacks access ('gh api user' failed).
Get a working token with 'gh auth token', or create a 'repo'-scoped PAT at
https://github.com/settings/tokens, then set the pipeline 'ghToken' variable and re-run.
"@
    }
    Write-Log INFO "GitHub token OK (authenticated as '$login')."
}

# Validate the GitHub token can actually WRITE the upstream GitHub repos the propagation will open
# PRs on. A token that is merely valid (passes Test-GitHubAuth) but is not SSO-authorized for the
# Azure org, or lacks write access, sails through and then fails ~20 minutes later mid-run with a 403
# ("Resource protected by organization SAML enforcement"). This catches that upfront. The GitHub
# repos come from the discovered dependency graph (urls whose host is github.com).
function Test-GitHubRepoAccess
{
    param([string[]] $repo_urls)
    Write-Log INFO 'Validating GitHub write access (SSO + push) to the upstream repos...'

    # Collect github.com repos as owner/name slugs from the discovered dependency-graph urls.
    $slugs = @()
    foreach ($url in $repo_urls)
    {
        if ($url -match 'github\.com[:/]+([^/]+/[^/]+?)(?:\.git)?/?$')
        {
            $slugs += $matches[1]
        }
    }
    $slugs = $slugs | Select-Object -Unique
    if ($slugs.Count -eq 0)
    {
        Write-Log INFO 'No github.com repos in the dependency graph; nothing to check.'
        return
    }

    $no_access = @()   # SSO not authorized / repo unreachable (403/404)
    $no_write = @()    # reachable but push=false
    foreach ($slug in $slugs)
    {
        $res = Invoke-Logged -File 'gh' -Arguments @('api', "repos/$slug", '--jq', '.permissions.push') -MaxAttempts 3 -AllowFail
        $out = ($res.Output | Out-String).Trim()
        if ($res.ExitCode -ne 0)
        {
            # Most common cause here is SAML SSO enforcement (the PAT is not authorized for the org).
            $no_access += $slug
        }
        elseif ($out -ne 'true')
        {
            $no_write += $slug
        }
        else
        {
            Write-Log INFO "  OK (write): $slug"
        }
    }

    if ($no_access.Count -gt 0 -or $no_write.Count -gt 0)
    {
        $msg = @()
        $msg += 'The GitHub token cannot open PRs on every upstream repo the propagation needs.'
        if ($no_access.Count -gt 0)
        {
            $msg += ''
            $msg += "Not accessible (likely NOT SSO-authorized for the org, or no access):"
            foreach ($s in $no_access) { $msg += "  - $s" }
            $msg += 'Fix: at https://github.com/settings/tokens, click "Configure SSO" next to the token'
            $msg += 'and Authorize it for the Azure organization (SAML SSO is enforced), then re-run.'
        }
        if ($no_write.Count -gt 0)
        {
            $msg += ''
            $msg += "Accessible but read-only (no push/write access):"
            foreach ($s in $no_write) { $msg += "  - $s" }
            $msg += "Fix: use a token with 'repo' (write) scope and ensure your account has write access"
            $msg += 'to these repos, then re-run.'
        }
        Fail-Preflight ($msg -join "`n")
    }

    Write-Log INFO "GitHub write access OK for all $($slugs.Count) upstream repo(s)."
}

# Validate Azure DevOps is reachable with the build account token and that target ADO repos
# can actually be read (i.e. the build service has access).
function Test-AdoAccess
{
    param([string[]] $root_list)

    Write-Log INFO 'Validating Azure DevOps access as the build account...'
    $token = $env:SYSTEM_ACCESSTOKEN
    if ([string]::IsNullOrWhiteSpace($token))
    {
        Fail-Preflight "SYSTEM_ACCESSTOKEN is not set. The pipeline must map 'SYSTEM_ACCESSTOKEN: `$(System.AccessToken)' into the step env."
    }
    Write-Log INFO "GET $script:AdoOrgUrl/_apis/connectionData"
    try
    {
        $cd = invoke-ado-rest -Method GET -Url "$script:AdoOrgUrl/_apis/connectionData?api-version=7.1-preview"
    }
    catch
    {
        Fail-Preflight "Could not reach Azure DevOps ($script:AdoOrgUrl). connectionData failed: $($_.Exception.Message)"
    }
    $who = $cd.authenticatedUser.providerDisplayName
    if ([string]::IsNullOrWhiteSpace($who))
    {
        Fail-Preflight 'Azure DevOps connectionData returned no authenticated user; the build token is not valid.'
    }
    Write-Log INFO "Azure DevOps reachable; authenticated as '$who' (id $($cd.authenticatedUser.id))."

    foreach ($url in $root_list)
    {
        if ($url -match 'visualstudio\.com|dev\.azure\.com')
        {
            $name = ($url -split '/_git/')[-1]
            Write-Log INFO "Checking build-account read access to ADO repo '$name'..."
            try
            {
                $null = invoke-ado-rest -Method GET -Url "$script:AdoOrgUrl/$script:AdoProject/_apis/git/repositories/$name/pullrequests?searchCriteria.status=active&`$top=1&api-version=7.1"
                Write-Log INFO "  OK: $name"
            }
            catch
            {
                Fail-Preflight "Build account cannot read ADO repo '$name': $($_.Exception.Message). Ensure One Build Service (msazure) has access to it."
            }
        }
    }
}

# Run all preflight checks. Call before any propagation work.
function Invoke-Preflight
{
    param([string[]] $root_list)
    Write-Log STEP 'Preflight self-test starting'
    Test-GitHubAuth
    Test-AdoAccess -root_list $root_list
    Write-Log STEP 'Preflight self-test passed'
}
