# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Azure DevOps repository operations for propagate_updates.ps1. Every call goes through the REST API
# (invoke-ado-rest). -Pipeline runs authenticate with SYSTEM_ACCESSTOKEN; interactive runs with a
# Personal Access Token or a WAM sign-in through the Azure CLI (see install_az_cli.ps1).
# Uses global: $azure_work_item

$script:ADO_RESOURCE_ID = '499b84ac-1321-427f-aa17-267ca6975798'
$script:ADO_BUILD_POLICY_TYPE_ID = '0609b952-1397-4640-95ec-e00a01b2c241'
$script:ADO_STATUS_POLICY_TYPE_ID = 'cbdc66da-9728-4af8-aada-9a5a32e4a226'
$script:ado_pat = $null
$script:ado_token_cache = @{}
$script:ado_tenant_cache = @{}
$script:ado_user_ids = @{}


# --- Authentication -----------------------------------------------------------------------------

# Organization URL (https://dev.azure.com/<org> or https://<org>.visualstudio.com) of an Azure DevOps
# URL, or $null for other URLs.
function get-ado-org-base-url
{
    param([string] $url)
    $result = $null
    if ($url -match '^(https://dev\.azure\.com/[^/?]+)')
    {
        $result = $matches[1]
    }
    elseif ($url -match '^(https://[^/]+\.visualstudio\.com)')
    {
        $result = $matches[1]
    }
    else
    {
        # not an Azure DevOps URL
    }
    return $result
}

# Tenant that owns an Azure DevOps organization, read from the X-VSS-ResourceTenant header of an
# anonymous request. Returns $null if it cannot be determined.
function get-ado-tenant-id
{
    param([string] $org_url)
    if ($script:ado_tenant_cache.ContainsKey($org_url))
    {
        return $script:ado_tenant_cache[$org_url]
    }
    else
    {
        # not looked up yet
    }

    $header = $null
    try
    {
        $null = Invoke-WebRequest -Uri "$org_url/_apis/connectionData" -Method Get -Headers @{ 'X-TFS-FedAuthRedirect' = 'Suppress' } -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    }
    catch
    {
        $response = $_.Exception.Response
        if (-not $response)
        {
            # no response (network failure)
        }
        elseif ($response.Headers -is [System.Net.WebHeaderCollection])
        {
            $header = $response.Headers['X-VSS-ResourceTenant']
        }
        else
        {
            $values = $null
            if ($response.Headers.TryGetValues('X-VSS-ResourceTenant', [ref]$values))
            {
                $header = @($values) -join ','
            }
            else
            {
                # header absent
            }
        }
    }

    $tenant = $null
    foreach ($candidate in @("$header" -split ','))
    {
        $candidate = $candidate.Trim()
        if (-not $tenant -and $candidate -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' -and $candidate -ne '00000000-0000-0000-0000-000000000000')
        {
            $tenant = $candidate
        }
        else
        {
            # not a usable tenant id
        }
    }
    $script:ado_tenant_cache[$org_url] = $tenant
    return $tenant
}

# Azure DevOps access token for an interactive WAM sign-in, from the Azure CLI for the tenant that
# owns the organization. Cached until five minutes before it expires.
function get-ado-access-token
{
    param([string] $org_url)
    $tenant = get-ado-tenant-id -org_url $org_url
    $cache_key = if ($tenant) { $tenant } else { 'default' }
    $cached = $script:ado_token_cache[$cache_key]
    if ($cached -and (Get-Date).ToUniversalTime() -lt $cached.RefreshAfterUtc)
    {
        return $cached.Token
    }
    else
    {
        # no usable cached token
    }

    $az_args = @('account', 'get-access-token', '--resource', $script:ADO_RESOURCE_ID, '--output', 'json')
    if ($tenant)
    {
        $az_args += @('--tenant', $tenant)
    }
    else
    {
        # use the default tenant
    }
    # A transient sign-in error mid-run must not end the run: retry, then throw so the caller can
    # treat it like any other failed request (watchers retry; writes report the failure).
    $json = $null
    for ($attempt = 1; $attempt -le 3; $attempt++)
    {
        $json = az @az_args 2>$null
        if ($LASTEXITCODE -eq 0 -and $json)
        {
            break
        }
        else
        {
            $json = $null
        }
        if ($attempt -lt 3)
        {
            Start-Sleep -Seconds (5 * $attempt)
        }
        else
        {
            # out of attempts
        }
    }
    if (-not $json)
    {
        $login = if ($tenant) { "az login --tenant $tenant" } else { "az login" }
        throw "Could not get an Azure DevOps access token from the Azure CLI. Run '$login', or pass -azure_token."
    }
    else
    {
        # token acquired
    }
    $token = (@($json) -join "`n") | ConvertFrom-Json

    $expires_utc = (Get-Date).ToUniversalTime().AddMinutes(10)
    if ($token.expires_on)
    {
        $expires_utc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$token.expires_on).UtcDateTime
    }
    elseif ($token.expiresOn)
    {
        try { $expires_utc = ([datetime]$token.expiresOn).ToUniversalTime() } catch { }
    }
    else
    {
        # unknown expiry; refresh soon
    }
    add-redaction-value $token.accessToken
    $script:ado_token_cache[$cache_key] = @{ Token = $token.accessToken; RefreshAfterUtc = $expires_utc.AddMinutes(-5) }
    return $token.accessToken
}

