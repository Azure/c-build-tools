# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Fake GitHub CLI for the end-to-end tests. The runner builds a small gh.exe shim and puts it
# first on PATH. The shim saves its arguments to a file, runs this script with Windows PowerShell, and
# relays stdout, stderr and the exit code.
#
# It models the gh 2.62.0 behavior the propagation scripts depend on:
# - --json output, and --jq for simple paths;
# - pull request selection by URL, number, branch, or the current branch of the working directory;
# - "pr checks --json" exits 0 whenever checks exist and 1 when none are reported;
# - "pr merge --auto" merges at once only when the pull request is already mergeable.
# Checks start when the "/AzurePipelines run" comment is posted. A pull request becomes mergeable
# after the configured number of status polls, and an auto-merge pull request is squash-merged
# into the bare repository at the next poll after that. -Pipeline polls with
# "pr view <url> --json state,...". Interactive worlds (Gh.Interactive) model what a developer's
# runs watch instead: every pull request has a passing license/cla check, the CI check appears with
# the comment, and each "pr checks" read is a status poll.
param([string] $ArgsFile)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'fake_services.ps1')

$fake_argv = @(Get-Content -LiteralPath $ArgsFile | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_.Substring(2))) })
$fake_cwd = (Get-Location).ProviderPath
$fake_world = read-fake-json 'world.json'

function write-gh-out
{
    param([string] $text)
    [Console]::Out.Write($text)
}

function write-gh-error
{
    param([string] $text)
    [Console]::Error.Write($text + "`n")
}

function read-gh-state
{
    $state = read-fake-json 'gh_state.json'
    if (-not $state)
    {
        $faults = @(@($fake_world.Gh.Faults | Where-Object { $_ }) | ForEach-Object { [pscustomobject]@{ Repo = $_.Repo; AfterPolls = [int]$_.AfterPolls; Errors = @($_.Errors) } })
        $state = [pscustomobject]@{ NextNumber = 101; Prs = @(); Faults = $faults }
    }
    else
    {
        # saved by an earlier gh call
    }
    return $state
}

function save-gh-state
{
    param($state)
    write-fake-json 'gh_state.json' $state
}

function find-gh-repo
{
    param([string] $slug)
    $result = $null
    foreach ($property in $fake_world.Repos.PSObject.Properties)
    {
        if ($property.Value.Host -eq 'github' -and $property.Value.Slug -eq $slug)
        {
            $result = [pscustomobject]@{ Name = $property.Name; Slug = $property.Value.Slug; Bare = $property.Value.Bare }
        }
        else
        {
            # another repository
        }
    }
    return $result
}

