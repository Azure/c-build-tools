# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Azure DevOps repository operations for propagate_updates.ps1
# Uses global: $azure_work_item

# Source dependencies
. "$PSScriptRoot\status_tracking.ps1"


# --- Direct Azure DevOps REST helpers ---------------------------------------------------------
# Azure DevOps operations call the REST API directly with the build service bearer token. Direct REST
# avoids the resource-area discovery (OPTIONS /_apis) that is intermittently HTTP 429 throttled on the
# huge msazure org (a direct authenticated GET returns 200 even while discovery returns 429).
function invoke-ado-rest
{
    param(
        [string] $Method,
        [string] $Url,
        $Body = $null,
        [string] $BodyJson = $null,
        [string] $ContentType = 'application/json',
        [int] $TimeoutSec = 0
    )
    $token = $env:SYSTEM_ACCESSTOKEN
    if ([string]::IsNullOrWhiteSpace($token))
    {
        fail-with-status "SYSTEM_ACCESSTOKEN is not set; cannot call the Azure DevOps REST API."
    }
    $headers = @{ Authorization = "Bearer $token" }
    # Always bound the wait: the Windows PowerShell default (0) waits forever on a request that is
    # never answered, silently stalling the whole run. A timeout throws, so callers' retries apply.
    # Writes get longer than reads: they are not retried, and a slow one may still succeed.
    if ($TimeoutSec -le 0)
    {
        $TimeoutSec = if ($Method -eq 'GET') { 60 } else { 300 }
    }
    $params = @{ Method = $Method; Uri = $Url; Headers = $headers; ContentType = $ContentType; TimeoutSec = $TimeoutSec }
    # PowerShell 7.4+ applies TimeoutSec only until the response starts; also bound a stalled body.
    # (Windows PowerShell already fails a body read that stalls for 300 s.)
    if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('OperationTimeoutSeconds'))
    {
        $params['OperationTimeoutSeconds'] = $TimeoutSec
    }
    if ($BodyJson) { $params['Body'] = $BodyJson }
    elseif ($null -ne $Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10) }
    return Invoke-RestMethod @params
}

# Resolve the authenticated identity (the build service) id, used as reviewer for self-vote and as
# autoCompleteSetBy when arming auto-complete.
function get-ado-authenticated-user-id
{
    param([string] $org_url)
    if ($global:_ado_user_id) { return $global:_ado_user_id }
    $cd = invoke-ado-rest -Method GET -Url "$org_url/_apis/connectionData?api-version=7.1-preview"
    $global:_ado_user_id = $cd.authenticatedUser.id
    return $global:_ado_user_id
}

# Fetch a pull request by id (org-scoped route, no project/repo needed). Returns the PR object,
# which includes repository.id and repository.project.id.
function get-ado-pull-request
{
    param([string] $org_url, [int] $pr_id)
    return invoke-ado-rest -Method GET -Url "$org_url/_apis/git/pullrequests/$pr_id`?api-version=7.1"
}

# get Azure DevOps organization and project from git remote URL
function get-azure-org-project
{
    param(
        [string] $repo_name
    )
    $result = $null

    Push-Location $repo_name
    $repo_url = git config --get remote.origin.url
    Pop-Location

    # Parse URL like https://msazure@dev.azure.com/msazure/One/_git/repo-name
    # or https://dev.azure.com/msazure/One/_git/repo-name
    if($repo_url -match "dev\.azure\.com/([^/]+)/([^/]+)/_git")
    {
        $org = $matches[1]
        $project = $matches[2]
        $result = @{
            Organization = "https://dev.azure.com/$org"
            Project = $project
        }
    }
    # Parse URL like https://msazure.visualstudio.com/DefaultCollection/One/_git/repo-name
    # or https://msazure.visualstudio.com/One/_git/repo-name
    elseif($repo_url -match "([^/]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git")
    {
        $org = $matches[1]
        $project = $matches[2]
        $result = @{
            Organization = "https://dev.azure.com/$org"
            Project = $project
        }
    }
    else
    {
        fail-with-status "Failed to parse Azure DevOps organization and project from remote URL: $repo_url"
    }

    return $result
}


# Get the status of an Azure PR ("completed", "abandoned", or "active") via REST.
function get-azure-pr-status
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )
    $result = "active"
    if ($pr_url -match "/pullrequest/(\d+)")
    {
        $pr_id = [int]$matches[1]
        $azure_info = get-azure-org-project $repo_name
        try
        {
            $pr = get-ado-pull-request -org_url $azure_info.Organization -pr_id $pr_id
            $result = $pr.status
        }
        catch
        {
            Write-Log WARN "Could not query status of PR ${pr_id}: $($_.Exception.Message)"
        }
    }
    return $result
}