# Drop the cached WAM token for an organization so the next request acquires a new one. Returns
# $true when a refresh is possible (interactive WAM sign-in).
function reset-ado-access-token
{
    param([string] $org_url)
    if ((test-pipeline-mode) -or $script:ado_pat)
    {
        return $false
    }
    else
    {
        $tenant = get-ado-tenant-id -org_url $org_url
        $cache_key = if ($tenant) { $tenant } else { 'default' }
        $script:ado_token_cache.Remove($cache_key)
        return $true
    }
}

# Authorization header value for Azure DevOps REST calls.
function get-ado-authorization-header
{
    param([string] $org_url)
    if (test-pipeline-mode)
    {
        if ([string]::IsNullOrWhiteSpace($env:SYSTEM_ACCESSTOKEN))
        {
            fail-with-status "SYSTEM_ACCESSTOKEN is not set; cannot call the Azure DevOps REST API."
        }
        else
        {
            return "Bearer $($env:SYSTEM_ACCESSTOKEN)"
        }
    }
    elseif ($script:ado_pat)
    {
        return "Basic " + [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($script:ado_pat)"))
    }
    else
    {
        return "Bearer " + (get-ado-access-token -org_url $org_url)
    }
}


# --- REST helpers -------------------------------------------------------------------------------

# HTTP status code of a failed web request, or 0 if no response was received.
function get-http-status-code
{
    param($error_record)
    try
    {
        return [int]$error_record.Exception.Response.StatusCode
    }
    catch
    {
        return 0
    }
}

# Seconds to wait before retrying a throttled request: Retry-After when present (capped), else 5.
function get-http-retry-after-seconds
{
    param($error_record)
    $seconds = 5
    try
    {
        $headers = $error_record.Exception.Response.Headers
        if ($headers -is [System.Net.WebHeaderCollection] -or $headers -is [hashtable])
        {
            if ("$($headers['Retry-After'])" -match '^\d+$') { $seconds = [int]$headers['Retry-After'] }
        }
        elseif ($headers -and $headers.RetryAfter -and $headers.RetryAfter.Delta)
        {
            $seconds = [int]$headers.RetryAfter.Delta.TotalSeconds
        }
        else
        {
            # no Retry-After header
        }
    }
    catch
    {
        # no response headers
    }
    return [Math]::Min([Math]::Max($seconds, 1), 60)
}

# Readable Azure DevOps error: the service's message when present, else the exception message.
function get-ado-error-message
{
    param($error_record)
    $detail = $null
    if ($error_record.ErrorDetails -and $error_record.ErrorDetails.Message)
    {
        $detail = $error_record.ErrorDetails.Message
        try
        {
            $parsed = $detail | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.message) { $detail = $parsed.message }
        }
        catch
        {
            # not JSON; keep the raw text
        }
    }
    else
    {
        # no service details
    }
    if (-not $detail)
    {
        $detail = $error_record.Exception.Message
    }
    return (Protect-Secret $detail)
}

