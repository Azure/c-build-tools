# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Self-tests that fail early, with actionable guidance, before any propagation work: the -Pipeline
# credentials and GitHub token, and Azure DevOps access (also checked after interactive sign-in).

function Fail-Preflight
{
    param([string] $Message)
    Write-Log ERROR '================ PREFLIGHT FAILED ================'
    foreach ($line in ($Message -split "`n")) { Write-Log ERROR $line.TrimEnd() }
    Write-Log ERROR '================================================='
    restore-original-directory
    exit 1
}

# -Pipeline reads both tokens from the environment; check them before any network call.
function Test-PipelineCredentials
{
    $problems = @()
    if ([string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN))
    {
        $problems += "SYSTEM_ACCESSTOKEN is not set. Map it into the step env: SYSTEM_ACCESSTOKEN: `$(System.AccessToken)"
    }
    else
    {
        # Azure DevOps token present
    }
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN))
    {
        $problems += @'
GH_TOKEN is not set (pipeline variable 'ghToken' is empty). The propagation needs a GitHub token so
its gh calls and pushes to github.com work.
How to get one:
  - Run: gh auth token            (prints your current gh session token), or
  - Create a PAT at https://github.com/settings/tokens with 'repo' scope.
How to use it:
  - In the pipeline: Edit -> Variables -> add 'ghToken' (secret, "settable at queue time"),
    paste the token when you queue the run, then re-run.
'@
    }
    else
    {
        # GitHub token present
    }
    if ($problems.Count -gt 0)
    {
        Fail-Preflight ($problems -join "`n")
    }
    else
    {
        # both tokens present
    }
}

# Validate that the GitHub token actually works against the GitHub API.
function Test-GitHubAuth
{
    Write-Log INFO 'Validating GitHub token...'
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
    else
    {
        Write-Log INFO "GitHub token OK (authenticated as '$login')."
    }
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
        else
        {
            # not a github.com repo
        }
    }
    $slugs = @($slugs | Select-Object -Unique)
    if ($slugs.Count -eq 0)
    {
        Write-Log INFO 'No github.com repos in the dependency graph; nothing to check.'
        return
    }
    else
    {
        # check every GitHub repo
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
        else
        {
            # every repo reachable
        }
        if ($no_write.Count -gt 0)
        {
            $msg += ''
            $msg += "Accessible but read-only (no push/write access):"
            foreach ($s in $no_write) { $msg += "  - $s" }
            $msg += "Fix: use a token with 'repo' (write) scope and ensure your account has write access"
            $msg += 'to these repos, then re-run.'
        }
        else
        {
            # every reachable repo writable
        }
        Fail-Preflight ($msg -join "`n")
    }
    else
    {
        Write-Log INFO "GitHub write access OK for all $($slugs.Count) upstream repo(s)."
    }
}

# How to fix Azure DevOps access for the current mode.
function get-ado-access-guidance
{
    if (test-pipeline-mode)
    {
        return "Ensure the pipeline's build service identity can read the repository and contribute to its pull requests."
    }
    else
    {
        return "Sign in with 'az login' using an account that can access the repository, or pass -azure_token with a PAT that has Code (Read & Write) and Work Items (Read & Write) permissions."
    }
}

# Validate that Azure DevOps is reachable with the current credentials and that every Azure DevOps
# root repository can be read.
function Test-AdoAccess
{
    param([string[]] $root_list)

    $ado_roots = @($root_list | Where-Object { get-azure-org-project-from-url $_ })
    if ($ado_roots.Count -eq 0)
    {
        Write-Log INFO 'No Azure DevOps root repos; skipping the Azure DevOps access check.'
        return
    }
    else
    {
        Write-Log INFO 'Validating Azure DevOps access...'
    }

    $checked_orgs = @{}
    foreach ($url in $ado_roots)
    {
        $info = get-azure-org-project-from-url $url
        $org = $info.Organization
        if (-not $checked_orgs.ContainsKey($org))
        {
            $cd = $null
            try
            {
                $cd = invoke-ado-rest -Method GET -Url "$org/_apis/connectionData?api-version=7.1-preview"
            }
            catch
            {
                Fail-Preflight "Could not reach Azure DevOps ($org): $(get-ado-error-message $_)`n$(get-ado-access-guidance)"
            }
            $who = $cd.authenticatedUser.providerDisplayName
            if ([string]::IsNullOrWhiteSpace($who))
            {
                Fail-Preflight "Azure DevOps ($org) did not report an authenticated user.`n$(get-ado-access-guidance)"
            }
            else
            {
                Write-Log INFO "Azure DevOps ($org) reachable; authenticated as '$who'."
            }
            $checked_orgs[$org] = $true
        }
        else
        {
            # organization already checked
        }

        $name = get-name-from-url $url
        try
        {
            $null = invoke-ado-rest -Method GET -Url "$org/$($info.Project)/_apis/git/repositories/$name/pullrequests?searchCriteria.status=active&`$top=1&api-version=7.1"
            Write-Log INFO "  OK: $name"
        }
        catch
        {
            Fail-Preflight "Cannot read Azure DevOps repo '$name': $(get-ado-error-message $_)`n$(get-ado-access-guidance)"
        }
    }
}

# Run the -Pipeline network self-tests. Call before any propagation work.
function Invoke-Preflight
{
    param([string[]] $root_list)
    Write-Log STEP 'Preflight self-test starting'
    Test-GitHubAuth
    Test-AdoAccess -root_list $root_list
    Write-Log STEP 'Preflight self-test passed'
}
