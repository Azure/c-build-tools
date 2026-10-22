# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Fake Azure DevOps service for the end-to-end tests. run_propagation.ps1 dot-sources this file into the
# global scope of the propagation process, so both front ends share one in-memory service:
# - Invoke-RestMethod (here) serves the REST API on https://dev.azure.com and, in interactive runs,
#   files of the fake GitHub repositories on https://raw.githubusercontent.com;
# - global:az (fake_az.ps1) serves the Azure CLI commands of the original interactive scripts.
# Both versions call these by name, so the functions shadow the real cmdlet and CLI.
#
# Requests are checked the way Azure DevOps checks them:
# - the credential: the pipeline's SYSTEM_ACCESSTOKEN (build service), a token from the fake
#   'az account get-access-token' (the developer, WAM), or the developer's PAT;
# - an existing source branch, the 4000-character description limit, no duplicate active pull
#   request, and no duplicate work item link;
# - votes and auto-complete must be set as the caller.
# A pull request completes once it is armed (linked to a work item, approved and set to auto-complete
# by the same identity) and has then been read enough times; completing squash-merges it into the
# bare repository. Scenario settings in world.json can fail its build, reject it, revoke tokens, or
# fail some reads. Every action is appended to events.jsonl. The state is saved to ado_state.json,
# which a later run in the same world (-Resume) loads again.

$global:FakeAdoWorld = read-fake-json 'world.json'
$global:FakeAdoResourceId = '499b84ac-1321-427f-aa17-267ca6975798'

# Parsed JSON back to the mutable types the service uses: hashtables and ArrayLists.
function convert-fake-value
{
    param($value)
    if ($null -eq $value)
    {
        return $null
    }
    elseif ($value -is [System.Management.Automation.PSCustomObject])
    {
        $table = @{}
        foreach ($property in $value.PSObject.Properties)
        {
            $table[$property.Name] = convert-fake-value $property.Value
        }
        return $table
    }
    elseif ($value -is [System.Array])
    {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $value)
        {
            [void]$list.Add((convert-fake-value $item))
        }
        return ,$list
    }
    else
    {
        return $value
    }
}

function new-fake-ado-state
{
    $state = @{
        NextId = 1001
        Prs = @{}
        WorkItems = @{}
        Faults = (New-Object System.Collections.ArrayList)
        Tokens = (New-Object System.Collections.ArrayList)
        Writes = 0
        TokensRevoked = $false
        Az = @{ LoggedIn = [bool]$global:FakeAdoWorld.Az.LoggedIn; Pat = $null; Defaults = @{} }
    }
    foreach ($work_item in @($global:FakeAdoWorld.Ado.WorkItems | Where-Object { $_ }))
    {
        $state.WorkItems["$work_item"] = @{ Id = [int]$work_item; Rev = 1; Relations = (New-Object System.Collections.ArrayList) }
    }
    foreach ($fault in @($global:FakeAdoWorld.Ado.Faults | Where-Object { $_ }))
    {
        $errors = New-Object System.Collections.ArrayList
        foreach ($error_kind in @($fault.Errors))
        {
            [void]$errors.Add([string]$error_kind)
        }
        [void]$state.Faults.Add(@{ Repo = [string]$fault.Repo; AfterPolls = [int]$fault.AfterPolls; Errors = $errors })
    }
    return $state
}

if (Test-Path -LiteralPath (get-fake-path 'ado_state.json'))
{
    $global:FakeAdoState = convert-fake-value (read-fake-json 'ado_state.json')
}
else
{
    $global:FakeAdoState = new-fake-ado-state
}

# Between the runs of a scenario someone may queue the failed builds again: their pull requests
# start polling from scratch, and finish with the build outcome the world now configures.
if ($global:FakeAdoWorld.Ado.RequeueFailedBuilds)
{
    foreach ($fake_pr in @($global:FakeAdoState.Prs.Values | Where-Object { $_.Status -eq 'active' -and $_.BuildFailed }))
    {
        $fake_pr.BuildFailed = $false
        $fake_pr.Polls = 0
        add-fake-event @{ kind = 'ado.requeue'; repo = $fake_pr.Repo; id = $fake_pr.Id }
    }
    write-fake-json 'ado_state.json' $global:FakeAdoState
}
else
{
    # builds stay as they finished
}

function save-fake-ado-state
{
    write-fake-json 'ado_state.json' $global:FakeAdoState
}

# An error shaped like a failed Invoke-RestMethod call: Exception.Response carries the status code
# and headers, ErrorDetails the service's JSON message.
function new-fake-ado-error
{
    param(
        [int] $status,
        [string] $message,
        [string] $retry_after = $null
    )
    $headers = @{}
    if ($retry_after)
    {
        $headers['Retry-After'] = $retry_after
    }
    else
    {
        # no Retry-After header
    }
    $exception = New-Object System.Exception ("Response status code does not indicate success: $status. $message")
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $status; Headers = $headers })
    $exception | Add-Member -NotePropertyName FakeAdoError -NotePropertyValue $true
    $record = New-Object System.Management.Automation.ErrorRecord ($exception, 'FakeAzureDevOpsError', 'NotSpecified', $null)
    $record.ErrorDetails = New-Object System.Management.Automation.ErrorDetails (ConvertTo-Json -Compress -InputObject @{ message = $message; typeKey = 'FakeAzureDevOpsException' })
    return $record
}