# Call the Azure DevOps REST API and return the parsed response. Reads are retried on throttling,
# server errors and dropped connections; writes only on throttling (429/503: not processed). A 401
# for an interactive WAM token refreshes the token once. X-TFS-FedAuthRedirect makes authentication
# failures return 401 instead of an HTML sign-in page, which is rejected unless -AllowText is set.
function invoke-ado-rest
{
    param(
        [string] $Method,
        [string] $Url,
        $Body = $null,
        [string] $BodyJson = $null,
        [string] $ContentType = 'application/json; charset=utf-8',
        [string] $Accept = $null,
        [int] $TimeoutSec = 0,
        [int] $MaxAttempts = 3,
        [switch] $AllowText
    )
    # Always bound the wait: the Windows PowerShell default (0) waits forever on a request that is
    # never answered. Writes get longer than reads since a slow one may still succeed.
    if ($TimeoutSec -le 0)
    {
        $TimeoutSec = if ($Method -eq 'GET') { 60 } else { 300 }
    }
    else
    {
        # caller-provided timeout
    }
    $payload = $null
    if ($BodyJson)
    {
        $payload = $BodyJson
    }
    elseif ($null -ne $Body)
    {
        $payload = $Body | ConvertTo-Json -Depth 10
    }
    else
    {
        # no body
    }
    $org_url = get-ado-org-base-url $Url
    $token_refreshed = $false
    $attempt = 0

    while ($true)
    {
        $attempt++
        $headers = @{
            Authorization = (get-ado-authorization-header -org_url $org_url)
            'X-TFS-FedAuthRedirect' = 'Suppress'
        }
        if ($Accept) { $headers['Accept'] = $Accept }
        $params = @{ Method = $Method; Uri = $Url; Headers = $headers; TimeoutSec = $TimeoutSec; UseBasicParsing = $true; ErrorAction = 'Stop' }
        # PowerShell 7.4+ applies TimeoutSec only until the response starts; also bound a stalled body.
        if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('OperationTimeoutSeconds'))
        {
            $params['OperationTimeoutSeconds'] = $TimeoutSec
        }
        else
        {
            # Windows PowerShell fails a stalled body read on its own
        }
        if ($null -ne $payload)
        {
            # Send UTF-8 bytes: Windows PowerShell would otherwise encode a string body as Latin-1.
            $params['ContentType'] = $ContentType
            $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes($payload)
        }
        else
        {
            # no body
        }

        $failure = $null
        $response = $null
        try
        {
            $response = Invoke-RestMethod @params
        }
        catch
        {
            $failure = $_
        }

        if (-not $failure)
        {
            if (-not $AllowText -and $response -is [string] -and $response.Trim())
            {
                throw "Azure DevOps returned a non-JSON response for $Method $Url (likely an authentication redirect)."
            }
            else
            {
                return $response
            }
        }
        else
        {
            # handled below
        }

        $status = get-http-status-code $failure
        if ($status -eq 401 -and -not $token_refreshed -and (reset-ado-access-token -org_url $org_url))
        {
            $token_refreshed = $true
            Write-Log WARN "Azure DevOps rejected the access token; acquiring a new one and retrying $Method $Url"
            continue
        }
        else
        {
            # no token refresh possible
        }

        $retryable = ($status -eq 429 -or $status -eq 503) -or ($Method -eq 'GET' -and ($status -eq 0 -or $status -eq 408 -or $status -ge 500))
        if (-not $retryable -or $attempt -ge $MaxAttempts)
        {
            throw $failure
        }
        else
        {
            $delay = get-http-retry-after-seconds $failure
            $status_text = if ($status) { "HTTP $status" } else { "no response" }
            Write-Log WARN ("Azure DevOps {0} {1} failed ({2}): {3}; retrying in {4}s (attempt {5}/{6})" -f $Method, $Url, $status_text, (get-ado-error-message $failure), $delay, $attempt, $MaxAttempts)
            Start-Sleep -Seconds $delay
        }
    }
}


# --- Lookups ------------------------------------------------------------------------------------

# Resolve the authenticated identity id, used as reviewer for the vote and as autoCompleteSetBy.
function get-ado-authenticated-user-id
{
    param([string] $org_url)
    if (-not $script:ado_user_ids.ContainsKey($org_url))
    {
        $cd = invoke-ado-rest -Method GET -Url "$org_url/_apis/connectionData?api-version=7.1-preview"
        $script:ado_user_ids[$org_url] = $cd.authenticatedUser.id
    }
    else
    {
        # cached for this run
    }
    return $script:ado_user_ids[$org_url]
}

# Fetch a pull request by id (org-scoped route, no project/repo needed). Returns the PR object,
# which includes repository.id and repository.project.id.
function get-ado-pull-request
{
    param([string] $org_url, [int] $pr_id)
    return (invoke-ado-rest -Method GET -Url "$org_url/_apis/git/pullrequests/$pr_id`?api-version=7.1")
}

# Parse an Azure DevOps repository URL into @{ Organization; Project }, or $null for other URLs.
# Accepts https://[user@]dev.azure.com/<org>/<project>/_git/<repo> and
# https://<org>.visualstudio.com/[DefaultCollection/]<project>/_git/<repo>.
function get-azure-org-project-from-url
{
    param(
        [string] $repo_url
    )
    $result = $null

    if($repo_url -match "dev\.azure\.com/([^/]+)/([^/]+)/_git")
    {
        $result = @{
            Organization = "https://dev.azure.com/$($matches[1])"
            Project = $matches[2]
        }
    }
    elseif($repo_url -match "([^/@]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git")
    {
        $result = @{
            Organization = "https://dev.azure.com/$($matches[1])"
            Project = $matches[2]
        }
    }
    else
    {
        # not an Azure DevOps repository URL
    }

    return $result
}

# get Azure DevOps organization and project from the git remote URL of a cloned repo
function get-azure-org-project
{
    param(
        [string] $repo_name
    )
    Push-Location $repo_name
    $repo_url = git config --get remote.origin.url
    Pop-Location

    $result = get-azure-org-project-from-url $repo_url
    if (-not $result)
    {
        fail-with-status "Failed to parse Azure DevOps organization and project from remote URL: $repo_url"
    }
    else
    {
        # parsed
    }

    return $result
}

# PR id from an Azure DevOps PR URL, or $null.
function get-azure-pr-id-from-url
{
    param([string] $pr_url)
    if ($pr_url -match "/pullrequest/(\d+)")
    {
        return [int]$matches[1]
    }
    else
    {
        return $null
    }
}