# Close/abandon an Azure PR via REST, checking status first.
function close-pr-azure
{
    param(
        [string] $pr_url,
        [string] $repo_name
    )

    $status = get-azure-pr-status -pr_url $pr_url -repo_name $repo_name
    if ($status -eq "completed")
    {
        Write-Log INFO "Azure PR already completed (merged); not abandoning: $pr_url"
        return
    }
    if ($status -eq "abandoned")
    {
        Write-Log INFO "Azure PR already abandoned: $pr_url"
        return
    }
    if ($pr_url -notmatch "/pullrequest/(\d+)")
    {
        Write-Log WARN "Could not parse PR id from URL: $pr_url"
        return
    }

    $pr_id = [int]$matches[1]
    $azure_info = get-azure-org-project $repo_name
    try
    {
        $pr = get-ado-pull-request -org_url $azure_info.Organization -pr_id $pr_id
        $abandon_url = "$($azure_info.Organization)/_apis/git/repositories/$($pr.repository.id)/pullRequests/$pr_id`?api-version=7.1"
        [void](invoke-ado-rest -Method PATCH -Url $abandon_url -Body @{ status = 'abandoned' })
        Write-Log INFO "Azure PR abandoned: $pr_url"
    }
    catch
    {
        Write-Log WARN "Failed to abandon Azure PR ${pr_id}: $($_.Exception.Message)"
    }
}

# Create the dependency-update PR for an Azure repo via the Azure DevOps REST API.
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

    $pr_title = "[no begging] [autogenerated] update dependencies"
    $pr_body = "Propagating dependency updates"
    if ($description)
    {
        $pr_title = $description.PrTitle
        $pr_body = $description.PrBody
    }
    else
    {
        # no description, use defaults
    }

    # Azure DevOps rejects a PR whose description exceeds 4000 characters. Cap the body and
    # reserve room for the truncation marker so the final string never crosses the limit.
    # NOTE (under duress): capped at 3999 rather than 4000 because we can never fully trust
    # where Azure DevOps actually draws the line, so we leave one extra character of slack.
    $max_body_len = 3999
    if ($pr_body.Length -gt $max_body_len)
    {
        $suffix = "`n`n... (truncated)"
        $pr_body = $pr_body.Substring(0, $max_body_len - $suffix.Length) + $suffix
    }
    else
    {
        # body fits within limits
    }

    $pr_body_obj = @{
        sourceRefName = "refs/heads/$new_branch_name"
        targetRefName = "refs/heads/master"
        title         = $pr_title
        description   = $pr_body
    }
    $create_url = "$org/$project/_apis/git/repositories/$repo_name/pullrequests?api-version=7.1"
    try
    {
        $result = invoke-ado-rest -Method POST -Url $create_url -Body $pr_body_obj
        Write-Host "PR created successfully" -ForegroundColor Green
    }
    catch
    {
        # Existing PRs are already detected by create-repo-pr before reaching here.
        # If creation still fails, it's an unexpected error - fail immediately.
        fail-with-status "Failed to create PR for repo ${repo_name}: $($_.Exception.Message)"
    }

    return $result
}


# Link the work item to the PR via the Azure DevOps REST API.
function link-work-item-to-pr-azure
{
    param(
        [int] $pr_id,
        [string] $org,
        [string] $project
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
            $project_id = $pr.repository.project.id
            $repo_id = $pr.repository.id
            $vstfs = "vstfs:///Git/PullRequestId/$project_id%2F$repo_id%2F$pr_id"
            $patch = '[{"op":"add","path":"/relations/-","value":{"rel":"ArtifactLink","url":"' + $vstfs + '","attributes":{"name":"Pull Request"}}}]'
            $wit_url = "$org/_apis/wit/workitems/$azure_work_item`?api-version=7.1"
            [void](invoke-ado-rest -Method PATCH -Url $wit_url -BodyJson $patch -ContentType 'application/json-patch+json')
            Write-Host "Work item linked successfully" -ForegroundColor Green
        }
        catch
        {
            fail-with-status "Failed to link work item to PR. Work item: $azure_work_item, PR ID: ${pr_id}: $($_.Exception.Message)"
        }
    }
}