# The GitHub repository of the working directory, from its origin remote as configured (gh reads
# the configured URL; "git remote get-url" would apply insteadOf and return the file:// URL).
function get-gh-cwd-repo
{
    $origin = invoke-fake-git -git_args @('config', '--get', 'remote.origin.url') -directory $fake_cwd -AllowFail
    $result = $null
    if ($origin.ExitCode -eq 0 -and $origin.StdOut.Trim() -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$')
    {
        $result = find-gh-repo "$($Matches[1])/$($Matches[2])"
    }
    else
    {
        # not inside a GitHub repository
    }
    return $result
}

function get-gh-setting
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

function test-gh-mergeable
{
    param($pr)
    $ready_after = [int](get-gh-setting $fake_world.Gh.ReadyAfter $pr.Repo $fake_world.Gh.DefaultReadyAfter)
    $outcome = get-gh-setting $fake_world.Gh.ChecksOutcome $pr.Repo 'pass'
    return ($pr.State -eq 'OPEN' -and $pr.CiTriggered -and $pr.Polls -gt $ready_after -and $outcome -eq 'pass')
}

function merge-gh-pr
{
    param(
        $pr,
        [string] $via,
        [bool] $delete_branch
    )
    $repo = find-gh-repo $pr.Slug
    $head = get-fake-revision $repo.Bare "refs/heads/$($pr.Head)"
    $commit = merge-fake-branch -bare $repo.Bare -branch $pr.Head -message ("{0} (#{1})" -f $pr.Title, $pr.Number) -delete_branch $delete_branch
    $pr.State = 'MERGED'
    $pr.MergeCommit = $commit
    add-fake-event @{ kind = 'gh.merged'; repo = $pr.Repo; number = $pr.Number; commit = $commit; head = $head; via = $via; deleteBranch = $delete_branch }

    # Someone else merges into another repository while the propagation is running.
    $late = $fake_world.Gh.LateCommit
    if ($late -and $late.OnMerge -eq $pr.Repo)
    {
        $target = $fake_world.Repos.($late.Repo)
        $tree = get-fake-revision $target.Bare 'refs/heads/master^{tree}'
        $late_commit = add-fake-master-commit -bare $target.Bare -tree $tree -message $late.Subject
        add-fake-event @{ kind = 'fake.late-commit'; repo = $late.Repo; commit = $late_commit }
    }
    else
    {
        # no concurrent change
    }
}

# The checks of a pull request in an interactive world: a passing license/cla check, and the CI
# check once the pipeline comment was posted. Each read of an open pull request's CI check is a
# status poll; the read that finds it passing also merges an auto-merge pull request.
function get-gh-interactive-checks
{
    param($pr)
    $checks = @(@{ name = 'license/cla'; state = 'SUCCESS'; bucket = 'pass'; link = 'https://cla.opensource.microsoft.com/'; workflow = ''; event = 'pull_request'; description = 'All CLA requirements met.'; startedAt = '2026-01-01T00:00:00Z'; completedAt = '2026-01-01T00:00:05Z' })
    if ($pr.CiTriggered)
    {
        if ($pr.State -eq 'OPEN')
        {
            $pr.Polls = [int]$pr.Polls + 1
        }
        else
        {
            # a closed or merged pull request's checks no longer change
        }
        $ready_after = [int](get-gh-setting $fake_world.Gh.ReadyAfter $pr.Repo $fake_world.Gh.DefaultReadyAfter)
        $ci = @{ name = "Azure-$($pr.Repo)-Gate"; link = "https://dev.azure.com/msazure/One/_build/results?buildId=$(7000 + [int]$pr.Number)"; workflow = ''; event = 'pull_request'; description = ''; startedAt = '2026-01-01T00:00:00Z'; completedAt = '0001-01-01T00:00:00Z' }
        if ($pr.Polls -le $ready_after -and $pr.State -eq 'OPEN')
        {
            $ci['state'] = 'IN_PROGRESS'
            $ci['bucket'] = 'pending'
        }
        elseif ((get-gh-setting $fake_world.Gh.ChecksOutcome $pr.Repo 'pass') -eq 'pass')
        {
            $ci['state'] = 'SUCCESS'
            $ci['bucket'] = 'pass'
            $ci['completedAt'] = '2026-01-01T00:20:00Z'
        }
        else
        {
            $ci['state'] = 'FAILURE'
            $ci['bucket'] = 'fail'
            $ci['completedAt'] = '2026-01-01T00:20:00Z'
        }
        add-fake-event @{ kind = 'gh.observed'; repo = $pr.Repo; number = $pr.Number; bucket = $ci['bucket'] }
        $checks += $ci
        if ($pr.State -eq 'OPEN' -and $pr.AutoMerge -and (test-gh-mergeable $pr))
        {
            merge-gh-pr -pr $pr -via 'auto' -delete_branch ([bool]$pr.AutoMergeDeleteBranch)
        }
        else
        {
            # not mergeable yet, or auto-merge not enabled
        }
    }
    else
    {
        # CI starts with the pipeline comment
    }
    return $checks
}

# Find the pull request a command refers to. Returns @{ Pr } or @{ Error }.
function find-gh-pr
{
    param(
        $state,
        [string] $selector
    )
    if ($selector -match '^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)')
    {
        $slug = "$($Matches[1])/$($Matches[2])"
        $number = [int]$Matches[3]
        $pr = @($state.Prs | Where-Object { $_.Slug -eq $slug -and $_.Number -eq $number }) | Select-Object -First 1
        if ($pr)
        {
            return @{ Pr = $pr }
        }
        else
        {
            return @{ Error = "GraphQL: Could not resolve to a PullRequest with the number of $number. (repository.pullRequest)" }
        }
    }
    else
    {
        # relative to the working directory's repository
    }

    $repo = get-gh-cwd-repo
    if (-not $repo)
    {
        return @{ Error = 'could not determine base repo: none of the git remotes configured for this repository point to a known GitHub host' }
    }
    else
    {
        # inside a GitHub repository
    }
    if ($selector -match '^#?(\d+)$')
    {
        $number = [int]$Matches[1]
        $pr = @($state.Prs | Where-Object { $_.Slug -eq $repo.Slug -and $_.Number -eq $number }) | Select-Object -First 1
        if ($pr)
        {
            return @{ Pr = $pr }
        }
        else
        {
            return @{ Error = "GraphQL: Could not resolve to a PullRequest with the number of $number. (repository.pullRequest)" }
        }
    }
    else
    {
        # select by branch
    }
    $branch = $selector
    if (-not $branch)
    {
        $branch = (invoke-fake-git -git_args @('rev-parse', '--abbrev-ref', 'HEAD') -directory $fake_cwd).StdOut.Trim()
    }
    else
    {
        # branch given
    }
    $candidates = @($state.Prs | Where-Object { $_.Slug -eq $repo.Slug -and $_.Head -eq $branch } | Sort-Object -Property @{ Expression = { $_.State -eq 'OPEN' }; Descending = $true }, @{ Expression = { $_.Number }; Descending = $true })
    if ($candidates.Count -gt 0)
    {
        return @{ Pr = $candidates[0] }
    }
    else
    {
        return @{ Error = "no pull requests found for branch `"$branch`"" }
    }
}

function get-gh-pr-fields
{
    param($pr)
    $merge_state = 'BLOCKED'
    if ($pr.State -ne 'OPEN')
    {
        $merge_state = 'UNKNOWN'
    }
    elseif (test-gh-mergeable $pr)
    {
        $merge_state = 'CLEAN'
    }
    else
    {
        # required checks have not passed
    }
    $auto_merge = $null
    if ($pr.AutoMerge)
    {
        $auto_merge = @{ mergeMethod = 'SQUASH'; enabledBy = @{ login = $fake_world.Gh.Login } }
    }
    else
    {
        # auto-merge not enabled
    }
    $merge_commit = $null
    if ($pr.MergeCommit)
    {
        $merge_commit = @{ oid = $pr.MergeCommit }
    }
    else
    {
        # not merged
    }
    return @{
        url = $pr.Url
        number = $pr.Number
        title = $pr.Title
        body = $pr.Body
        state = $pr.State
        headRefName = $pr.Head
        baseRefName = 'master'
        isDraft = $false
        reviewDecision = 'REVIEW_REQUIRED'
        mergeStateStatus = $merge_state
        autoMergeRequest = $auto_merge
        mergeCommit = $merge_commit
    }
}

function select-gh-fields
{
    param(
        [hashtable] $all,
        [string] $fields
    )
    $result = [ordered]@{}
    foreach ($field in ($fields -split ','))
    {
        if ($all.ContainsKey($field))
        {
            $result[$field] = $all[$field]
        }
        else
        {
            add-fake-event @{ kind = 'gh.unexpected'; reason = "unsupported --json field $field"; args = $fake_argv }
            $result[$field] = $null
        }
    }
    return $result
}

# Evaluate a --jq path such as .login, .permissions.push or .[0].url.
function get-gh-jq-value
{
    param(
        $value,
        [string] $expression
    )
    $rest = $expression.Trim()
    $current = $value
    if ($rest -eq '.')
    {
        $rest = ''
    }
    else
    {
        # a path
    }
    while ($rest.Length -gt 0)
    {
        $match = [regex]::Match($rest, '^(\.(?<name>[A-Za-z_][A-Za-z0-9_]*)|\.?\[(?<index>\d+)\])')
        if (-not $match.Success)
        {
            throw "unsupported --jq expression $expression"
        }
        elseif ($match.Groups['name'].Success)
        {
            if ($null -ne $current)
            {
                if ($current -is [System.Collections.IDictionary])
                {
                    $current = $current[$match.Groups['name'].Value]
                }
                else
                {
                    $current = $current.($match.Groups['name'].Value)
                }
            }
            else
            {
                # null stays null
            }
        }
        else
        {
            $items = @($current)
            $index = [int]$match.Groups['index'].Value
            if ($null -ne $current -and $index -lt $items.Count)
            {
                $current = $items[$index]
            }
            else
            {
                $current = $null
            }
        }
        $rest = $rest.Substring($match.Length)
    }
    return $current
}

# Print a result like gh: JSON, or with --jq the selected value (strings raw, null as an empty line).
function write-gh-result
{
    param(
        $value,
        [string] $jq
    )
    if ($jq)
    {
        $selected = get-gh-jq-value $value $jq
        if ($null -eq $selected)
        {
            write-gh-out "`n"
        }
        elseif ($selected -is [bool])
        {
            write-gh-out ($selected.ToString().ToLowerInvariant() + "`n")
        }
        elseif ($selected -is [string] -or $selected -is [int] -or $selected -is [long])
        {
            write-gh-out ("$selected" + "`n")
        }
        else
        {
            write-gh-out ((ConvertTo-Json -InputObject $selected -Depth 10 -Compress) + "`n")
        }
    }
    else
    {
        write-gh-out ((ConvertTo-Json -InputObject $value -Depth 10 -Compress) + "`n")
    }
}

function split-gh-arguments
{
    param([string[]] $argv)
    $value_flags = @('--title', '--body', '--body-file', '--head', '--base', '--json', '--jq', '--repo', '--state', '--limit')
    $switch_flags = @('--auto', '--squash', '--merge', '--rebase', '--delete-branch', '--version')
    $positional = New-Object System.Collections.ArrayList
    $flags = @{}
    for ($i = 0; $i -lt $argv.Count; $i++)
    {
        $argument = $argv[$i]
        if ($value_flags -contains $argument)
        {
            $flags[$argument] = $argv[$i + 1]
            $i++
        }
        elseif ($switch_flags -contains $argument)
        {
            $flags[$argument] = $true
        }
        elseif ($argument.StartsWith('-'))
        {
            add-fake-event @{ kind = 'gh.unexpected'; reason = "unsupported flag $argument"; args = $argv }
            $flags[$argument] = $true
        }
        else
        {
            [void]$positional.Add($argument)
        }
    }
    return @{ Positional = @($positional); Flags = $flags }
}

function invoke-gh-pr
{
    param(
        $state,
        [string] $verb,
        [string] $selector,
        [hashtable] $flags
    )
    if ($verb -eq 'create')
    {
        $repo = get-gh-cwd-repo
        if (-not $repo)
        {
            write-gh-error 'could not determine base repo: none of the git remotes configured for this repository point to a known GitHub host'
            return 1
        }
        else
        {
            # creating in the working directory's repository
        }
        $head = $flags['--head']
        if (-not $head)
        {
            $head = (invoke-fake-git -git_args @('rev-parse', '--abbrev-ref', 'HEAD') -directory $fake_cwd).StdOut.Trim()
        }
        else
        {
            # head branch given
        }
        $head_commit = get-fake-revision $repo.Bare "refs/heads/$head"
        if (-not $head_commit)
        {
            write-gh-error "pull request create failed: GraphQL: Head sha can't be blank, Base sha can't be blank, No commits between master and $head, Head ref must be a branch (createPullRequest)"
            return 1
        }
        else
        {
            # head branch was pushed
        }
        $open = @($state.Prs | Where-Object { $_.Slug -eq $repo.Slug -and $_.Head -eq $head -and $_.State -eq 'OPEN' }) | Select-Object -First 1
        if ($open)
        {
            write-gh-error "a pull request for branch `"$head`" into branch `"master`" already exists:`n$($open.Url)"
            return 1
        }
        else
        {
            # no open pull request for this branch
        }
        $body = ''
        if ($flags['--body-file'])
        {
            $body = [System.IO.File]::ReadAllText($flags['--body-file'])
        }
        elseif ($flags['--body'])
        {
            $body = $flags['--body']
        }
        else
        {
            # empty body
        }
        if ($body.Length -gt 65536)
        {
            write-gh-error 'pull request create failed: GraphQL: Body is too long (maximum is 65536 characters) (createPullRequest)'
            return 1
        }
        else
        {
            # body fits
        }
        $number = [int]$state.NextNumber
        $state.NextNumber = $number + 1
        $url = "https://github.com/$($repo.Slug)/pull/$number"
        $pr = [pscustomobject]@{
            Number = $number
            Slug = $repo.Slug
            Repo = $repo.Name
            Url = $url
            Head = $head
            Title = [string]$flags['--title']
            Body = $body
            State = 'OPEN'
            AutoMerge = $false
            AutoMergeDeleteBranch = $false
            CiTriggered = $false
            Polls = 0
            HeadCommit = $head_commit
            MergeCommit = $null
        }
        $state.Prs = @($state.Prs) + @($pr)
        add-fake-event @{ kind = 'gh.create'; repo = $repo.Name; number = $number; url = $url; title = $pr.Title; head = $head; headCommit = $head_commit; headMessage = (get-fake-commit-message $repo.Bare $head_commit); body = $body }
        write-gh-out "$url`n"
        return 0
    }
    elseif ($verb -eq 'list')
    {
        $repo = get-gh-cwd-repo
        if (-not $repo)
        {
            write-gh-error 'could not determine base repo: none of the git remotes configured for this repository point to a known GitHub host'
            return 1
        }
        else
        {
            # listing the working directory's repository
        }
        $wanted_state = 'OPEN'
        if ($flags['--state'])
        {
            $wanted_state = ([string]$flags['--state']).ToUpperInvariant()
        }
        else
        {
            # gh lists open pull requests by default
        }
        $items = @($state.Prs | Where-Object { $_.Slug -eq $repo.Slug -and ($wanted_state -eq 'ALL' -or $_.State -eq $wanted_state) -and (-not $flags['--head'] -or $_.Head -eq $flags['--head']) })
        $projected = @($items | ForEach-Object { select-gh-fields (get-gh-pr-fields $_) $flags['--json'] })
        write-gh-result -value $projected -jq $flags['--jq']
        return 0
    }
    else
    {
        # commands on an existing pull request
    }

    $found = find-gh-pr -state $state -selector $selector
    if ($found.Error)
    {
        write-gh-error $found.Error
        return 1
    }
    else
    {
        $pr = $found.Pr
    }

    if ($verb -eq 'view')
    {
        $fields = [string]$flags['--json']
        if (-not $fields)
        {
            add-fake-event @{ kind = 'gh.unexpected'; reason = 'pr view without --json'; args = $fake_argv }
            write-gh-error 'fake gh: pr view needs --json'
            return 2
        }
        else
        {
            # JSON output
        }
        $is_poll = (-not $fake_world.Gh.Interactive) -and ($selector -match '^https://') -and (($fields -split ',') -contains 'state') -and $pr.State -eq 'OPEN'
        if ($is_poll)
        {
            $fault = @($state.Faults | Where-Object { $_.Repo -eq $pr.Repo -and $_.AfterPolls -eq $pr.Polls -and @($_.Errors).Count -gt 0 }) | Select-Object -First 1
            if ($fault)
            {
                $kind = @($fault.Errors)[0]
                $fault.Errors = @(@($fault.Errors) | Select-Object -Skip 1)
                add-fake-event @{ kind = 'fault'; service = 'gh'; repo = $pr.Repo; number = $pr.Number; error = $kind; afterPolls = $pr.Polls }
                write-gh-error 'HTTP 502: Server Error (https://api.github.com/graphql)'
                return 1
            }
            else
            {
                # no fault due
            }
            $pr.Polls = [int]$pr.Polls + 1
            if ($pr.AutoMerge -and (test-gh-mergeable $pr))
            {
                merge-gh-pr -pr $pr -via 'auto' -delete_branch ([bool]$pr.AutoMergeDeleteBranch)
            }
            else
            {
                # not mergeable yet, or auto-merge not enabled
            }
        }
        else
        {
            # a lookup, not a status poll
        }
        write-gh-result -value (select-gh-fields (get-gh-pr-fields $pr) $fields) -jq $flags['--jq']
        return 0
    }
    elseif ($verb -eq 'checks')
    {
        if (-not $flags['--json'])
        {
            add-fake-event @{ kind = 'gh.unexpected'; reason = 'pr checks without --json'; args = $fake_argv }
            write-gh-error 'fake gh: pr checks needs --json'
            return 2
        }
        elseif ($fake_world.Gh.Interactive)
        {
            $checks = @(get-gh-interactive-checks $pr)
            write-gh-result -value @($checks | ForEach-Object { select-gh-fields $_ $flags['--json'] }) -jq $flags['--jq']
            return 0
        }
        elseif (-not $pr.CiTriggered)
        {
            write-gh-error "no checks reported on the '$($pr.Head)' branch"
            return 1
        }
        else
        {
            # checks are running or done
        }
        $ready_after = [int](get-gh-setting $fake_world.Gh.ReadyAfter $pr.Repo $fake_world.Gh.DefaultReadyAfter)
        $check = @{ name = 'Fake PR gate'; link = 'https://dev.azure.com/msazure/One/_build/results?buildId=4242'; workflow = ''; event = 'pull_request'; description = ''; startedAt = '2026-01-01T00:00:00Z'; completedAt = '0001-01-01T00:00:00Z' }
        if ($pr.Polls -le $ready_after)
        {
            $check['state'] = 'IN_PROGRESS'
            $check['bucket'] = 'pending'
        }
        elseif ((get-gh-setting $fake_world.Gh.ChecksOutcome $pr.Repo 'pass') -eq 'pass')
        {
            $check['state'] = 'SUCCESS'
            $check['bucket'] = 'pass'
        }
        else
        {
            $check['state'] = 'FAILURE'
            $check['bucket'] = 'fail'
        }
        write-gh-result -value @(select-gh-fields $check $flags['--json']) -jq $flags['--jq']
        return 0
    }
    elseif ($verb -eq 'merge')
    {
        if ($pr.State -ne 'OPEN')
        {
            write-gh-error "Pull request #$($pr.Number) is $($pr.State.ToLowerInvariant())"
            return 1
        }
        elseif (-not $flags['--squash'])
        {
            add-fake-event @{ kind = 'gh.unexpected'; reason = 'merge without --squash'; args = $fake_argv }
            write-gh-error 'fake gh: only squash merges are supported'
            return 2
        }
        else
        {
            # squash merge
        }
        $delete_branch = [bool]$flags['--delete-branch']
        if (test-gh-mergeable $pr)
        {
            $via = 'direct'
            if ($flags['--auto'])
            {
                $via = 'auto-immediate'
            }
            else
            {
                # an explicit merge
            }
            merge-gh-pr -pr $pr -via $via -delete_branch $delete_branch
            write-gh-out "Squashed and merged pull request #$($pr.Number)`n"
            return 0
        }
        elseif ($flags['--auto'])
        {
            $pr.AutoMerge = $true
            $pr.AutoMergeDeleteBranch = $delete_branch
            add-fake-event @{ kind = 'gh.automerge'; repo = $pr.Repo; number = $pr.Number; method = 'squash'; deleteBranch = $delete_branch }
            write-gh-out "Pull request #$($pr.Number) will be automatically merged via squash when all requirements are met`n"
            return 0
        }
        else
        {
            write-gh-error "X Pull request #$($pr.Number) is not mergeable: the base branch policy prohibits the merge."
            return 1
        }
    }
    elseif ($verb -eq 'comment')
    {
        $body = [string]$flags['--body']
        if ($body.Trim() -eq '/AzurePipelines run')
        {
            $pr.CiTriggered = $true
        }
        else
        {
            # an ordinary comment
        }
        add-fake-event @{ kind = 'gh.comment'; repo = $pr.Repo; number = $pr.Number; body = $body }
        write-gh-out "$($pr.Url)#issuecomment-1`n"
        return 0
    }
    elseif ($verb -eq 'close')
    {
        if ($pr.State -eq 'OPEN')
        {
            $pr.State = 'CLOSED'
            add-fake-event @{ kind = 'gh.close'; repo = $pr.Repo; number = $pr.Number }
        }
        else
        {
            # already closed or merged
        }
        write-gh-out "Closed pull request #$($pr.Number)`n"
        return 0
    }
    elseif ($verb -eq 'reopen')
    {
        if ($pr.State -eq 'CLOSED')
        {
            $pr.State = 'OPEN'
            add-fake-event @{ kind = 'gh.reopen'; repo = $pr.Repo; number = $pr.Number }
        }
        else
        {
            # not closed
        }
        write-gh-out "Reopened pull request #$($pr.Number)`n"
        return 0
    }
    else
    {
        add-fake-event @{ kind = 'gh.unexpected'; reason = "unsupported command pr $verb"; args = $fake_argv }
        write-gh-error "fake gh: unsupported command pr $verb"
        return 2
    }
}

function invoke-fake-gh
{
    param([string[]] $argv)
    $parsed = split-gh-arguments $argv
    $positional = $parsed.Positional
    $flags = $parsed.Flags
    if ($flags['--version'] -or ($positional.Count -gt 0 -and $positional[0] -eq 'version'))
    {
        write-gh-out "gh version 2.62.0 (fake)`n"
        return 0
    }
    else
    {
        # a command that needs authentication
    }
    # Signed in through GH_TOKEN (pipelines), or with the account 'gh auth login' stored in the gh
    # config folder (developers).
    $credential = $null
    if (-not [string]::IsNullOrEmpty($env:GH_TOKEN))
    {
        $credential = 'GH_TOKEN'
    }
    elseif ($env:GH_CONFIG_DIR -and (Test-Path -LiteralPath (Join-Path $env:GH_CONFIG_DIR 'hosts.yml')) -and ([System.IO.File]::ReadAllText((Join-Path $env:GH_CONFIG_DIR 'hosts.yml')) -match '(?m)^github\.com:'))
    {
        $credential = 'keyring'
    }
    else
    {
        # not signed in
    }
    if (-not $credential)
    {
        if ($positional.Count -ge 2 -and $positional[0] -eq 'auth' -and $positional[1] -eq 'status')
        {
            write-gh-error 'You are not logged into any GitHub hosts. To log in, run: gh auth login'
            return 1
        }
        else
        {
            write-gh-error "To get started with GitHub CLI, please run:  gh auth login`nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token."
            return 4
        }
    }
    else
    {
        # authenticated through GH_TOKEN
    }

    $state = read-gh-state
    $exit_code = 2
    $group = ''
    if ($positional.Count -gt 0)
    {
        $group = $positional[0]
    }
    else
    {
        # no command
    }
    if ($group -eq 'auth' -and $positional.Count -ge 2 -and $positional[1] -eq 'status')
    {
        write-gh-out "github.com`n  Logged in to github.com account $($fake_world.Gh.Login) ($credential)`n"
        $exit_code = 0
    }
    elseif ($group -eq 'auth' -and $positional.Count -ge 2 -and $positional[1] -eq 'setup-git')
    {
        $exit_code = 0
    }
    elseif ($group -eq 'api' -and $positional.Count -ge 2 -and $positional[1] -eq 'user')
    {
        write-gh-result -value @{ login = $fake_world.Gh.Login; id = 4242 } -jq $flags['--jq']
        $exit_code = 0
    }
    elseif ($group -eq 'api' -and $positional.Count -ge 2 -and $positional[1] -match '^repos/([^/]+/[^/]+)$')
    {
        $repo = find-gh-repo $Matches[1]
        if (-not $repo)
        {
            write-gh-error 'gh: Not Found (HTTP 404)'
            $exit_code = 1
        }
        else
        {
            $push = -not (@($fake_world.Gh.NoPush) -contains $repo.Slug)
            write-gh-result -value @{ full_name = $repo.Slug; permissions = @{ admin = $false; maintain = $false; push = $push; triage = $true; pull = $true } } -jq $flags['--jq']
            $exit_code = 0
        }
    }
    elseif ($group -eq 'pr' -and $positional.Count -ge 2)
    {
        $selector = ''
        if ($positional.Count -ge 3)
        {
            $selector = $positional[2]
        }
        else
        {
            # the working directory's current branch
        }
        $exit_code = invoke-gh-pr -state $state -verb $positional[1] -selector $selector -flags $flags
    }
    else
    {
        add-fake-event @{ kind = 'gh.unexpected'; reason = 'unsupported command'; args = $argv }
        write-gh-error "fake gh: unsupported command $($argv -join ' ')"
        $exit_code = 2
    }
    save-gh-state $state
    return $exit_code
}

add-fake-event @{ kind = 'gh.call'; args = $fake_argv; cwd = $fake_cwd }
$fake_exit_code = 99
try
{
    $fake_exit_code = invoke-fake-gh -argv $fake_argv
}
catch
{
    add-fake-event @{ kind = 'fake.error'; source = 'gh'; message = "$($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" }
    write-gh-error "fake gh internal error: $($_.Exception.Message)"
    $fake_exit_code = 99
}
exit $fake_exit_code