# Find an active Azure PR for a given branch. Returns the PR URL or $null.
function find-active-azure-pr
{
    param(
        [string] $repo_name,
        [string] $branch_name
    )
    $result = $null

    $azure_info = get-azure-org-project $repo_name
    $org = $azure_info.Organization
    $project = $azure_info.Project
    $source = [uri]::EscapeDataString("refs/heads/$branch_name")
    $target = [uri]::EscapeDataString("refs/heads/master")
    $url = "$org/$project/_apis/git/repositories/$repo_name/pullrequests?searchCriteria.sourceRefName=$source&searchCriteria.targetRefName=$target&searchCriteria.status=active&api-version=7.1"
    try
    {
        $prs = @((invoke-ado-rest -Method GET -Url $url).value)
        if ($prs.Count -gt 0)
        {
            # The list response has no repository.webUrl, so construct the URL from org/project/repo.
            $result = "$org/$project/_git/$repo_name/pullrequest/$($prs[0].pullRequestId)"
        }
        else
        {
            # no active PRs for this branch
        }
    }
    catch
    {
        Write-Log WARN "Could not look up active PRs for ${repo_name}: $(get-ado-error-message $_)"
    }

    return $result
}

# Get the status of an Azure PR ("completed", "abandoned", or "active").
function get-azure-pr-status
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )
    $result = "active"
    $pr_id = get-azure-pr-id-from-url $pr_url
    if ($pr_id)
    {
        $azure_info = get-azure-org-project $repo_name
        try
        {
            $pr = get-ado-pull-request -org_url $azure_info.Organization -pr_id $pr_id
            $result = $pr.status
        }
        catch
        {
            Write-Log WARN "Could not query status of PR ${pr_id}: $(get-ado-error-message $_)"
        }
    }
    else
    {
        # couldn't parse PR ID from URL
    }
    return $result
}

# Fetch a PR, or $null if it cannot be read right now (invoke-ado-rest already retried transient
# failures, so callers simply try again on their next poll).
function get-pr-status-with-retry
{
    param(
        [int] $pr_id,
        [string] $org
    )
    $result = $null
    try
    {
        $result = get-ado-pull-request -org_url $org -pr_id $pr_id
    }
    catch
    {
        Write-Log WARN "PR $pr_id status check failed; will retry on the next poll: $(get-ado-error-message $_)"
    }
    return $result
}

# Policy evaluations (builds, reviewers, status checks, ...) of a PR object.
function get-azure-pr-policy-evaluations
{
    param(
        [string] $org,
        [object] $pr
    )
    $project_id = $pr.repository.project.id
    $artifact_id = "vstfs:///CodeReview/CodeReviewId/$project_id/$($pr.pullRequestId)"
    $url = "$org/$project_id/_apis/policy/evaluations?artifactId=$([uri]::EscapeDataString($artifact_id))&api-version=7.1-preview.1"
    return @((invoke-ado-rest -Method GET -Url $url).value)
}

# Timeline (stages, jobs, tasks) of a build.
function get-ado-build-timeline
{
    param([string] $org, [string] $project, [int] $build_id)
    return (invoke-ado-rest -Method GET -Url "$org/$project/_apis/build/builds/$build_id/timeline?api-version=7.1")
}

# A build's result and validation messages.
function get-ado-build
{
    param([string] $org, [string] $project, [int] $build_id)
    return (invoke-ado-rest -Method GET -Url "$org/$project/_apis/build/builds/$build_id`?api-version=7.1")
}

# The logs of a build (id and lineCount of each).
function get-ado-build-logs
{
    param([string] $org, [string] $project, [int] $build_id)
    return @((invoke-ado-rest -Method GET -Url "$org/$project/_apis/build/builds/$build_id/logs?api-version=7.1").value)
}

# Lines start_line..end_line of one build log.
function get-ado-build-log-lines
{
    param([string] $org, [string] $project, [int] $build_id, [int] $log_id, [int] $start_line, [int] $end_line)
    $response = invoke-ado-rest -Method GET -Url "$org/$project/_apis/build/builds/$build_id/logs/$log_id`?startLine=$start_line&endLine=$end_line&api-version=7.1" -Accept 'application/json' -AllowText
    if ($response -is [string])
    {
        return @($response -split "`r?`n")
    }
    else
    {
        return @($response.value)
    }
}


# --- PR changes ---------------------------------------------------------------------------------