# A request that never got a response, like a timeout or a dropped connection.
function new-fake-ado-timeout
{
    $exception = New-Object System.Net.WebException ('The operation has timed out.', [System.Net.WebExceptionStatus]::Timeout)
    $exception | Add-Member -NotePropertyName FakeAdoError -NotePropertyValue $true
    return $exception
}

# Hashtables to the PSCustomObjects a real response parses to.
function convert-fake-ado-response
{
    param($value)
    return (ConvertTo-Json -InputObject $value -Depth 30 | ConvertFrom-Json)
}

function get-fake-ado-repo
{
    param([string] $name_or_id)
    $result = $null
    foreach ($property in $global:FakeAdoWorld.Repos.PSObject.Properties)
    {
        if ($property.Value.Host -eq 'ado' -and ($property.Name -eq $name_or_id -or $property.Value.Id -eq $name_or_id))
        {
            $result = @{ Name = $property.Name; Id = $property.Value.Id; Bare = $property.Value.Bare }
        }
        else
        {
            # another repository
        }
    }
    return $result
}

function test-fake-ado-project
{
    param([string] $project)
    return ($project -eq $global:FakeAdoWorld.Ado.ProjectName -or $project -eq $global:FakeAdoWorld.Ado.ProjectId)
}

function get-fake-ado-setting
{
    param(
        $table,
        [string] $repo,
        $default
    )
    $value = $null
    if ($table)
    {
        $value = $table.$repo
    }
    else
    {
        # no per-repository settings
    }
    if ($null -eq $value)
    {
        $value = $default
    }
    else
    {
        # repository-specific setting
    }
    return $value
}

function get-fake-ado-user
{
    return @{ Id = $global:FakeAdoWorld.Ado.UserId; Name = $global:FakeAdoWorld.Ado.UserName }
}

# The identity behind a REST request's credential. Unknown, revoked or misdirected credentials get
# 401, like the real service.
function resolve-fake-ado-caller
{
    param($headers)
    $ado = $global:FakeAdoWorld.Ado
    $authorization = $null
    if ($headers)
    {
        $authorization = [string]$headers['Authorization']
    }
    else
    {
        # no headers
    }
    $reason = $null
    $result = $null
    if (-not $authorization)
    {
        $reason = 'anonymous'
    }
    elseif ($env:SYSTEM_ACCESSTOKEN -and $authorization -ceq "Bearer $($env:SYSTEM_ACCESSTOKEN)")
    {
        $result = @{ Kind = 'system'; Id = $ado.BotId; Name = $ado.BotName }
    }
    elseif ($authorization -cmatch '^Bearer (.+)$')
    {
        $token_value = $Matches[1]
        $token = @($global:FakeAdoState.Tokens | Where-Object { $_.Token -ceq $token_value }) | Select-Object -First 1
        if (-not $token)
        {
            $reason = 'unknown-token'
        }
        elseif ($token.Revoked)
        {
            $reason = 'revoked-token'
        }
        elseif ($token.Resource -ne $global:FakeAdoResourceId)
        {
            $reason = 'wrong-resource'
        }
        elseif ($token.Tenant -ne $ado.TenantId)
        {
            $reason = 'wrong-tenant'
        }
        else
        {
            $user = get-fake-ado-user
            $result = @{ Kind = 'wam'; Id = $user.Id; Name = $user.Name }
        }
    }
    elseif ($authorization -cmatch '^Basic (.+)$')
    {
        $decoded = ''
        try { $decoded = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($Matches[1])) } catch { $decoded = '' }
        if ($ado.Pat -and $decoded -ceq ":$($ado.Pat)")
        {
            $user = get-fake-ado-user
            $result = @{ Kind = 'pat'; Id = $user.Id; Name = $user.Name }
        }
        else
        {
            $reason = 'bad-pat'
        }
    }
    else
    {
        $reason = 'unsupported-credential'
    }
    if (-not $result)
    {
        throw (new-fake-ado-unauthorized $reason)
    }
    else
    {
        return $result
    }
}

function new-fake-ado-unauthorized
{
    param([string] $reason)
    add-fake-event @{ kind = 'ado.unauthorized'; reason = $reason }
    return (new-fake-ado-error 401 'TF400813: The user is not authorized to access this resource.')
}

# Count a write. After the configured number of writes every issued WAM token is revoked once, so
# the next request with one must sign in again.
function register-fake-ado-write
{
    $state = $global:FakeAdoState
    $state.Writes = [int]$state.Writes + 1
    $limit = [int]$global:FakeAdoWorld.Ado.RevokeTokensAfterWrites
    if ($limit -gt 0 -and -not $state.TokensRevoked -and $state.Writes -ge $limit)
    {
        foreach ($token in $state.Tokens)
        {
            $token.Revoked = $true
        }
        $state.TokensRevoked = $true
        add-fake-event @{ kind = 'ado.tokens-revoked'; writes = $state.Writes; tokens = $state.Tokens.Count }
    }
    else
    {
        # tokens stay valid
    }
}

function get-fake-ado-query
{
    param([string] $query)
    $result = @{}
    foreach ($pair in ($query.TrimStart('?') -split '&'))
    {
        if ($pair)
        {
            $parts = $pair -split '=', 2
            $value = ''
            if ($parts.Count -gt 1)
            {
                $value = [System.Uri]::UnescapeDataString($parts[1])
            }
            else
            {
                # flag without a value
            }
            $result[[System.Uri]::UnescapeDataString($parts[0])] = $value
        }
        else
        {
            # empty segment
        }
    }
    return $result
}