# Self-approve the PR (build account vote) via the Azure DevOps REST API.
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
        $repo_id = $pr.repository.id
        $vote_url = "$org/_apis/git/repositories/$repo_id/pullRequests/$pr_id/reviewers/$user_id`?api-version=7.1"
        [void](invoke-ado-rest -Method PUT -Url $vote_url -Body @{ vote = 10 })
        Write-Host "PR approved successfully" -ForegroundColor Green
    }
    catch
    {
        fail-with-status "Failed to approve PR ID: ${pr_id}: $($_.Exception.Message)"
    }
}


# Arm the PR to auto-complete once policies pass, via the Azure DevOps REST API.
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
        $repo_id = $pr.repository.id
        $patch_url = "$org/_apis/git/repositories/$repo_id/pullRequests/$pr_id`?api-version=7.1"
        $body = @{
            autoCompleteSetBy = @{ id = $user_id }
            completionOptions = @{ deleteSourceBranch = $true; mergeStrategy = 'squash' }
        }
        [void](invoke-ado-rest -Method PATCH -Url $patch_url -Body $body)
        Write-Host "Autocomplete enabled successfully" -ForegroundColor Green
    }
    catch
    {
        fail-with-status "Failed to set autocomplete for PR ID: ${pr_id}: $($_.Exception.Message)"
    }
}


# Fetch PR status with retries to handle transient API failures
function get-pr-status-with-retry
{
    param(
        [int] $pr_id,
        [string] $org,
        [int] $max_retries = 3,
        [int] $retry_delay = 5
    )
    $result = $null

    for ($attempt = 1; $attempt -le $max_retries; $attempt++)
    {
        try
        {
            $result = get-ado-pull-request -org_url $org -pr_id $pr_id
            break
        }
        catch
        {
            if ($attempt -lt $max_retries)
            {
                Write-Log INFO "PR $pr_id status check failed, retrying ($attempt/$max_retries): $($_.Exception.Message)"
                Start-Sleep -Seconds $retry_delay
            }
            else
            {
                Write-Log WARN "PR $pr_id status check failed $max_retries times; will retry on the next poll: $($_.Exception.Message)"
            }
        }
    }

    return $result
}

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
    $build_policy_type_id = '0609b952-1397-4640-95ec-e00a01b2c241'
    $status_policy_type_id = 'cbdc66da-9728-4af8-aada-9a5a32e4a226'
    $type_id = $evaluation.configuration.type.id
    $is_build = ($type_id -eq $build_policy_type_id)

    if ($evaluation.status -eq 'approved')
    {
        $result = 'done'
    }
    elseif (-not $is_build -and $type_id -ne $status_policy_type_id)
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
        $project_id = $pr.repository.project.id
        $artifact_id = "vstfs:///CodeReview/CodeReviewId/$project_id/$($pr.pullRequestId)"
        $url = "$org/$project_id/_apis/policy/evaluations?artifactId=$([uri]::EscapeDataString($artifact_id))&api-version=7.1-preview.1"
        $evaluations = @((invoke-ado-rest -Method GET -Url $url).value | Where-Object { $_.configuration.isBlocking -and $_.status -ne 'notApplicable' })
        $gates = @($evaluations | ForEach-Object { @{ Name = (get-azure-policy-name $_); State = (get-azure-policy-gate-state $_) } })
        $result = format-gate-summary -gates $gates -notes $notes
    }
    catch
    {
        $result = (@("gate status unavailable: $($_.Exception.Message)") + $notes) -join "; "
    }
    return $result
}

# Wait until the PR auto-completes, polling status via REST (no az; avoids discovery throttling).
# Auto-complete is already armed and the bot self-approved, so the PR merges itself once policies
# pass and a human provides the required non-bot approval.
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

    $pr = get-pr-status-with-retry -pr_id $pr_id -org $org -max_retries 3
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

# Create the dependency-update PR for an Azure repo and arm it to merge on its own (link work item,
# self-approve, set auto-complete) WITHOUT blocking. Returns a descriptor consumed by the
# scheduler: @{ Repo; Type='azure'; PrUrl; PrId; Org }.
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

    link-work-item-to-pr-azure $pr_id $org $project

    approve-pr-azure $pr_id $org

    set-autocomplete-azure $pr_id $org

    return @{ Repo = $repo_name; Type = 'azure'; PrUrl = $pr_url; PrId = $pr_id; Org = $org }
}