# Create the dependency-update PR for an Azure repo. A PR that already exists for the branch (for
# example after a create that timed out but succeeded) is reused.
function create-pr-azure
{
    param(
        [string] $repo_name,
        [string] $new_branch_name,
        [hashtable] $description
    )
    $result = $null

    Write-Host "`nCreating PR"

    $azure_info = get-azure-org-project $repo_name
    $org = $azure_info.Organization
    $project = $azure_info.Project

    if (-not $description)
    {
        $description = build-propagation-description @()
    }
    else
    {
        # description provided
    }

    # Azure DevOps rejects a PR whose description exceeds 4000 characters; leave one character
    # of slack below the documented limit.
    $pr_body_obj = @{
        sourceRefName = "refs/heads/$new_branch_name"
        targetRefName = "refs/heads/master"
        title         = $description.PrTitle
        description   = (select-pr-body -description $description -max_length 3999)
    }
    $create_url = "$org/$project/_apis/git/repositories/$repo_name/pullrequests?api-version=7.1"
    try
    {
        $result = invoke-ado-rest -Method POST -Url $create_url -Body $pr_body_obj
        Write-Host "PR created successfully" -ForegroundColor Green
    }
    catch
    {
        $create_error = get-ado-error-message $_
        $existing_url = find-active-azure-pr -repo_name $repo_name -branch_name $new_branch_name
        $existing_id = get-azure-pr-id-from-url $existing_url
        if ($existing_id)
        {
            Write-Log WARN "PR creation for $repo_name reported '$create_error'; using the active PR $existing_url"
            $result = get-ado-pull-request -org_url $org -pr_id $existing_id
        }
        else
        {
            fail-with-status "Failed to create PR for repo ${repo_name}: $create_error"
        }
    }

    return $result
}


# Link the work item to the PR. Does nothing if the link already exists.
function link-work-item-to-pr-azure
{
    param(
        [int] $pr_id,
        [string] $org
    )

    Write-Host "Linking work item to PR (PR ID: $pr_id)"

    if(!$azure_work_item)
    {
        fail-with-status "Updating Azure repos requires providing a work item id. Provide work item id as: -azure_work_item [id]"
    }
    else
    {
        try
        {
            $pr = get-ado-pull-request -org_url $org -pr_id $pr_id
            $vstfs = "vstfs:///Git/PullRequestId/$($pr.repository.project.id)%2F$($pr.repository.id)%2F$pr_id"
            $work_item = invoke-ado-rest -Method GET -Url "$org/_apis/wit/workitems/$azure_work_item`?`$expand=relations&api-version=7.1"
            $linked = @($work_item.relations | Where-Object {
                $_.url -and [uri]::UnescapeDataString($_.url) -eq [uri]::UnescapeDataString($vstfs)
            }).Count -gt 0
            if ($linked)
            {
                Write-Host "Work item already linked" -ForegroundColor Green
            }
            else
            {
                $patch = '[{"op":"add","path":"/relations/-","value":{"rel":"ArtifactLink","url":"' + $vstfs + '","attributes":{"name":"Pull Request"}}}]'
                [void](invoke-ado-rest -Method PATCH -Url "$org/_apis/wit/workitems/$azure_work_item`?api-version=7.1" -BodyJson $patch -ContentType 'application/json-patch+json; charset=utf-8')
                Write-Host "Work item linked successfully" -ForegroundColor Green
            }
        }
        catch
        {
            $link_error = get-ado-error-message $_
            if ($link_error -match 'already exists')
            {
                Write-Host "Work item already linked" -ForegroundColor Green
            }
            else
            {
                fail-with-status "Failed to link work item to PR. Work item: $azure_work_item, PR ID: ${pr_id}: $link_error"
            }
        }
    }
}


# Approve the PR (vote 10 as the authenticated identity).
function approve-pr-azure
{
    param(
        [int] $pr_id,
        [string] $org
    )

    Write-Host "Approving PR"

    try
    {
        $user_id = get-ado-authenticated-user-id -org_url $org
        $pr = get-ado-pull-request -org_url $org -pr_id $pr_id
        $vote_url = "$org/_apis/git/repositories/$($pr.repository.id)/pullRequests/$pr_id/reviewers/$user_id`?api-version=7.1"
        [void](invoke-ado-rest -Method PUT -Url $vote_url -Body @{ vote = 10 })
        Write-Host "PR approved successfully" -ForegroundColor Green
    }
    catch
    {
        fail-with-status "Failed to approve PR ID: ${pr_id}: $(get-ado-error-message $_)"
    }
}


# Set the PR to squash-merge automatically (deleting the source branch) once policies pass.
function set-autocomplete-azure
{
    param(
        [int] $pr_id,
        [string] $org
    )

    Write-Host "Enabling PR to autocomplete"

    try
    {
        $user_id = get-ado-authenticated-user-id -org_url $org
        $pr = get-ado-pull-request -org_url $org -pr_id $pr_id
        $patch_url = "$org/_apis/git/repositories/$($pr.repository.id)/pullRequests/$pr_id`?api-version=7.1"
        $body = @{
            autoCompleteSetBy = @{ id = $user_id }
            completionOptions = @{ deleteSourceBranch = $true; mergeStrategy = 'squash' }
        }
        [void](invoke-ado-rest -Method PATCH -Url $patch_url -Body $body)
        Write-Host "Autocomplete enabled successfully" -ForegroundColor Green
    }
    catch
    {
        fail-with-status "Failed to set autocomplete for PR ID: ${pr_id}: $(get-ado-error-message $_)"
    }
}


