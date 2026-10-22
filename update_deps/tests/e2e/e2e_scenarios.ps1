# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# The end-to-end scenarios and their assertions. The assertions are the same for every implementation:
# they describe the Azure-MessagingStore pipeline's observable behavior (pull requests opened, armed and
# merged, their order, their text, and the final submodule state). Intended internal differences, such
# as the order of independent repositories within one wave, are not asserted.

function assert-e2e
{
    param(
        [hashtable] $r,
        [bool] $condition,
        [string] $message
    )
    if (-not $condition)
    {
        $r.Failures.Add($message)
    }
    else
    {
        # passed
    }
}

function test-e2e-output
{
    param(
        [hashtable] $r,
        [string] $text
    )
    # Compare with whitespace collapsed: console output may break a message across lines.
    if (-not $r.ContainsKey('NormalizedOutput'))
    {
        $r['NormalizedOutput'] = [regex]::Replace($r.Output, '\s+', ' ')
    }
    else
    {
        # cached
    }
    $needle = [regex]::Replace($text, '\s+', ' ')
    return ($r.NormalizedOutput.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

# Whether one run's output (1-based) contains $text, with whitespace collapsed.
function test-e2e-run-output
{
    param(
        [hashtable] $r,
        [int] $run,
        [string] $text
    )
    $output = [regex]::Replace([string]$r.Outputs[$run - 1], '\s+', ' ')
    return ($output.IndexOf([regex]::Replace($text, '\s+', ' '), [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function get-e2e-events
{
    param(
        [hashtable] $r,
        [string[]] $kinds,
        [string] $repo = $null
    )
    return @($r.Events | Where-Object { $kinds -contains $_.kind -and (-not $repo -or $_.repo -eq $repo) })
}

# Position of the first matching event in the run, or -1.
function get-e2e-index
{
    param(
        [hashtable] $r,
        [string[]] $kinds,
        [string] $repo
    )
    $found = @(get-e2e-events $r $kinds $repo)
    if ($found.Count -gt 0)
    {
        return $found[0].Index
    }
    else
    {
        return -1
    }
}

function assert-e2e-before
{
    param(
        [hashtable] $r,
        [string] $first_kind,
        [string] $first_repo,
        [string] $second_kind,
        [string] $second_repo,
        [string] $why
    )
    $kinds = @{ create = @('gh.create', 'ado.create'); merge = @('gh.merged', 'ado.merged') }
    $first = get-e2e-index $r $kinds[$first_kind] $first_repo
    $second = get-e2e-index $r $kinds[$second_kind] $second_repo
    assert-e2e $r ($first -ge 0 -and $second -ge 0 -and $first -lt $second) "$first_repo $first_kind must happen before $second_repo $second_kind ($why); positions $first and $second."
}

function get-e2e-bare
{
    param(
        [hashtable] $r,
        [string] $repo
    )
    return $r.World.Repos[$repo].Bare
}

function get-e2e-gitlink
{
    param(
        [hashtable] $r,
        [string] $repo,
        [string] $commit,
        [string] $path
    )
    $tree = invoke-fake-git -git_args @("--git-dir=$(get-e2e-bare $r $repo)", 'ls-tree', $commit, '--', $path) -AllowFail
    if ($tree.StdOut -match '^160000 commit ([0-9a-f]{40})\t')
    {
        return $Matches[1]
    }
    else
    {
        return $null
    }
}

function get-e2e-yaml-ref
{
    param(
        [hashtable] $r,
        [string] $repo,
        [string] $commit
    )
    $yaml = invoke-fake-git -git_args @("--git-dir=$(get-e2e-bare $r $repo)", 'show', "${commit}:build/pipeline.yml") -AllowFail
    if ($yaml.StdOut -match 'ref:\s*([0-9a-f]{40})')
    {
        return $Matches[1]
    }
    else
    {
        return $null
    }
}

function get-e2e-propagation-branches
{
    param(
        [hashtable] $r,
        [string] $repo
    )
    $refs = invoke-fake-git -git_args @("--git-dir=$(get-e2e-bare $r $repo)", 'for-each-ref', '--format=%(refname:short)', 'refs/heads/new_deps_*')
    return @($refs.StdOut -split "`r?`n" | Where-Object { $_ })
}

# Checks for every scenario: every run finished by itself, nothing unexpected reached the fake services,
# nothing asked for input, and no secret was printed. The only 401s allowed are for access tokens the
# service revoked on purpose (the run must then sign in again).
function assert-e2e-common
{
    param([hashtable] $r)
    foreach ($run in $r.Runs)
    {
        assert-e2e $r (-not $run.TimedOut) "run $($run.Index) did not finish within $e2e_run_timeout_sec seconds."
    }
    assert-e2e $r (@(get-e2e-events $r @('driver.end')).Count -eq $r.Runs.Count) "a run did not finish (exit codes $(($r.Runs | ForEach-Object { $_.ExitCode }) -join ', '))."
    foreach ($kind in @('driver.budget-exceeded', 'driver.exception', 'driver.prompt', 'fake.error'))
    {
        $found = @(get-e2e-events $r @($kind))
        assert-e2e $r ($found.Count -eq 0) "$kind events: $(($found | ForEach-Object { ConvertTo-Json -Compress -InputObject $_ }) -join ' | ')"
    }
    $unauthorized = @(get-e2e-events $r @('ado.unauthorized') | Where-Object { $_.reason -ne 'revoked-token' })
    assert-e2e $r ($unauthorized.Count -eq 0) "ado.unauthorized events: $(($unauthorized | ForEach-Object { ConvertTo-Json -Compress -InputObject $_ }) -join ' | ')"
    $unexpected = @($r.Events | Where-Object { $_.kind -like '*unexpected' })
    assert-e2e $r ($unexpected.Count -eq 0) "unexpected calls to the fake services: $(($unexpected | ForEach-Object { ConvertTo-Json -Compress -Depth 5 -InputObject $_ }) -join ' | ')"
    assert-e2e $r (-not (test-e2e-output $r $e2e_system_token)) 'SYSTEM_ACCESSTOKEN was printed.'
    assert-e2e $r (-not (test-e2e-output $r $e2e_gh_token)) 'GH_TOKEN was printed.'
    $printed = @(@($r.Ado.Tokens) | Where-Object { $_ -and $_.Token -and (test-e2e-output $r $_.Token) })
    assert-e2e $r ($printed.Count -eq 0) "$($printed.Count) Azure DevOps access token(s) from the Azure CLI were printed."
    if ($r.Spec.Interactive)
    {
        assert-e2e-interactive-common $r
    }
    else
    {
        # pipeline runs own their isolated git config
    }
}

# The run failed, for the intended reason: each of $texts must appear in its output.
function assert-e2e-failed
{
    param(
        [hashtable] $r,
        [string[]] $texts
    )
    assert-e2e $r ($r.Run.ExitCode -ne 0) 'the run must fail.'
    foreach ($text in $texts)
    {
        assert-e2e $r (test-e2e-output $r $text) "the output does not say '$text'."
    }
}

# Nothing happened to these repositories: no pull request, no propagation branch, master unchanged.
function assert-e2e-untouched
{
    param(
        [hashtable] $r,
        [string[]] $repos
    )
    foreach ($repo in $repos)
    {
        assert-e2e $r (@(get-e2e-events $r @('gh.create', 'ado.create') $repo).Count -eq 0) "a pull request was opened for $repo."
        assert-e2e $r (@(get-e2e-propagation-branches $r $repo).Count -eq 0) "a propagation branch was pushed to $repo."
        $master = get-fake-revision (get-e2e-bare $r $repo) 'refs/heads/master'
        assert-e2e $r ($master -eq $r.World.InitialMasters[$repo]) "master of $repo changed."
    }
}

$e2e_pr_repos = @('fake-logging', 'fake-pal', 'fake-util', 'FakeLib', 'FakeApp', 'FakeRoot')

function assert-e2e-happy-path
{
    param([hashtable] $r)
    $template = $r.World.Template.Repos
    assert-e2e $r ($r.Run.ExitCode -eq 0) "the run must succeed (exit code $($r.Run.ExitCode))."

    # One pull request per repository with dependencies; none for c-build-tools (no dependencies) or
    # for libuv (ignored).
    $creates = @(get-e2e-events $r @('gh.create', 'ado.create'))
    foreach ($repo in $e2e_pr_repos)
    {
        assert-e2e $r (@($creates | Where-Object { $_.repo -eq $repo }).Count -eq 1) "expected one pull request for $repo, got $(@($creates | Where-Object { $_.repo -eq $repo }).Count)."
        assert-e2e $r (@(get-e2e-events $r @('gh.merged', 'ado.merged') $repo).Count -eq 1) "the pull request for $repo did not merge exactly once."
    }
    $extra = @($creates | Where-Object { $e2e_pr_repos -notcontains $_.repo } | ForEach-Object { $_.repo })
    assert-e2e $r ($extra.Count -eq 0) "unexpected pull requests for: $($extra -join ', ')."
    $branches = @($creates | ForEach-Object { if ($_.kind -eq 'gh.create') { $_.head } else { $_.branch } } | Select-Object -Unique)
    assert-e2e $r ($branches.Count -eq 1 -and $branches[0] -match '^new_deps_\d{14}$') "every pull request must come from one new_deps_<timestamp> branch: $($branches -join ', ')."

    # Bottom-up: a pull request opens only after every dependency's pull request merged.
    foreach ($repo in $e2e_pr_repos)
    {
        foreach ($dep in $template[$repo].Deps)
        {
            if ($e2e_pr_repos -contains $dep)
            {
                assert-e2e-before $r 'merge' $dep 'create' $repo 'dependency order'
            }
            else
            {
                # c-build-tools has nothing to propagate
            }
        }
    }
    # Greedy: a slow pull request (fake-logging, FakeApp) does not hold up repositories that do not
    # depend on it. A scheduler that waits for each level to finish would fail these.
    assert-e2e-before $r 'create' 'fake-pal' 'merge' 'fake-logging' 'independent pull requests open together'
    assert-e2e-before $r 'create' 'fake-logging' 'merge' 'fake-pal' 'independent pull requests open together'
    assert-e2e-before $r 'create' 'fake-util' 'merge' 'fake-logging' 'fake-util does not depend on fake-logging'
    assert-e2e-before $r 'create' 'FakeApp' 'merge' 'fake-logging' 'FakeApp does not depend on fake-logging'
    assert-e2e-before $r 'create' 'FakeRoot' 'merge' 'FakeApp' 'FakeRoot does not depend on FakeApp'

    assert-e2e-pr-text $r $creates '[no begging] [autogenerated]'

    # Azure DevOps pull requests are linked to the work item, approved by the build identity, and set
    # to squash-merge on their own; GitHub ones get squash auto-merge, then the pipeline comment.
    $bot = $r.World.Ado.BotId
    foreach ($create in @($creates | Where-Object { $_.kind -eq 'ado.create' }))
    {
        $artifact = "vstfs:///Git/PullRequestId/$($r.World.Ado.ProjectId)/$($r.World.Repos[$create.repo].Id)/$($create.id)"
        $links = @($r.Ado.WorkItems.'42'.Relations | Where-Object { $_.Rel -eq 'ArtifactLink' -and [System.Uri]::UnescapeDataString($_.Url) -eq $artifact })
        assert-e2e $r ($links.Count -eq 1) "work item 42 has $($links.Count) links to the $($create.repo) pull request."
        $votes = @(get-e2e-events $r @('ado.vote') | Where-Object { $_.id -eq $create.id -and $_.user -eq $bot -and $_.vote -eq 10 })
        assert-e2e $r ($votes.Count -ge 1) "the build identity did not approve the $($create.repo) pull request."
        $auto = @(get-e2e-events $r @('ado.autocomplete') | Where-Object { $_.id -eq $create.id -and $_.by -eq $bot -and $_.mergeStrategy -eq 'squash' -and $_.deleteSourceBranch })
        assert-e2e $r ($auto.Count -ge 1) "the $($create.repo) pull request was not set to auto-complete with squash and source branch deletion."
    }
    foreach ($create in @($creates | Where-Object { $_.kind -eq 'gh.create' }))
    {
        $auto = @(get-e2e-events $r @('gh.automerge') | Where-Object { $_.number -eq $create.number -and $_.method -eq 'squash' -and $_.deleteBranch })
        $comment = @(get-e2e-events $r @('gh.comment') | Where-Object { $_.number -eq $create.number -and $_.body -eq '/AzurePipelines run' })
        assert-e2e $r ($auto.Count -ge 1) "squash auto-merge with branch deletion was not enabled for the $($create.repo) pull request."
        assert-e2e $r ($comment.Count -ge 1) "the $($create.repo) pull request did not get the /AzurePipelines run comment."
        assert-e2e $r ($auto.Count -ge 1 -and $comment.Count -ge 1 -and $auto[0].Index -lt $comment[0].Index) "auto-merge must be enabled before the pipeline comment on the $($create.repo) pull request."
    }

    assert-e2e-final-state $r -LateCommit

    # The injected service failures happened, and the run recovered from them.
    $faults = @(get-e2e-events $r @('fault'))
    assert-e2e $r ($faults.Count -eq 5) "expected 5 injected service failures, got $($faults.Count)."
}

# Every repository $repo depends on, directly or not (ignored libuv left out).
function get-e2e-upstream
{
    param([string] $repo)
    $result = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    foreach ($dep in $e2e_repo_specs[$repo].Deps)
    {
        $queue.Enqueue($dep)
    }
    while ($queue.Count -gt 0)
    {
        $dep = $queue.Dequeue()
        if ($dep -ne 'libuv' -and -not $result.Contains($dep))
        {
            [void]$result.Add($dep)
            foreach ($next in $e2e_repo_specs[$dep].Deps)
            {
                $queue.Enqueue($next)
            }
        }
        else
        {
            # ignored, or already listed
        }
    }
    return @($result)
}

# The text of the propagation pull requests ($creates: their create events) and of their commits.
# Titles start with $title_prefix. Pipeline runs name exactly the repositories whose own changes
# reach the pull request (the root causes). With -Interactive the names must include the root causes
# and may include other upstream repositories: the original interactive scripts also name every
# dependency whose only change is its propagation commit.
function assert-e2e-pr-text
{
    param(
        [hashtable] $r,
        [object[]] $creates,
        [string] $title_prefix,
        [switch] $Interactive
    )
    $helper = $r.World.Template.HelperSubject
    foreach ($create in $creates)
    {
        $repo = $create.repo
        $subject = ($create.headMessage -split "`r?`n")[0]
        if ($repo -eq 'fake-logging' -or $repo -eq 'fake-pal')
        {
            assert-e2e $r ($create.title -ceq "$title_prefix update deps: c-build-tools") "title of the $repo pull request: '$($create.title)'."
            assert-e2e $r ($subject.StartsWith('Update deps: c-build-tools: ')) "commit subject for ${repo}: '$subject'."
        }
        elseif ($Interactive)
        {
            $upstream = @(get-e2e-upstream $repo)
            $title_names = @()
            if ($create.title.StartsWith("$title_prefix update deps: ", [System.StringComparison]::Ordinal))
            {
                $title_names = @($create.title.Substring("$title_prefix update deps: ".Length) -split ', ')
            }
            else
            {
                # reported below
            }
            $subject_names = @()
            if ($subject -match '^Update deps: ([^:]+)$')
            {
                $subject_names = @($Matches[1] -split ', ')
            }
            else
            {
                # reported below
            }
            foreach ($names in @(@{ What = 'title'; Text = $create.title; Names = $title_names }, @{ What = 'commit subject'; Text = $subject; Names = $subject_names }))
            {
                $missing = @(@('c-build-tools', 'fake-pal') | Where-Object { $names.Names -notcontains $_ })
                $foreign = @($names.Names | Where-Object { $upstream -notcontains $_ })
                assert-e2e $r ($names.Names.Count -gt 0 -and $missing.Count -eq 0 -and $foreign.Count -eq 0) "$($names.What) of the $repo pull request: '$($names.Text)' (must name c-build-tools and fake-pal, and only upstream repositories)."
            }
            assert-e2e $r ($create.headMessage.Contains('Pal improvement (https://github.com/Azure/fake-pal/pull/7)')) "the $repo commit message does not list the fake-pal change with its expanded PR link."
        }
        else
        {
            assert-e2e $r ($create.title -ceq "$title_prefix update deps: c-build-tools, fake-pal") "title of the $repo pull request: '$($create.title)'."
            assert-e2e $r ($subject -ceq 'Update deps: c-build-tools, fake-pal') "commit subject for ${repo}: '$subject'."
            # Upstream changes are listed through every level, with GitHub (#N) references expanded so
            # Azure DevOps does not link them as work items.
            assert-e2e $r ($create.headMessage.Contains('Pal improvement (https://github.com/Azure/fake-pal/pull/7)')) "the $repo commit message does not list the fake-pal change with its expanded PR link."
        }
        assert-e2e $r ($create.headMessage.Contains($helper)) "the $repo commit message does not list the c-build-tools change '$helper'."
        assert-e2e $r (-not $create.headMessage.Contains('Late cbt change')) "the $repo commit message lists a c-build-tools commit made after the run started."
        $body = $create.body
        if ($create.kind -eq 'ado.create')
        {
            $body = $create.description
            assert-e2e $r ($body.Length -le 4000) "the $repo description has $($body.Length) characters; Azure DevOps allows 4000."
        }
        else
        {
            # GitHub allows 65536 characters; the fake checks that limit
        }
        assert-e2e $r ($body.StartsWith('## Dependency Updates')) "the $repo pull request body does not start with '## Dependency Updates'."
    }
    $root = @($creates | Where-Object { $_.repo -eq 'FakeRoot' }) | Select-Object -Last 1
    if ($root)
    {
        foreach ($create in @($creates | Where-Object { $_.repo -ne 'FakeRoot' }))
        {
            $link = if ($create.kind -eq 'gh.create') { "[$($create.repo)]($($create.url))" } else { "[$($create.repo)](https://dev.azure.com/msazure/One/_git/$($create.repo)/pullrequest/$($create.id))" }
            assert-e2e $r ($root.description.Contains($link)) "the FakeRoot description does not link $link."
        }
    }
    else
    {
        # reported by the caller
    }
}

# The final state after a successful propagation. Dependents pin c-build-tools at its master when the
# run started (a commit merged later is not propagated), keep a submodule commit that is ahead of that
# (FakeApp), and pin every other dependency at the commit its own pull request merged. Ignored libuv
# never moves. -LateCommit: c-build-tools got a commit during the run, which must be reported.
function assert-e2e-final-state
{
    param(
        [hashtable] $r,
        [switch] $LateCommit
    )
    $template = $r.World.Template.Repos
    $merged_commits = @{}
    foreach ($merge in @(get-e2e-events $r @('gh.merged', 'ado.merged')))
    {
        $merged_commits[$merge.repo] = $merge.commit
    }
    $snapshot = $template['c-build-tools'].Final
    $ahead = $template['c-build-tools'].Side
    if ($LateCommit)
    {
        $late = @(get-e2e-events $r @('fake.late-commit'))
        assert-e2e $r ($late.Count -eq 1) "the concurrent c-build-tools commit was not made."
        assert-e2e $r (test-e2e-output $r 'NEWER COMMITS NOT PROPAGATED') 'the run did not report the c-build-tools commit it left out.'
    }
    else
    {
        # c-build-tools did not change during the run
    }
    foreach ($repo in $e2e_pr_repos)
    {
        $master = get-fake-revision (get-e2e-bare $r $repo) 'refs/heads/master'
        assert-e2e $r ($master -eq $merged_commits[$repo]) "master of $repo is not its pull request's merge commit."
        foreach ($dep in $template[$repo].Deps)
        {
            if ($dep -eq 'c-build-tools')
            {
                $expected = if ($repo -eq 'FakeApp') { $ahead } else { $snapshot }
            }
            else
            {
                $expected = $merged_commits[$dep]
            }
            $actual = get-e2e-gitlink $r $repo $master "deps/$dep"
            assert-e2e $r ($actual -eq $expected) "$repo deps/$dep is $actual; expected $expected."
        }
        if ($e2e_repo_specs[$repo].PipelineYaml)
        {
            $expected_ref = if ($repo -eq 'FakeApp') { $ahead } else { $snapshot }
            $actual_ref = get-e2e-yaml-ref $r $repo $master
            assert-e2e $r ($actual_ref -eq $expected_ref) "$repo build/pipeline.yml has c_build_tools ref $actual_ref; expected $expected_ref."
        }
        else
        {
            # no pipeline YAML
        }
        assert-e2e $r (@(get-e2e-propagation-branches $r $repo).Count -eq 0) "the propagation branch of $repo was not deleted after the merge."
    }
    $root_master = get-fake-revision (get-e2e-bare $r 'FakeRoot') 'refs/heads/master'
    assert-e2e $r ((get-e2e-gitlink $r 'FakeRoot' $root_master 'deps/libuv') -eq $template['libuv'].Initial) 'the ignored libuv submodule was updated.'
    assert-e2e-untouched $r @('libuv')
}

# --- Interactive scenarios ------------------------------------------------------------------------

# The last pull request opened for each repository with dependencies (a repository whose pull request
# failed gets a new one when the propagation resumes). The known_graph.json pull request is not one.
function get-e2e-final-creates
{
    param([hashtable] $r)
    $result = @()
    foreach ($repo in $e2e_pr_repos)
    {
        $last = @(get-e2e-events $r @('gh.create', 'ado.create') $repo) | Select-Object -Last 1
        if ($last)
        {
            $result += $last
        }
        else
        {
            # reported by the caller
        }
    }
    return $result
}

# The merge event of the pull request a create event opened, or $null.
function get-e2e-merge
{
    param(
        [hashtable] $r,
        $create
    )
    if ($create.kind -eq 'gh.create')
    {
        return (@(get-e2e-events $r @('gh.merged') $create.repo | Where-Object { $_.number -eq $create.number }) | Select-Object -First 1)
    }
    else
    {
        return (@(get-e2e-events $r @('ado.merged') $create.repo | Where-Object { $_.id -eq $create.id }) | Select-Object -First 1)
    }
}

function get-e2e-pr-url
{
    param($create)
    if ($create.kind -eq 'gh.create')
    {
        return $create.url
    }
    else
    {
        return "https://dev.azure.com/msazure/One/_git/$($create.repo)/pullrequest/$($create.id)"
    }
}

# The propagation state an interactive run saved for -Resume, or $null.
function get-e2e-saved-state
{
    param([hashtable] $r)
    $folders = @(Get-ChildItem -LiteralPath (Join-Path $r.World.Path 'agent_work') -Directory -Filter 'new_deps_*' -ErrorAction SilentlyContinue)
    $result = $null
    if ($folders.Count -eq 1)
    {
        $file = Join-Path $folders[0].FullName 'propagation_state.json'
        if (Test-Path -LiteralPath $file)
        {
            $result = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
        }
        else
        {
            # no state saved
        }
    }
    else
    {
        # none, or more than one propagation folder (reported by the caller)
    }
    return $result
}

# The credential kinds Azure DevOps may see in an interactive scenario: the developer's, through
# REST or the Azure CLI.
function get-e2e-interactive-auth
{
    param([hashtable] $r)
    if ($r.Spec.Pat)
    {
        return @('pat', 'az-pat')
    }
    else
    {
        return @('wam', 'az-wam')
    }
}

# Checks for every interactive scenario: the run never asked for input (prompts other than Read-Host
# fail in these -NonInteractive runs, with an error saying so), the developer's machine is left as
# it was (their global git config, no git credential helper set up by gh, no new Azure CLI
# sign-in), and every Azure DevOps change was made as the developer.
function assert-e2e-interactive-common
{
    param([hashtable] $r)
    assert-e2e $r (-not (test-e2e-output $r 'NonInteractive mode')) 'the run asked for input (a prompt failed in NonInteractive mode).'
    $config = [System.IO.File]::ReadAllText($r.World.DeveloperConfig)
    assert-e2e $r ($config -ceq $r.World.DeveloperConfigText) "the developer's global git config changed: $config"
    $setup = @(get-e2e-events $r @('gh.call') | Where-Object { @($_.args)[0] -eq 'auth' -and @($_.args)[1] -eq 'setup-git' })
    assert-e2e $r ($setup.Count -eq 0) "an interactive run ran 'gh auth setup-git'."
    assert-e2e $r (@(get-e2e-events $r @('az.login')).Count -eq 0) 'an interactive run signed in to the Azure CLI again although it was signed in.'
    $auth = get-e2e-interactive-auth $r
    $foreign = @(get-e2e-events $r @('ado.create', 'ado.link', 'ado.vote', 'ado.autocomplete', 'ado.abandon', 'ado.reopen') | Where-Object { $auth -notcontains $_.auth -or $_.actor -ne $r.World.Ado.UserId })
    assert-e2e $r ($foreign.Count -eq 0) "Azure DevOps changes not made as the developer ($($auth -join ' or ')): $(($foreign | ForEach-Object { "$($_.kind) $($_.repo) $($_.auth)" }) -join '; ')"
    if ($r.Spec.Pat)
    {
        assert-e2e $r (-not (test-e2e-output $r $r.World.Ado.Pat)) 'the Azure DevOps PAT was printed.'
    }
    else
    {
        # no PAT given
    }
}

# A developer's successful propagation: one pull request per repository (or the counts in
# $expected_creates), opened one at a time in dependency order, armed as the developer and watched
# (seen in progress) until it merged, $expected_closes closed or abandoned pull requests, a
# notification for each pull request, the saved state, and the final repository state.
function assert-e2e-interactive-success
{
    param(
        [hashtable] $r,
        [hashtable] $expected_creates = @{},
        [int] $expected_closes = 0,
        [switch] $LateCommit
    )
    assert-e2e $r ($r.Run.ExitCode -eq 0) "the propagation must succeed (exit code $($r.Run.ExitCode))."
    $creates = @(get-e2e-final-creates $r)
    foreach ($repo in $e2e_pr_repos)
    {
        $expected = 1
        if ($expected_creates.ContainsKey($repo))
        {
            $expected = $expected_creates[$repo]
        }
        else
        {
            # one pull request
        }
        $count = @(get-e2e-events $r @('gh.create', 'ado.create') $repo).Count
        assert-e2e $r ($count -eq $expected) "expected $expected pull request(s) for $repo, got $count."
        assert-e2e $r (@(get-e2e-events $r @('gh.merged', 'ado.merged') $repo).Count -eq 1) "the pull request for $repo did not merge exactly once."
    }
    $closes = @(get-e2e-events $r @('gh.close', 'ado.abandon'))
    assert-e2e $r ($closes.Count -eq $expected_closes) "expected $expected_closes closed or abandoned pull request(s), got $($closes.Count): $(($closes | ForEach-Object { $_.repo }) -join ', ')."
    $branches = @(get-e2e-events $r @('gh.create', 'ado.create') | Where-Object { $_.repo -ne 'c-build-tools' } | ForEach-Object { if ($_.kind -eq 'gh.create') { $_.head } else { $_.branch } } | Select-Object -Unique)
    assert-e2e $r ($branches.Count -eq 1 -and $branches[0] -match '^new_deps_\d{14}$') "every pull request must come from one new_deps_<timestamp> branch: $($branches -join ', ')."

    # One at a time: the next pull request opens only after the previous one merged. Bottom-up: a
    # pull request opens only after every dependency's pull request merged.
    $ordered = @($creates | Sort-Object -Property Index)
    for ($i = 1; $i -lt $ordered.Count; $i++)
    {
        $previous = get-e2e-merge $r $ordered[$i - 1]
        assert-e2e $r ($previous -and $previous.Index -lt $ordered[$i].Index) "the $($ordered[$i].repo) pull request opened before the $($ordered[$i - 1].repo) pull request merged."
    }
    foreach ($create in $creates)
    {
        foreach ($dep in $r.World.Template.Repos[$create.repo].Deps)
        {
            $dep_create = @($creates | Where-Object { $_.repo -eq $dep }) | Select-Object -First 1
            if ($dep_create)
            {
                $dep_merge = get-e2e-merge $r $dep_create
                assert-e2e $r ($dep_merge -and $dep_merge.Index -lt $create.Index) "the $($create.repo) pull request opened before its dependency $dep merged."
            }
            else
            {
                # c-build-tools has nothing to propagate
            }
        }
    }

    assert-e2e-pr-text $r $creates '[autogenerated]' -Interactive

    $user = $r.World.Ado.UserId
    $state = get-e2e-saved-state $r
    assert-e2e $r ($null -ne $state) 'no propagation_state.json was saved in a single new_deps_* folder.'
    foreach ($create in $creates)
    {
        $repo = $create.repo
        $merge = get-e2e-merge $r $create
        $url = get-e2e-pr-url $create
        if ($create.kind -eq 'ado.create')
        {
            # Linked to the work item once, approved by the developer, set to squash-merge on its own.
            $artifact = "vstfs:///Git/PullRequestId/$($r.World.Ado.ProjectId)/$($r.World.Repos[$repo].Id)/$($create.id)"
            $links = @($r.Ado.WorkItems.'42'.Relations | Where-Object { $_.Rel -eq 'ArtifactLink' -and [System.Uri]::UnescapeDataString($_.Url) -eq $artifact })
            assert-e2e $r ($links.Count -eq 1) "work item 42 has $($links.Count) links to the $repo pull request."
            $votes = @(get-e2e-events $r @('ado.vote') | Where-Object { $_.id -eq $create.id -and $_.user -eq $user -and $_.vote -eq 10 })
            assert-e2e $r ($votes.Count -ge 1) "the developer did not approve the $repo pull request."
            $auto = @(get-e2e-events $r @('ado.autocomplete') | Where-Object { $_.id -eq $create.id -and $_.by -eq $user -and $_.mergeStrategy -eq 'squash' -and $_.deleteSourceBranch })
            assert-e2e $r ($auto.Count -ge 1) "the $repo pull request was not set to auto-complete (squash, delete the branch) by the developer."
            $watched = @(get-e2e-events $r @('ado.observed') $repo | Where-Object { $_.id -eq $create.id -and $_.status -eq 'running' -and $merge -and $_.Index -lt $merge.Index })
            assert-e2e $r ($watched.Count -ge 1) "the run did not watch the $repo pull request's build while it was running."
        }
        else
        {
            $auto = @(get-e2e-events $r @('gh.automerge') | Where-Object { $_.number -eq $create.number -and $_.method -eq 'squash' -and $_.deleteBranch })
            $comment = @(get-e2e-events $r @('gh.comment') | Where-Object { $_.number -eq $create.number -and $_.body -eq '/AzurePipelines run' })
            assert-e2e $r ($auto.Count -ge 1) "squash auto-merge with branch deletion was not enabled for the $repo pull request."
            assert-e2e $r ($comment.Count -ge 1) "the $repo pull request did not get the /AzurePipelines run comment."
            assert-e2e $r ($auto.Count -ge 1 -and $comment.Count -ge 1 -and $auto[0].Index -lt $comment[0].Index) "auto-merge must be enabled before the pipeline comment on the $repo pull request."
            $watched = @(get-e2e-events $r @('gh.observed') $repo | Where-Object { $_.number -eq $create.number -and $_.bucket -eq 'pending' -and $merge -and $_.Index -lt $merge.Index })
            assert-e2e $r ($watched.Count -ge 1) "the run did not watch the $repo pull request's checks while they were running."
        }
        $notified = @(get-e2e-events $r @('notification') | Where-Object { "$($_.text)".Contains($url) })
        assert-e2e $r ($notified.Count -ge 1) "no notification showed the $repo pull request $url."
        if ($state)
        {
            $saved = $state.repo_statuses.$repo
            assert-e2e $r ($saved -and $saved.Status -eq 'updated' -and $saved.PrUrl -eq $url) "the saved state of $repo is '$($saved.Status)' with PR '$($saved.PrUrl)'; expected 'updated' with $url."
        }
        else
        {
            # reported above
        }
    }
    if ($state)
    {
        assert-e2e $r ($state.repo_statuses.'c-build-tools'.Status -eq 'skipped') "the saved state of c-build-tools is '$($state.repo_statuses.'c-build-tools'.Status)'; expected 'skipped'."
    }
    else
    {
        # reported above
    }

    assert-e2e-final-state $r -LateCommit:$LateCommit
}

# The pull request that saves a newly discovered graph to c-build-tools' known_graph.json: opened
# before any propagation pull request, with the fixture graph's edges.
function assert-e2e-known-graph-pr
{
    param([hashtable] $r)
    $prs = @(get-e2e-events $r @('gh.create') 'c-build-tools')
    assert-e2e $r ($prs.Count -eq 1) "expected one known_graph.json pull request in c-build-tools, got $($prs.Count)."
    if ($prs.Count -eq 1)
    {
        $pr = $prs[0]
        assert-e2e $r ($pr.title -ceq '[autogenerated] update known_graph.json') "title of the known_graph.json pull request: '$($pr.title)'."
        assert-e2e $r ($pr.head -match '^update-known-graph-\d{14}$') "branch of the known_graph.json pull request: '$($pr.head)'."
        $first = @(get-e2e-events $r @('gh.create', 'ado.create') | Where-Object { $_.repo -ne 'c-build-tools' }) | Select-Object -First 1
        assert-e2e $r (-not $first -or $pr.Index -lt $first.Index) 'the known_graph.json pull request must open before the propagation pull requests.'
        $show = invoke-fake-git -git_args @("--git-dir=$(get-e2e-bare $r 'c-build-tools')", 'show', "$($pr.headCommit):update_deps/known_graph.json") -AllowFail
        $graph = $null
        try { $graph = $show.StdOut | ConvertFrom-Json } catch { $graph = $null }
        assert-e2e $r ($null -ne $graph) "the known_graph.json pull request has no readable update_deps/known_graph.json: $($show.StdErr)"
        if ($graph)
        {
            foreach ($repo in @($e2e_repo_specs.Keys | Where-Object { $_ -ne 'libuv' }))
            {
                $expected = (@($e2e_repo_specs[$repo].Deps | Where-Object { $_ -ne 'libuv' }) | Sort-Object) -join ','
                $actual = (@($graph.edges.$repo) | Sort-Object) -join ','
                assert-e2e $r ($null -ne $graph.edges.PSObject.Properties[$repo] -and $actual -eq $expected) "known_graph.json edges of ${repo}: '$actual'; expected '$expected'."
            }
            $extra = @($graph.edges.PSObject.Properties | Where-Object { -not $e2e_repo_specs.Contains($_.Name) -or $_.Name -eq 'libuv' } | ForEach-Object { $_.Name })
            assert-e2e $r ($extra.Count -eq 0) "known_graph.json lists repositories outside the graph: $($extra -join ', ')."
            # Later runs clone from these URLs: the real https ones, without .git.
            foreach ($repo in @($e2e_repo_specs.Keys | Where-Object { $_ -ne 'libuv' }))
            {
                $url = [string]$graph.urls.$repo
                if ($e2e_repo_specs[$repo].Host -eq 'github')
                {
                    $ok = ($url -ceq "https://github.com/Azure/$repo")
                }
                else
                {
                    $ok = ($url -cmatch "^https://msazure\.visualstudio\.com/(DefaultCollection/)?One/_git/$([regex]::Escape($repo))$")
                }
                assert-e2e $r $ok "known_graph.json URL of ${repo}: '$url'."
            }
            $extra_urls = @($graph.urls.PSObject.Properties | Where-Object { -not $e2e_repo_specs.Contains($_.Name) -or $_.Name -eq 'libuv' } | ForEach-Object { $_.Name })
            assert-e2e $r ($extra_urls.Count -eq 0) "known_graph.json has URLs of repositories outside the graph: $($extra_urls -join ', ')."
        }
        else
        {
            # reported above
        }
    }
    else
    {
        # reported above
    }
}

# What the first run of a resumed scenario did before it failed: it reported $texts and printed the
# command that resumes it with the same parameters, opened no pull request for $untouched, and did
# not redo the repositories it finished before the failure.
function assert-e2e-first-run-failed
{
    param(
        [hashtable] $r,
        [string[]] $texts,
        [string] $failed_repo,
        [string[]] $untouched
    )
    assert-e2e $r ($r.Runs.Count -eq 2) "expected 2 runs, got $($r.Runs.Count)."
    assert-e2e $r ($r.Runs[0].ExitCode -ne 0) 'the first run must fail.'
    $resume = @('To resume from where it stopped', '-azure_work_item 42', "-root_list $($e2e_roots -join ',')", '-Resume')
    if ($r.Spec.NoCloseFailedPr)
    {
        $resume += '-NoCloseFailedPr'
    }
    else
    {
        # failed pull requests are closed
    }
    foreach ($text in @($texts) + $resume)
    {
        assert-e2e $r (test-e2e-run-output $r 1 $text) "the first run's output does not say '$text'."
    }
    foreach ($repo in $untouched)
    {
        assert-e2e $r (@(get-e2e-events $r @('gh.create', 'ado.create') $repo | Where-Object { $_.run -eq 1 }).Count -eq 0) "the first run opened a pull request for $repo after $failed_repo failed."
    }
    # Repositories finished before the failure are not redone.
    foreach ($repo in @($e2e_pr_repos | Where-Object { $_ -ne $failed_repo -and $untouched -notcontains $_ }))
    {
        $creates = @(get-e2e-events $r @('gh.create', 'ado.create') $repo)
        assert-e2e $r ($creates.Count -eq 1 -and $creates[0].run -eq 1) "$repo was finished by the first run, but has $($creates.Count) pull requests (runs $(($creates | ForEach-Object { $_.run }) -join ', '))."
    }
}

$e2e_all_repos = @('c-build-tools', 'libuv', 'fake-pal', 'fake-logging', 'fake-util', 'FakeLib', 'FakeApp', 'FakeRoot')

# Name: test name. Mode: fixture template. Settings: fake service behavior. NoWorkItem, NoSystemToken,
# NoGhToken, NoCloseFailedPr: how the propagation is invoked. Assert: the scenario's checks.
$e2e_scenarios = @(
    @{
        Name = 'happy_path'
        Mode = 'stale'
        Settings = @{
            Ado = @{
                CompleteAfter = @{ FakeApp = 8 }
                Faults = @(
                    @{ Repo = 'FakeLib'; AfterPolls = 1; Errors = @('503', '503') },
                    @{ Repo = 'FakeApp'; AfterPolls = 2; Errors = @('429') },
                    @{ Repo = 'FakeApp'; AfterPolls = 4; Errors = @('timeout') }
                )
            }
            Gh = @{
                ReadyAfter = @{ 'fake-logging' = 6 }
                Faults = @(@{ Repo = 'fake-logging'; AfterPolls = 2; Errors = @('502') })
                LateCommit = @{ OnMerge = 'fake-pal'; Repo = 'c-build-tools'; Subject = 'Late cbt change' }
            }
        }
        Assert = { param($r) assert-e2e-happy-path $r }
    },
    @{
        Name = 'github_checks_fail'
        Mode = 'stale'
        Settings = @{ Gh = @{ ChecksOutcome = @{ 'fake-pal' = 'fail' } } }
        Assert = {
            param($r)
            assert-e2e-failed $r @('GitHub PR checks failed for fake-pal', 'PR for fake-pal failed')
            $create = @(get-e2e-events $r @('gh.create') 'fake-pal') | Select-Object -First 1
            $closed = @(get-e2e-events $r @('gh.close') 'fake-pal' | Where-Object { $create -and $_.number -eq $create.number })
            assert-e2e $r ($closed.Count -eq 1) 'the failed fake-pal pull request was not closed.'
            assert-e2e-untouched $r @('fake-util', 'FakeLib', 'FakeApp', 'FakeRoot')
            assert-e2e $r ((get-fake-revision (get-e2e-bare $r 'fake-pal') 'refs/heads/master') -eq $r.World.InitialMasters['fake-pal']) 'the failed fake-pal pull request was merged.'
        }
    },
    @{
        Name = 'azure_pr_rejected'
        Mode = 'stale'
        NoCloseFailedPr = $true
        Settings = @{ Ado = @{ Reject = @('FakeLib') } }
        Assert = {
            param($r)
            assert-e2e-failed $r @('was rejected by', 'PR for FakeLib failed')
            $create = @(get-e2e-events $r @('ado.create') 'FakeLib') | Select-Object -First 1
            assert-e2e $r ($null -ne $create) 'no pull request was opened for FakeLib.'
            assert-e2e $r (@(get-e2e-events $r @('ado.abandon')).Count -eq 0) '-NoCloseFailedPr must leave the rejected pull request open.'
            if ($create)
            {
                assert-e2e $r ($r.Ado.Prs."$($create.id)".Status -eq 'active') 'the rejected FakeLib pull request is not active.'
            }
            else
            {
                # reported above
            }
            assert-e2e-untouched $r @('FakeRoot')
        }
    },
    @{
        Name = 'no_push_access'
        Mode = 'stale'
        Settings = @{ Gh = @{ NoPush = @('Azure/fake-util') } }
        Assert = {
            param($r)
            assert-e2e-failed $r @('cannot open PRs', 'Azure/fake-util')
            assert-e2e-untouched $r $e2e_all_repos
        }
    },
    @{
        Name = 'missing_work_item'
        Mode = 'stale'
        NoWorkItem = $true
        Assert = {
            param($r)
            assert-e2e-failed $r @('azure_work_item')
            assert-e2e-untouched $r $e2e_all_repos
        }
    },
    @{
        Name = 'missing_system_token'
        Mode = 'stale'
        NoSystemToken = $true
        Assert = {
            param($r)
            assert-e2e-failed $r @('SYSTEM_ACCESSTOKEN')
            assert-e2e-untouched $r $e2e_all_repos
        }
    },
    @{
        Name = 'missing_gh_token'
        Mode = 'stale'
        NoGhToken = $true
        Assert = {
            param($r)
            assert-e2e-failed $r @('GH_TOKEN')
            assert-e2e-untouched $r $e2e_all_repos
        }
    },
    @{
        Name = 'nothing_to_propagate'
        Mode = 'current'
        Assert = {
            param($r)
            assert-e2e $r ($r.Run.ExitCode -eq 0) "the run must succeed (exit code $($r.Run.ExitCode))."
            assert-e2e-untouched $r $e2e_all_repos
        }
    }
)

# Interactive scenarios: a developer runs propagate_updates.ps1 in a console, signed in to gh and to
# the Azure CLI (WAM), or with -azure_token (Pat). Runs: one entry per run in the same world, with the
# world settings that change before it (a failed run, then its -Resume). BaselineShells: the
# PowerShell editions the baseline runs this scenario with.
#
# The resume scenarios check the baseline with PowerShell 7 only, because with Windows PowerShell
# 5.1 it fails them:
# - Its watchers count checks with (... | Where-Object ...).Count, which is empty for a single
#   match there, so a lone running check counts as finished and a lone failed build is never
#   reported: the run keeps watching forever.
# - Its find-active-azure-pr reads an empty 'az repos pr list' result as one pull request
#   (ConvertFrom-Json does not enumerate arrays there), so -Resume fails on the first Azure DevOps
#   repository that was not updated yet.
# The merged version runs every scenario with both editions.
$e2e_scenarios += @(
    @{
        Name = 'interactive_happy_path'
        Mode = 'interactive'
        Interactive = $true
        Settings = @{
            # Access tokens expire mid-run: the run must sign in again (a WAM token from the CLI).
            Ado = @{ RevokeTokensAfterWrites = 5 }
            Gh = @{ LateCommit = @{ OnMerge = 'fake-pal'; Repo = 'c-build-tools'; Subject = 'Late cbt change' } }
        }
        Assert = {
            param($r)
            assert-e2e-known-graph-pr $r
            assert-e2e-interactive-success $r -LateCommit
        }
    },
    @{
        Name = 'interactive_known_graph_pat'
        Mode = 'interactive-known'
        Interactive = $true
        Pat = $true
        Assert = {
            param($r)
            assert-e2e $r (@(get-e2e-events $r @('gh.create') 'c-build-tools').Count -eq 0) 'a known_graph.json pull request was opened although the known graph matches.'
            assert-e2e $r (@(get-e2e-events $r @('az.token')).Count -eq 0) 'a run with -azure_token asked the Azure CLI for an access token.'
            assert-e2e-interactive-success $r
        }
    },
    @{
        Name = 'interactive_github_checks_fail_resume'
        Mode = 'interactive-known'
        Interactive = $true
        BaselineShells = @('pwsh')
        Settings = @{ Gh = @{ ChecksOutcome = @{ 'fake-util' = 'fail' } } }
        Runs = @(
            @{},
            @{ Resume = $true; Settings = @{ Gh = @{ ChecksOutcome = @{} } } }
        )
        Assert = {
            param($r)
            # The checks of fake-util's pull request fail. (Both versions read a failed check that is
            # not named Build* as passed, wait for auto-merge, and then fail to merge directly.)
            assert-e2e-first-run-failed $r @('PR for repo fake-util could not be merged') 'fake-util' @('FakeLib', 'FakeApp', 'FakeRoot')
            $failed = @(get-e2e-events $r @('gh.create') 'fake-util' | Where-Object { $_.run -eq 1 }) | Select-Object -First 1
            assert-e2e $r ($null -ne $failed) 'the first run opened no fake-util pull request.'
            if ($failed)
            {
                assert-e2e $r (@(get-e2e-events $r @('gh.close') 'fake-util' | Where-Object { $_.number -eq $failed.number -and $_.run -eq 1 }).Count -eq 1) 'the failed fake-util pull request was not closed.'
                assert-e2e $r (@(get-e2e-events $r @('gh.merged') 'fake-util' | Where-Object { $_.number -eq $failed.number }).Count -eq 0) 'the failed fake-util pull request was merged.'
            }
            else
            {
                # reported above
            }
            # -Resume opens a new fake-util pull request and finishes the propagation.
            $retried = @(get-e2e-events $r @('gh.create') 'fake-util' | Where-Object { $_.run -eq 2 })
            assert-e2e $r ($retried.Count -eq 1) "the resumed run opened $($retried.Count) fake-util pull requests; expected 1."
            assert-e2e-interactive-success $r -expected_creates @{ 'fake-util' = 2 } -expected_closes 1
        }
    },
    @{
        Name = 'interactive_azure_build_fails_resume'
        Mode = 'interactive-known'
        Interactive = $true
        NoCloseFailedPr = $true
        BaselineShells = @('pwsh')
        Settings = @{ Ado = @{ BuildOutcome = @{ FakeLib = 'fail' } } }
        Runs = @(
            @{},
            # The new FakeLib build runs long enough that the resumed run must watch it: more polls
            # than the reads either version makes before it starts watching.
            @{ Resume = $true; Settings = @{ Ado = @{ BuildOutcome = @{}; RequeueFailedBuilds = $true; CompleteAfter = @{ FakeLib = 6 } } } }
        )
        Assert = {
            param($r)
            assert-e2e-first-run-failed $r @('failed to complete') 'FakeLib' @('FakeApp', 'FakeRoot')
            $creates = @(get-e2e-events $r @('ado.create') 'FakeLib')
            assert-e2e $r ($creates.Count -eq 1 -and $creates[0].run -eq 1) "expected the first run's FakeLib pull request to be the only one, got $($creates.Count)."
            assert-e2e $r (@(get-e2e-events $r @('ado.build-failed') 'FakeLib' | Where-Object { $_.run -eq 1 }).Count -eq 1) "the FakeLib build did not fail in the first run."
            assert-e2e $r (@(get-e2e-events $r @('ado.abandon')).Count -eq 0) '-NoCloseFailedPr must leave the failed pull request open.'
            assert-e2e $r (@(get-e2e-events $r @('ado.requeue') 'FakeLib').Count -eq 1) 'the failed FakeLib build was not queued again before the resumed run.'
            if ($creates.Count -eq 1)
            {
                $merge = get-e2e-merge $r $creates[0]
                assert-e2e $r ($merge -and $merge.run -eq 2) 'the resumed run did not merge the existing FakeLib pull request.'
                # Pushing to the open pull request would restart its builds and reset its votes.
                assert-e2e $r ($merge -and $merge.head -eq $creates[0].headCommit) 'the resumed run pushed a new commit to the existing FakeLib pull request instead of reusing it as it was.'
                $watched = @(get-e2e-events $r @('ado.observed') 'FakeLib' | Where-Object { $_.run -eq 2 -and $_.status -eq 'running' -and $merge -and $_.Index -lt $merge.Index })
                assert-e2e $r ($watched.Count -ge 1) 'the resumed run did not watch the existing FakeLib pull request until it merged.'
            }
            else
            {
                # reported above
            }
            assert-e2e-interactive-success $r
        }
    },
    @{
        Name = 'interactive_missing_work_item'
        Mode = 'interactive-known'
        Interactive = $true
        NoWorkItem = $true
        Assert = {
            param($r)
            assert-e2e-failed $r @('azure_work_item')
            assert-e2e-untouched $r $e2e_all_repos
            assert-e2e $r (@(Get-ChildItem -LiteralPath (Join-Path $r.World.Path 'agent_work') -Directory -Filter 'new_deps_*' -ErrorAction SilentlyContinue).Count -eq 0) 'the run created a propagation folder before validating its parameters.'
        }
    }
)