# Decode a request body the way the service sees it. Windows PowerShell sends a string body as
# ISO-8859-1 unless the content type names a charset, while Azure DevOps reads UTF-8.
function get-fake-ado-body
{
    param(
        $body,
        [string] $content_type
    )
    $result = $null
    if ($null -ne $body)
    {
        if ($body -is [byte[]])
        {
            $text = [System.Text.Encoding]::UTF8.GetString($body)
        }
        else
        {
            $text = [string]$body
            if ($PSVersionTable.PSVersion.Major -le 5 -and $content_type -notmatch 'charset=')
            {
                $text = [System.Text.Encoding]::UTF8.GetString([System.Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($text))
            }
            else
            {
                # sent as UTF-8
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($text))
        {
            $result = $text | ConvertFrom-Json
        }
        else
        {
            # empty body
        }
    }
    else
    {
        # no body
    }
    return $result
}

function get-fake-ado-artifact-url
{
    param([hashtable] $pr)
    $repo = get-fake-ado-repo $pr.Repo
    return ("vstfs:///Git/PullRequestId/{0}%2F{1}%2F{2}" -f $global:FakeAdoWorld.Ado.ProjectId, $repo.Id, $pr.Id)
}

function test-fake-ado-pr-linked
{
    param([hashtable] $pr)
    $artifact = [System.Uri]::UnescapeDataString((get-fake-ado-artifact-url $pr))
    $result = $false
    foreach ($work_item in $global:FakeAdoState.WorkItems.Values)
    {
        foreach ($relation in $work_item.Relations)
        {
            if ([System.Uri]::UnescapeDataString($relation.Url) -eq $artifact)
            {
                $result = $true
            }
            else
            {
                # another link
            }
        }
    }
    return $result
}

# Armed: linked to a work item, and approved and set to auto-complete by the same identity.
function test-fake-ado-pr-armed
{
    param([hashtable] $pr)
    $setter = $pr.AutoCompleteSetBy
    $approved = $setter -and (@($pr.Reviewers | Where-Object { $_.Id -eq $setter -and [int]$_.Vote -eq 10 }).Count -gt 0)
    return ($approved -and (test-fake-ado-pr-linked $pr))
}

function get-fake-ado-build-id
{
    param([hashtable] $pr)
    return (5000 + [int]$pr.Id)
}

# The build and its policy follow the pull request: running until it completes, or failed when the
# scenario fails the repository's build.
function get-fake-ado-build-state
{
    param([hashtable] $pr)
    if ($pr.Status -eq 'completed')
    {
        return 'succeeded'
    }
    elseif ($pr.BuildFailed)
    {
        return 'failed'
    }
    else
    {
        return 'running'
    }
}

function get-fake-ado-pr-view
{
    param(
        [hashtable] $pr,
        [switch] $ForList
    )
    $ado = $global:FakeAdoWorld.Ado
    $repo = get-fake-ado-repo $pr.Repo
    $repository = @{
        id = $repo.Id
        name = $repo.Name
        url = "https://dev.azure.com/msazure/$($ado.ProjectId)/_apis/git/repositories/$($repo.Id)"
        project = @{ id = $ado.ProjectId; name = $ado.ProjectName; url = "https://dev.azure.com/msazure/_apis/projects/$($ado.ProjectId)"; state = 'wellFormed' }
    }
    if (-not $ForList)
    {
        # Like the real service, single pull requests carry the web URL; list items do not.
        $repository['webUrl'] = "https://dev.azure.com/msazure/$($ado.ProjectName)/_git/$($repo.Name)"
    }
    else
    {
        # list item
    }
    $view = @{
        repository = $repository
        pullRequestId = [int]$pr.Id
        codeReviewId = [int]$pr.Id
        status = $pr.Status
        createdBy = @{ id = $pr.CreatedBy.Id; displayName = $pr.CreatedBy.Name }
        title = $pr.Title
        description = $pr.Description
        sourceRefName = $pr.SourceRefName
        targetRefName = $pr.TargetRefName
        mergeStatus = 'succeeded'
        isDraft = $false
        reviewers = @($pr.Reviewers | ForEach-Object { @{ id = $_.Id; displayName = $_.DisplayName; vote = [int]$_.Vote; isRequired = $false } })
        url = "https://dev.azure.com/msazure/$($ado.ProjectId)/_apis/git/repositories/$($repo.Id)/pullRequests/$($pr.Id)"
        lastMergeSourceCommit = @{ commitId = $pr.HeadCommit }
    }
    if ($pr.AutoCompleteSetBy)
    {
        $setter_name = $pr.AutoCompleteSetBy
        $setter = @($pr.Reviewers | Where-Object { $_.Id -eq $pr.AutoCompleteSetBy }) | Select-Object -First 1
        if ($setter)
        {
            $setter_name = $setter.DisplayName
        }
        else
        {
            # not a reviewer
        }
        $view['autoCompleteSetBy'] = @{ id = $pr.AutoCompleteSetBy; displayName = $setter_name }
    }
    else
    {
        # auto-complete not set
    }
    if ($pr.CompletionOptions)
    {
        $view['completionOptions'] = $pr.CompletionOptions
    }
    else
    {
        # no completion options
    }
    if ($pr.MergeCommit)
    {
        $view['lastMergeCommit'] = @{ commitId = $pr.MergeCommit }
    }
    else
    {
        # not merged
    }
    return $view
}

function get-fake-ado-pr-by-id
{
    param([string] $id)
    $pr = $global:FakeAdoState.Prs["$id"]
    if (-not $pr)
    {
        throw (new-fake-ado-error 404 "TF401180: The requested pull request was not found.")
    }
    else
    {
        return $pr
    }
}

function new-fake-ado-pr
{
    param(
        [hashtable] $caller,
        [hashtable] $repo,
        $request
    )
    if (-not $request)
    {
        throw (new-fake-ado-error 400 'The request body is missing.')
    }
    else
    {
        # body present
    }
    $source = [string]$request.sourceRefName
    $target = [string]$request.targetRefName
    $title = [string]$request.title
    $description = [string]$request.description
    if ($target -ne 'refs/heads/master' -or $source -notmatch '^refs/heads/(.+)$')
    {
        throw (new-fake-ado-error 400 "TF401398: The pull request cannot be activated because the source and/or the target branch no longer exists, or the requested refs are not branches.")
    }
    else
    {
        # branch refs
    }
    $branch = $Matches[1]
    $head = get-fake-revision $repo.Bare "refs/heads/$branch"
    if (-not $head)
    {
        throw (new-fake-ado-error 400 "TF401398: The pull request cannot be activated because the source and/or the target branch no longer exists, or the requested refs are not branches.")
    }
    else
    {
        # source branch was pushed
    }
    foreach ($existing in $global:FakeAdoState.Prs.Values)
    {
        if ($existing.Repo -eq $repo.Name -and $existing.Status -eq 'active' -and $existing.SourceRefName -eq $source -and $existing.TargetRefName -eq $target)
        {
            throw (new-fake-ado-error 409 'TF401179: An active pull request for the source and target branch already exists.')
        }
        else
        {
            # no conflict
        }
    }
    if ($description.Length -gt 4000)
    {
        throw (new-fake-ado-error 400 "The pull request description is $($description.Length) characters; the maximum is 4000.")
    }
    else
    {
        # description fits
    }
    if ($title.Length -gt 400)
    {
        throw (new-fake-ado-error 400 "The pull request title is $($title.Length) characters; the maximum is 400.")
    }
    else
    {
        # title fits
    }

    $id = [int]$global:FakeAdoState.NextId
    $global:FakeAdoState.NextId = $id + 1
    $pr = @{
        Id = $id
        Repo = $repo.Name
        Title = $title
        Description = $description
        SourceRefName = $source
        TargetRefName = $target
        Branch = $branch
        Status = 'active'
        Reviewers = (New-Object System.Collections.ArrayList)
        AutoCompleteSetBy = $null
        CompletionOptions = $null
        Polls = 0
        HeadCommit = $head
        MergeCommit = $null
        Rejected = $false
        BuildFailed = $false
        CreatedBy = @{ Id = $caller.Id; Name = $caller.Name }
    }
    $global:FakeAdoState.Prs["$id"] = $pr
    register-fake-ado-write
    add-fake-event @{ kind = 'ado.create'; repo = $repo.Name; id = $id; title = $title; description = $description; source = $source; branch = $branch; headCommit = $head; headMessage = (get-fake-commit-message $repo.Bare $head); auth = $caller.Kind; actor = $caller.Id }
    save-fake-ado-state
    return (get-fake-ado-pr-view $pr)
}

function complete-fake-ado-pr
{
    param([hashtable] $pr)
    $repo = get-fake-ado-repo $pr.Repo
    $delete_branch = $false
    if ($pr.CompletionOptions -and $pr.CompletionOptions.deleteSourceBranch)
    {
        $delete_branch = $true
    }
    else
    {
        # keep the source branch
    }
    $head = get-fake-revision $repo.Bare "refs/heads/$($pr.Branch)"
    $commit = merge-fake-branch -bare $repo.Bare -branch $pr.Branch -message ("Merged PR {0}: {1}" -f $pr.Id, $pr.Title) -delete_branch $delete_branch
    $pr.Status = 'completed'
    $pr.BuildFailed = $false
    $pr.MergeCommit = $commit
    add-fake-event @{ kind = 'ado.merged'; repo = $pr.Repo; id = $pr.Id; commit = $commit; head = $head; deleteSourceBranch = $delete_branch }
}

# Read a pull request. Once it is armed, each read is a status poll: scenario faults fail some reads,
# a rejecting reviewer votes -10 on the first poll, and after the configured number of polls its build
# finishes: the pull request completes, or stays active with a failed build.
function get-fake-ado-pr
{
    param([string] $id)
    $pr = get-fake-ado-pr-by-id $id
    if ($pr.Status -eq 'active' -and (test-fake-ado-pr-armed $pr))
    {
        foreach ($fault in $global:FakeAdoState.Faults)
        {
            if ($fault.Repo -eq $pr.Repo -and [int]$fault.AfterPolls -eq [int]$pr.Polls -and $fault.Errors.Count -gt 0)
            {
                $kind = $fault.Errors[0]
                $fault.Errors.RemoveAt(0)
                add-fake-event @{ kind = 'fault'; service = 'ado'; repo = $pr.Repo; id = $pr.Id; error = $kind; afterPolls = $pr.Polls }
                save-fake-ado-state
                if ($kind -eq 'timeout')
                {
                    throw (new-fake-ado-timeout)
                }
                elseif ($kind -eq '429')
                {
                    throw (new-fake-ado-error 429 'TF400733: The request has been throttled.' '1')
                }
                else
                {
                    throw (new-fake-ado-error ([int]$kind) 'The service is temporarily unavailable.')
                }
            }
            else
            {
                # fault not due yet
            }
        }

        $pr.Polls = [int]$pr.Polls + 1
        $ado = $global:FakeAdoWorld.Ado
        if (@($ado.Reject) -contains $pr.Repo)
        {
            if (-not $pr.Rejected)
            {
                [void]$pr.Reviewers.Add(@{ Id = $ado.ReviewerId; DisplayName = 'Jane Reviewer'; Vote = -10 })
                $pr.Rejected = $true
                add-fake-event @{ kind = 'ado.reject'; repo = $pr.Repo; id = $pr.Id }
            }
            else
            {
                # already rejected
            }
        }
        elseif ($pr.Polls -gt [int](get-fake-ado-setting $ado.CompleteAfter $pr.Repo $ado.DefaultCompleteAfter))
        {
            if ((get-fake-ado-setting $ado.BuildOutcome $pr.Repo 'pass') -eq 'pass')
            {
                complete-fake-ado-pr $pr
            }
            elseif (-not $pr.BuildFailed)
            {
                $pr.BuildFailed = $true
                add-fake-event @{ kind = 'ado.build-failed'; repo = $pr.Repo; id = $pr.Id }
            }
            else
            {
                # the build already failed
            }
        }
        else
        {
            # still waiting for its builds and reviewers
        }
        save-fake-ado-state
    }
    else
    {
        # not armed yet, or no longer active
    }
    return (get-fake-ado-pr-view $pr)
}

function get-fake-ado-pr-list
{
    param(
        [hashtable] $repo,
        [string] $status,
        [string] $source,
        [string] $target,
        [int] $top
    )
    $items = @($global:FakeAdoState.Prs.Values | Where-Object {
        $_.Repo -eq $repo.Name -and ($status -eq 'all' -or $_.Status -eq $status) -and
        (-not $source -or $_.SourceRefName -eq $source) -and
        (-not $target -or $_.TargetRefName -eq $target)
    } | Sort-Object -Property { [int]$_.Id } -Descending)
    if ($top -gt 0)
    {
        $items = @($items | Select-Object -First $top)
    }
    else
    {
        # every match
    }
    return @($items | ForEach-Object { get-fake-ado-pr-view $_ -ForList })
}

function set-fake-ado-vote
{
    param(
        [hashtable] $caller,
        [hashtable] $pr,
        [string] $user,
        [int] $vote
    )
    if ($user -ne $caller.Id)
    {
        add-fake-event @{ kind = 'ado.unexpected'; reason = 'vote for another identity'; repo = $pr.Repo; id = $pr.Id; user = $user; caller = $caller.Id }
        throw (new-fake-ado-error 403 'TF401027: You need the Git "PullRequestContribute" permission to vote on behalf of another identity.')
    }
    else
    {
        # voting as the caller
    }
    $existing = @($pr.Reviewers | Where-Object { $_.Id -eq $user }) | Select-Object -First 1
    if ($existing)
    {
        $existing.Vote = $vote
    }
    else
    {
        [void]$pr.Reviewers.Add(@{ Id = $user; DisplayName = $caller.Name; Vote = $vote })
    }
    register-fake-ado-write
    add-fake-event @{ kind = 'ado.vote'; repo = $pr.Repo; id = $pr.Id; user = $user; vote = $vote; auth = $caller.Kind; actor = $caller.Id }
    save-fake-ado-state
    return @{ id = $user; displayName = $caller.Name; vote = $vote }
}

# Change a pull request's status, or set it to complete on its own (as the caller).
function update-fake-ado-pr
{
    param(
        [hashtable] $caller,
        [hashtable] $pr,
        [string] $status,
        [string] $auto_complete_set_by,
        $completion_options
    )
    if ($status)
    {
        if ($status -eq 'abandoned' -and $pr.Status -eq 'active')
        {
            $pr.Status = 'abandoned'
            register-fake-ado-write
            add-fake-event @{ kind = 'ado.abandon'; repo = $pr.Repo; id = $pr.Id; auth = $caller.Kind; actor = $caller.Id }
        }
        elseif ($status -eq 'active' -and $pr.Status -eq 'abandoned')
        {
            $pr.Status = 'active'
            register-fake-ado-write
            add-fake-event @{ kind = 'ado.reopen'; repo = $pr.Repo; id = $pr.Id; auth = $caller.Kind; actor = $caller.Id }
        }
        else
        {
            throw (new-fake-ado-error 400 "TF401181: The pull request cannot be changed from $($pr.Status) to $status.")
        }
    }
    else
    {
        # no status change
    }
    if ($auto_complete_set_by -or $completion_options)
    {
        if ($auto_complete_set_by)
        {
            if ($auto_complete_set_by -ne $caller.Id)
            {
                add-fake-event @{ kind = 'ado.unexpected'; reason = 'auto-complete for another identity'; repo = $pr.Repo; id = $pr.Id; setBy = $auto_complete_set_by; caller = $caller.Id }
                throw (new-fake-ado-error 403 'TF401027: Auto-complete can only be set by the caller.')
            }
            else
            {
                $pr.AutoCompleteSetBy = $auto_complete_set_by
            }
        }
        else
        {
            # completion options only
        }
        if ($completion_options)
        {
            $pr.CompletionOptions = @{ mergeStrategy = [string]$completion_options.mergeStrategy; deleteSourceBranch = [bool]$completion_options.deleteSourceBranch }
        }
        else
        {
            # auto-complete identity only
        }
        register-fake-ado-write
        add-fake-event @{ kind = 'ado.autocomplete'; repo = $pr.Repo; id = $pr.Id; by = $pr.AutoCompleteSetBy; mergeStrategy = $pr.CompletionOptions.mergeStrategy; deleteSourceBranch = $pr.CompletionOptions.deleteSourceBranch; auth = $caller.Kind; actor = $caller.Id }
    }
    else
    {
        # no auto-complete change
    }
    save-fake-ado-state
    return (get-fake-ado-pr-view $pr)
}

function get-fake-ado-work-item-by-id
{
    param([string] $id)
    $work_item = $global:FakeAdoState.WorkItems["$id"]
    if (-not $work_item)
    {
        throw (new-fake-ado-error 404 "TF401232: Work item $id does not exist, or you do not have permissions to read it.")
    }
    else
    {
        return $work_item
    }
}

function get-fake-ado-work-item-view
{
    param([hashtable] $work_item)
    $view = @{
        id = [int]$work_item.Id
        rev = [int]$work_item.Rev
        fields = @{ 'System.Title' = 'Fake propagation work item'; 'System.WorkItemType' = 'Task' }
        url = "https://dev.azure.com/msazure/_apis/wit/workItems/$($work_item.Id)"
    }
    if ($work_item.Relations.Count -gt 0)
    {
        $view['relations'] = @($work_item.Relations | ForEach-Object { @{ rel = $_.Rel; url = $_.Url; attributes = @{ name = $_.Name } } })
    }
    else
    {
        # Azure DevOps omits relations when there are none
    }
    return $view
}

# Add a link to a work item. A link that already exists is rejected, as Azure DevOps does.
function add-fake-ado-work-item-link
{
    param(
        [hashtable] $caller,
        [hashtable] $work_item,
        [string] $rel,
        [string] $url,
        [string] $name
    )
    foreach ($relation in $work_item.Relations)
    {
        if ($relation.Rel -eq $rel -and [System.Uri]::UnescapeDataString($relation.Url) -eq [System.Uri]::UnescapeDataString($url))
        {
            throw (new-fake-ado-error 400 'TF201035: The relation already exists.')
        }
        else
        {
            # a different relation
        }
    }
    [void]$work_item.Relations.Add(@{ Rel = $rel; Url = $url; Name = $name })
    $work_item.Rev = [int]$work_item.Rev + 1
    register-fake-ado-write
    add-fake-event @{ kind = 'ado.link'; workItem = $work_item.Id; rel = $rel; url = $url; auth = $caller.Kind; actor = $caller.Id }
    save-fake-ado-state
}

function update-fake-ado-work-item
{
    param(
        [hashtable] $caller,
        [hashtable] $work_item,
        $operations,
        [string] $content_type
    )
    if ($content_type -notmatch '^application/json-patch\+json')
    {
        throw (new-fake-ado-error 415 "Work item updates must use application/json-patch+json, not $content_type.")
    }
    else
    {
        # JSON patch
    }
    foreach ($operation in $operations)
    {
        if ($operation.op -eq 'add' -and $operation.path -eq '/relations/-')
        {
            add-fake-ado-work-item-link -caller $caller -work_item $work_item -rel ([string]$operation.value.rel) -url ([string]$operation.value.url) -name ([string]$operation.value.attributes.name)
        }
        else
        {
            add-fake-event @{ kind = 'ado.unexpected'; reason = 'unsupported work item operation'; operation = $operation }
            throw (new-fake-ado-error 400 "Unsupported work item operation $($operation.op) $($operation.path).")
        }
    }
    return (get-fake-ado-work-item-view $work_item)
}

# The pull request's policy evaluations: one blocking build policy that follows its build.
function get-fake-ado-pr-evaluations
{
    param([hashtable] $pr)
    $ado = $global:FakeAdoWorld.Ado
    $state = get-fake-ado-build-state $pr
    $status = switch ($state) { 'succeeded' { 'approved' } 'failed' { 'rejected' } default { 'running' } }
    add-fake-event @{ kind = 'ado.observed'; source = 'evaluations'; repo = $pr.Repo; id = $pr.Id; status = $status }
    $evaluation = @{
        evaluationId = [guid]::NewGuid().ToString()
        artifactId = "vstfs:///CodeReview/CodeReviewId/$($ado.ProjectId)/$($pr.Id)"
        status = $status
        configuration = @{
            isEnabled = $true
            isBlocking = $true
            type = @{ id = '0609b952-1397-4640-95ec-e00a01b2c241'; displayName = 'Build' }
            settings = @{ displayName = 'Fake PR gate'; buildDefinitionId = 1; scope = @(@{ repositoryId = (get-fake-ado-repo $pr.Repo).Id; refName = 'refs/heads/master'; matchKind = 'Exact' }) }
        }
        context = @{ buildId = (get-fake-ado-build-id $pr); isExpired = $false }
    }
    return @($evaluation)
}

function get-fake-ado-evaluations
{
    param([hashtable] $query)
    $artifact = $query['artifactId']
    if ($artifact -notmatch '^vstfs:///CodeReview/CodeReviewId/(?<project>[^/]+)/(?<id>\d+)$' -or -not (test-fake-ado-project $Matches['project']))
    {
        add-fake-event @{ kind = 'ado.unexpected'; reason = 'unexpected policy artifact'; artifact = $artifact }
        throw (new-fake-ado-error 400 "Unexpected artifactId $artifact.")
    }
    else
    {
        # pull request artifact
    }
    $evaluations = @(get-fake-ado-pr-evaluations (get-fake-ado-pr-by-id $Matches['id']))
    return @{ value = $evaluations; count = $evaluations.Count }
}

# A build's timeline: one job that follows the pull request's build.
function get-fake-ado-timeline
{
    param([int] $build_id)
    $pr = @($global:FakeAdoState.Prs.Values | Where-Object { (get-fake-ado-build-id $_) -eq $build_id }) | Select-Object -First 1
    if (-not $pr)
    {
        throw (new-fake-ado-error 404 "TF215016: The requested build $build_id could not be found.")
    }
    else
    {
        # the pull request's build
    }
    $state = get-fake-ado-build-state $pr
    add-fake-event @{ kind = 'ado.observed'; source = 'timeline'; repo = $pr.Repo; id = $pr.Id; status = $state }
    $job_state = 'inProgress'
    $job_result = $null
    $finish = $null
    if ($state -ne 'running')
    {
        $job_state = 'completed'
        $job_result = $state
        $finish = '2026-01-01T00:10:00Z'
    }
    else
    {
        # still running
    }
    $stage_id = [guid]::NewGuid().ToString()
    $records = @(
        @{ id = $stage_id; parentId = $null; type = 'Stage'; name = 'Build'; state = $job_state; result = $job_result; startTime = '2026-01-01T00:00:00Z'; finishTime = $finish },
        @{ id = [guid]::NewGuid().ToString(); parentId = $stage_id; type = 'Job'; name = 'Build and run tests'; state = $job_state; result = $job_result; startTime = '2026-01-01T00:00:00Z'; finishTime = $finish }
    )
    return @{ records = $records; id = [guid]::NewGuid().ToString(); changeId = 1 }
}

# A file of a fake GitHub repository, as https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>
# serves it. Invoke-RestMethod parses JSON content.
function get-fake-raw-github-file
{
    param([string] $uri)
    $parsed = [System.Uri]$uri
    $segments = @($parsed.AbsolutePath.TrimStart('/') -split '/')
    $found = $null
    if ($segments.Count -ge 4)
    {
        $slug = "$($segments[0])/$($segments[1])"
        $ref = $segments[2]
        $file = ($segments | Select-Object -Skip 3) -join '/'
        foreach ($property in $global:FakeAdoWorld.Repos.PSObject.Properties)
        {
            if ($property.Value.Host -eq 'github' -and $property.Value.Slug -eq $slug)
            {
                $show = invoke-fake-git -git_args @("--git-dir=$($property.Value.Bare)", 'show', "${ref}:$file") -AllowFail
                if ($show.ExitCode -eq 0)
                {
                    $found = $show.StdOut
                }
                else
                {
                    # no such file at that ref
                }
            }
            else
            {
                # another repository
            }
        }
    }
    else
    {
        # not a raw file URL
    }
    add-fake-event @{ kind = 'web.raw'; url = $uri; found = ($null -ne $found) }
    if ($null -eq $found)
    {
        throw (new-fake-ado-error 404 '404: Not Found')
    }
    else
    {
        try
        {
            return ($found | ConvertFrom-Json)
        }
        catch
        {
            return $found
        }
    }
}

function invoke-fake-ado-request
{
    param(
        [string] $method,
        [string] $uri,
        $headers,
        $body,
        [string] $content_type
    )
    $method = $method.ToUpperInvariant()
    $parsed = $null
    try
    {
        $parsed = [System.Uri]$uri
    }
    catch
    {
        $parsed = $null
    }
    if ($parsed -and $parsed.Host -eq 'raw.githubusercontent.com' -and $method -eq 'GET' -and $global:FakeAdoWorld.Gh.Interactive)
    {
        # Interactive runs read the known dependency graph from c-build-tools; -Pipeline never does.
        return (get-fake-raw-github-file $uri)
    }
    elseif (-not $parsed -or $parsed.Host -ne 'dev.azure.com')
    {
        add-fake-event @{ kind = 'ado.unexpected'; reason = 'only https://dev.azure.com (and, for interactive runs, raw GitHub files) is served'; method = $method; url = $uri }
        throw (new-fake-ado-error 404 "The fake services do not serve $uri.")
    }
    else
    {
        # Azure DevOps
    }
    add-fake-event @{ kind = 'ado.call'; method = $method; url = $uri }
    $caller = resolve-fake-ado-caller $headers

    $path = $parsed.AbsolutePath.TrimEnd('/')
    $query = get-fake-ado-query $parsed.Query
    $request = get-fake-ado-body -body $body -content_type $content_type
    $response = $null
    if ($method -eq 'GET' -and $path -match '^/msazure/_apis/connectionData$')
    {
        $identity = @{ id = $caller.Id; descriptor = "fake.$($caller.Kind)"; providerDisplayName = $caller.Name; isActive = $true }
        $response = @{ authenticatedUser = $identity; authorizedUser = $identity; instanceId = $global:FakeAdoWorld.Ado.InstanceId }
    }
    elseif ($path -match '^/msazure/(?<project>[^/]+)/_apis/git/repositories/(?<repo>[^/]+)/pullrequests$' -and ($method -eq 'GET' -or $method -eq 'POST'))
    {
        $repo = get-fake-ado-repo $Matches['repo']
        if (-not $repo -or -not (test-fake-ado-project $Matches['project']))
        {
            throw (new-fake-ado-error 404 "TF401019: The Git repository with name or identifier $($Matches['repo']) does not exist or you do not have permissions for the operation you are attempting.")
        }
        elseif ($method -eq 'POST')
        {
            $response = new-fake-ado-pr -caller $caller -repo $repo -request $request
        }
        else
        {
            $status = 'active'
            if ($query.ContainsKey('searchCriteria.status'))
            {
                $status = $query['searchCriteria.status']
            }
            else
            {
                # Azure DevOps lists active pull requests by default
            }
            $items = @(get-fake-ado-pr-list -repo $repo -status $status -source $query['searchCriteria.sourceRefName'] -target $query['searchCriteria.targetRefName'] -top ([int]$query['$top']))
            $response = @{ value = $items; count = $items.Count }
        }
    }
    elseif ($method -eq 'GET' -and $path -match '^/msazure/_apis/git/pullrequests/(?<id>\d+)$')
    {
        $response = get-fake-ado-pr $Matches['id']
    }
    elseif ($method -eq 'PUT' -and $path -match '^/msazure/_apis/git/repositories/(?<repo>[^/]+)/pullrequests/(?<id>\d+)/reviewers/(?<user>[^/]+)$')
    {
        $user = $Matches['user']
        $pr = get-fake-ado-pr-by-id $Matches['id']
        $repo = get-fake-ado-repo $Matches['repo']
        if (-not $repo -or $repo.Name -ne $pr.Repo)
        {
            throw (new-fake-ado-error 404 "TF401180: The requested pull request was not found.")
        }
        else
        {
            $response = set-fake-ado-vote -caller $caller -pr $pr -user $user -vote ([int]$request.vote)
        }
    }
    elseif ($method -eq 'PATCH' -and $path -match '^/msazure/_apis/git/repositories/(?<repo>[^/]+)/pullrequests/(?<id>\d+)$')
    {
        $pr = get-fake-ado-pr-by-id $Matches['id']
        $repo = get-fake-ado-repo $Matches['repo']
        if (-not $repo -or $repo.Name -ne $pr.Repo)
        {
            throw (new-fake-ado-error 404 "TF401180: The requested pull request was not found.")
        }
        else
        {
            $response = update-fake-ado-pr -caller $caller -pr $pr -status ([string]$request.status) -auto_complete_set_by ([string]$request.autoCompleteSetBy.id) -completion_options $request.completionOptions
        }
    }
    elseif ($path -match '^/msazure/_apis/wit/workitems/(?<id>\d+)$' -and ($method -eq 'GET' -or $method -eq 'PATCH'))
    {
        $work_item = get-fake-ado-work-item-by-id $Matches['id']
        if ($method -eq 'PATCH')
        {
            $response = update-fake-ado-work-item -caller $caller -work_item $work_item -operations $request -content_type $content_type
        }
        else
        {
            $response = get-fake-ado-work-item-view $work_item
        }
    }
    elseif ($method -eq 'GET' -and $path -match '^/msazure/(?<project>[^/]+)/_apis/policy/evaluations$')
    {
        $response = get-fake-ado-evaluations $query
    }
    elseif ($method -eq 'GET' -and $path -match '^/msazure/(?<project>[^/]+)/_apis/build/builds/(?<build>\d+)/timeline$')
    {
        $response = get-fake-ado-timeline ([int]$Matches['build'])
    }
    else
    {
        add-fake-event @{ kind = 'ado.unexpected'; reason = 'no such route'; method = $method; url = $uri }
        throw (new-fake-ado-error 404 "The fake Azure DevOps service has no route for $method $uri.")
    }
    return (convert-fake-ado-response $response)
}

# Invoke-RestMethod as this PowerShell edition declares it (see set-fake-cmdlet-proxy).
set-fake-cmdlet-proxy -name 'Invoke-RestMethod' -body @'
    # Callers may pass -ErrorAction Stop; the fake's own work must not turn into terminating errors.
    $ErrorActionPreference = 'Continue'
    # The propagation scripts read $LASTEXITCODE after their own native commands.
    $fake_saved_exit_code = $global:LASTEXITCODE
    try
    {
        $fake_method = 'GET'
        if ($PSBoundParameters.ContainsKey('CustomMethod') -and $PSBoundParameters['CustomMethod'])
        {
            $fake_method = [string]$PSBoundParameters['CustomMethod']
        }
        elseif ($PSBoundParameters.ContainsKey('Method'))
        {
            $fake_method = [string]$PSBoundParameters['Method']
        }
        else
        {
            # GET by default
        }
        try
        {
            invoke-fake-ado-request -method $fake_method -uri (get-fake-request-url $PSBoundParameters['Uri']) -headers $PSBoundParameters['Headers'] -body $PSBoundParameters['Body'] -content_type ([string]$PSBoundParameters['ContentType'])
        }
        catch
        {
            if ($_.Exception.FakeAdoError)
            {
                throw
            }
            else
            {
                add-fake-event @{ kind = 'fake.error'; source = 'ado'; message = "$($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" }
                throw
            }
        }
    }
    finally
    {
        $global:LASTEXITCODE = $fake_saved_exit_code
    }
'@