# Arm a PR to merge on its own once policies pass: link the work item, approve, and set
# auto-complete. Safe to repeat for resumed, reopened, or AutoFix-updated PRs.
function arm-azure-pr
{
    param(
        [int] $pr_id,
        [string] $org
    )
    link-work-item-to-pr-azure $pr_id $org
    approve-pr-azure $pr_id $org
    set-autocomplete-azure $pr_id $org
}


# Create the dependency-update PR for an Azure repo and arm it to merge on its own, without
# waiting for it. Returns a descriptor: @{ Repo; Type='azure'; PrUrl; PrId; Org }.
function create-pr-azure-armed
{
    param(
        [string] $repo_name,
        [string] $new_branch_name,
        [hashtable] $description
    )

    $azure_info = get-azure-org-project $repo_name
    $org = $azure_info.Organization
    $project = $azure_info.Project

    $pr_info = create-pr-azure $repo_name $new_branch_name $description
    $pr_id = $pr_info.pullRequestId

    # Build PR URL from the response
    if($pr_info.repository -and $pr_info.repository.webUrl)
    {
        $pr_url = "$($pr_info.repository.webUrl)/pullrequest/$pr_id"
    }
    else
    {
        # Fallback: construct from known org/project/repo
        $pr_url = "$org/$project/_git/$repo_name/pullrequest/$pr_id"
    }

    # Update status with PR URL immediately so it shows even if later steps fail
    set-repo-status -repo_name $repo_name -status $script:STATUS_IN_PROGRESS -pr_url $pr_url

    arm-azure-pr $pr_id $org

    return @{ Repo = $repo_name; Type = 'azure'; PrUrl = $pr_url; PrId = $pr_id; Org = $org }
}


# Close/abandon an Azure PR, checking status first.
function close-pr-azure
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )

    $status = get-azure-pr-status -pr_url $pr_url -repo_name $repo_name
    $pr_id = get-azure-pr-id-from-url $pr_url
    if ($status -eq "completed")
    {
        Write-Host "Azure PR is already completed (merged), skipping abandon" -ForegroundColor Green
    }
    elseif ($status -eq "abandoned")
    {
        Write-Host "Azure PR is already abandoned, skipping" -ForegroundColor Gray
    }
    elseif (-not $pr_id)
    {
        Write-Host "Warning: Could not parse PR ID from URL: $pr_url" -ForegroundColor Yellow
    }
    else
    {
        Write-Host "Abandoning Azure PR: $pr_url" -ForegroundColor Yellow
        $azure_info = get-azure-org-project $repo_name
        try
        {
            $pr = get-ado-pull-request -org_url $azure_info.Organization -pr_id $pr_id
            $abandon_url = "$($azure_info.Organization)/_apis/git/repositories/$($pr.repository.id)/pullRequests/$pr_id`?api-version=7.1"
            [void](invoke-ado-rest -Method PATCH -Url $abandon_url -Body @{ status = 'abandoned' })
            Write-Host "Azure PR abandoned successfully" -ForegroundColor Green
        }
        catch
        {
            Write-Host "Warning: Failed to abandon Azure PR ID ${pr_id}: $(get-ado-error-message $_)" -ForegroundColor Yellow
        }
    }
}


# Reopen an abandoned Azure PR.
function reopen-pr-azure
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )

    $pr_id = get-azure-pr-id-from-url $pr_url
    if ($pr_id)
    {
        $azure_info = get-azure-org-project $repo_name
        Write-Host "Reactivating Azure PR $pr_id..." -ForegroundColor Cyan
        try
        {
            $pr = get-ado-pull-request -org_url $azure_info.Organization -pr_id $pr_id
            $patch_url = "$($azure_info.Organization)/_apis/git/repositories/$($pr.repository.id)/pullRequests/$pr_id`?api-version=7.1"
            [void](invoke-ado-rest -Method PATCH -Url $patch_url -Body @{ status = 'active' })
            Write-Host "Azure PR reactivated successfully" -ForegroundColor Green
        }
        catch
        {
            Write-Host "Warning: Failed to reactivate Azure PR ID ${pr_id}: $(get-ado-error-message $_)" -ForegroundColor Yellow
        }
    }
    else
    {
        Write-Host "Warning: Could not parse PR ID from URL: $pr_url" -ForegroundColor Yellow
    }
}


# --- Interactive monitoring ---------------------------------------------------------------------

# Monitor an existing Azure PR until completion.
function monitor-azure-pr
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )

    $pr_id = get-azure-pr-id-from-url $pr_url
    if ($pr_id)
    {
        $azure_info = get-azure-org-project $repo_name
        wait-until-complete-azure -pr_id $pr_id -org $azure_info.Organization -repo_name $repo_name -pr_url $pr_url
    }
    else
    {
        fail-with-status "Could not parse PR ID from URL: $pr_url"
    }
}


# Watch an Azure PR's policies until it completes, running AutoFix on build failures when enabled.
function wait-until-complete-azure
{
    param(
        [int] $pr_id,
        [string] $org,
        [string] $repo_name,
        [string] $pr_url
    )
    $done = $false
    $autofix_attempts = 0

    while (-not $done -and -not $global:propagation_cancelled)
    {
        Write-Host "Waiting for build to complete"
        Write-Host "`nWatching PR policies..."
        $success = watch-azure-pr-policies -pr_id $pr_id -org $org -poll_interval $global:poll_interval -timeout 120 -ShowBuildDetails -OnIteration { [void](show-propagation-status) }

        if(!$success)
        {
            # Policy watch reported failure - check if PR already completed
            $pr_info = get-pr-status-with-retry -pr_id $pr_id -org $org
            if($pr_info -and $pr_info.status -eq "completed")
            {
                Write-Host "PR completed successfully" -ForegroundColor Green
                $done = $true
            }
            else
            {
                # Wait for autocomplete (non-blocking policy may have failed while build passed)
                $max_wait = 120
                $waited = 0
                while($waited -lt $max_wait -and !$done)
                {
                    $cancelled = wait-or-cancel -seconds 5
                    if ($cancelled) { $global:propagation_cancelled = $true; break }
                    $waited += 5
                    $pr_check = get-pr-status-with-retry -pr_id $pr_id -org $org
                    if($pr_check -and $pr_check.status -eq "completed")
                    {
                        Write-Host "PR completed successfully" -ForegroundColor Green
                        $done = $true
                    }
                    else
                    {
                        # keep waiting
                    }
                }
            }
            if(!$done -and -not $global:propagation_cancelled)
            {
                # Check if a Build check actually failed (vs timeout or non-build policy failure)
                $has_build_failure = $false
                $recheck_data = get-policy-display-data -pr_id $pr_id -org $org -ShowBuildDetails
                if ($recheck_data -and $recheck_data.Checks)
                {
                    $failed_build_checks = @($recheck_data.Checks | Where-Object {
                        $_.Status -eq [PrCheckStatus]::Failed -and $_.Name -match "^Build"
                    })
                    $has_build_failure = $failed_build_checks.Count -gt 0
                }
                else
                {
                    # couldn't recheck
                }

                if ($has_build_failure -and $global:auto_fix -and $autofix_attempts -lt $global:MAX_AUTOFIX_ATTEMPTS)
                {
                    $autofix_attempts++
                    Write-Host "`n  AutoFix attempt $autofix_attempts of $global:MAX_AUTOFIX_ATTEMPTS" -ForegroundColor Magenta
                    Push-Location $repo_name
                    $branch_name = git rev-parse --abbrev-ref HEAD 2>$null
                    $fix_result = invoke-copilot-autofix -repo_name $repo_name -branch_name $branch_name -pr_url $pr_url
                    Pop-Location
                    if ($fix_result)
                    {
                        # A new push can reset votes, so re-arm before watching again.
                        Write-Host "  AutoFix pushed a fix, restarting watch..." -ForegroundColor Magenta
                        arm-azure-pr $pr_id $org
                    }
                    else
                    {
                        fail-with-status "PR $pr_id failed to complete. AutoFix could not resolve the build failure."
                    }
                }
                else
                {
                    if ($global:propagation_cancelled)
                    {
                        # User cancelled - just stop, don't close the PR
                        $done = $true
                    }
                    else
                    {
                        fail-with-status "PR $pr_id failed to complete. Check policy status above."
                    }
                }
            }
            else
            {
                # already done or cancelled
            }
        }
        else
        {
            # Verify PR is completed
            $pr_info = get-pr-status-with-retry -pr_id $pr_id -org $org
            if(-not $pr_info)
            {
                fail-with-status "Failed to get PR status for ID: $pr_id after retries"
            }
            else
            {
                if($pr_info.status -ne "completed")
                {
                    # PR policies passed but PR not yet merged - wait a bit for autocomplete
                    Write-Host "Waiting for PR to auto-complete..."
                    $max_wait = 60
                    $waited = 0
                    while($waited -lt $max_wait -and !$done)
                    {
                        $cancelled = wait-or-cancel -seconds 2
                        if ($cancelled) { $global:propagation_cancelled = $true; break }
                        $waited += 2
                        $pr_check = get-pr-status-with-retry -pr_id $pr_id -org $org
                        if($pr_check -and $pr_check.status -eq "completed")
                        {
                            Write-Host "PR completed successfully" -ForegroundColor Green
                            $done = $true
                        }
                        else
                        {
                            # keep waiting
                        }
                    }
                    if(!$done)
                    {
                        Write-Host "Warning: PR policies passed but PR status is: $($pr_info.status)" -ForegroundColor Yellow
                    }
                    else
                    {
                        # already logged success
                    }
                }
                else
                {
                    Write-Host "PR completed successfully" -ForegroundColor Green
                    $done = $true
                }
            }
        }
    }
}


# --- Pipeline polling ---------------------------------------------------------------------------

# Name a policy evaluation for display: the build or status check name when the policy has one,
# otherwise the policy type (e.g. "Required reviewers"). An expired build is marked as such.
function get-azure-policy-name
{
    param([object] $evaluation)
    $settings = $evaluation.configuration.settings
    $result = $evaluation.configuration.type.displayName
    if ($settings.displayName)
    {
        $result = $settings.displayName
    }
    elseif ($settings.defaultDisplayName)
    {
        $result = $settings.defaultDisplayName
    }
    elseif ($settings.statusName)
    {
        $result = (@($settings.statusGenre, $settings.statusName) | Where-Object { $_ }) -join '/'
    }
    else
    {
        # no specific name; the policy type describes it
    }
    if ($evaluation.context.isExpired)
    {
        $result += " (expired)"
    }
    else
    {
        # current
    }
    return $result
}

# Map a policy evaluation to a gate state for format-gate-summary. Only builds and external status
# checks actually run; every other policy (reviewers, comments, work items, merge strategy, ...)
# reports 'queued' or 'rejected' while it waits for people, so it is awaiting action until approved.
function get-azure-policy-gate-state
{
    param([object] $evaluation)
    $type_id = $evaluation.configuration.type.id
    $is_build = ($type_id -eq $script:ADO_BUILD_POLICY_TYPE_ID)

    if ($evaluation.status -eq 'approved')
    {
        $result = 'done'
    }
    elseif (-not $is_build -and $type_id -ne $script:ADO_STATUS_POLICY_TYPE_ID)
    {
        $result = 'awaiting-action'
    }
    elseif ($evaluation.status -eq 'running')
    {
        $result = 'running'
    }
    elseif ($evaluation.status -eq 'queued')
    {
        # An expired build has to be re-queued before the PR can complete.
        if ($evaluation.context.isExpired)
        {
            $result = 'awaiting-action'
        }
        else
        {
            $result = 'not-started'
        }
    }
    elseif ($is_build -and -not $evaluation.context.buildId)
    {
        # rejected or broken before any build ran
        $result = 'not-started'
    }
    else
    {
        # rejected or broken: the build or status check reported a failure
        $result = 'failed'
    }
    return $result
}

# Describe what an open PR is waiting on for the status table: its blocking policies (builds,
# reviewers, status checks, ...) by state, plus anything else that keeps it from merging. Never
# throws: the status table is informational and must not break the wait loop.
function get-azure-pr-progress
{
    param(
        [object] $pr,
        [string] $org
    )
    $notes = @()
    if ($pr.mergeStatus -in @('conflicts', 'failure', 'rejectedByPolicy'))
    {
        $notes += "merge status: $($pr.mergeStatus)"
    }
    if ($pr.isDraft)
    {
        $notes += "draft"
    }
    if (-not $pr.autoCompleteSetBy)
    {
        $notes += "auto-complete not set"
    }

    try
    {
        $evaluations = @(get-azure-pr-policy-evaluations -org $org -pr $pr | Where-Object { $_.configuration.isBlocking -and $_.status -ne 'notApplicable' })
        $gates = @($evaluations | ForEach-Object { @{ Name = (get-azure-policy-name $_); State = (get-azure-policy-gate-state $_) } })
        $result = format-gate-summary -gates $gates -notes $notes
    }
    catch
    {
        $result = (@("gate status unavailable: $(get-ado-error-message $_)") + $notes) -join "; "
    }
    return $result
}

# Poll an Azure PR once and classify it as 'merged', 'failed', or 'pending'. Auto-complete is armed
# and the bot self-approved, so the PR merges itself once policies pass and a human provides the
# required non-bot approval. Used by the scheduler to watch several PRs at once.
function poll-azure-pr-state
{
    param(
        [int] $pr_id,
        [string] $org,
        [string] $repo_name
    )

    $pr = get-pr-status-with-retry -pr_id $pr_id -org $org
    if ($pr -and $pr.status -eq "completed")
    {
        return 'merged'
    }
    if ($pr -and $pr.status -eq "abandoned")
    {
        Write-Log WARN "PR $pr_id ($repo_name) was abandoned before completing."
        return 'failed'
    }
    # The only reliable "this PR will never complete" signal is an explicit human reject vote (-10).
    # Policy/build evaluations are unreliable here: a freshly created PR shows many blocking policies
    # as 'rejected'/'queued' simply because builds are still running and approvals are still pending,
    # which is exactly what we are waiting for.
    if ($pr -and $pr.reviewers)
    {
        $rejected_by = @($pr.reviewers | Where-Object { $_.vote -eq -10 })
        if ($rejected_by.Count -gt 0)
        {
            $names = ($rejected_by | ForEach-Object { $_.displayName }) -join ', '
            Write-Log WARN "PR $pr_id ($repo_name) was rejected by: $names"
            return 'failed'
        }
    }
    $state = if ($pr) { $pr.status } else { "unknown" }
    if ($pr)
    {
        set-repo-details -repo_name $repo_name -details (get-azure-pr-progress -pr $pr -org $org)
    }
    else
    {
        set-repo-details -repo_name $repo_name -details "PR status unavailable; retrying on the next poll"
    }
    Write-Log INFO "Waiting for PR $pr_id ($repo_name) to complete (status: $state)..."
    return 'pending'
}
