# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Fake Azure CLI for the interactive end-to-end tests. run_propagation.ps1 dot-sources this file after
# fake_ado.ps1, so global:az serves the commands the interactive scripts run from the same fake
# Azure DevOps service the REST calls reach. Both versions call az by name, so the function shadows
# the real CLI (the runner also puts an az.exe tripwire on PATH in case anything bypasses it).
#
# It models the Azure CLI 2.x behavior the scripts depend on: --output json and tsv, the --query
# expressions they use, exit codes through $LASTEXITCODE, and the azure-devops extension, which
# authenticates with the PAT from 'az devops login' if there is one and otherwise with the
# 'az login' (WAM) account. Reading a pull request ('az repos pr show') counts as a status poll,
# like a REST read. 'az account get-access-token' issues tokens the REST fake accepts.

# The --query expressions the scripts use, by name.
$global:FakeAzQueries = @{
    "[?name=='azure-devops'].name" = 'extension-name'
    '{ProjectId:repository.project.id, ProjectName:repository.project.name, OrgUrl:repository.project.url, RepoName:repository.name}' = 'pr-project'
    '[].{Policy:configuration.type.displayName, Status:status, BuildId:context.buildId, ProjectId:configuration.settings.scope[0].repositoryId, IsBlocking:configuration.isBlocking}' = 'policy-summary'
}

# Options that take several values (az reads values up to the next option).
$global:FakeAzMultiValueOptions = @('--route-parameters', '--defaults', '--work-items', '--description', '--query-parameters')
$global:FakeAzSwitches = @('-h', '--help', '--list', '--debug', '--verbose', '--only-show-errors', '--yes', '-y')

# Split az arguments into the command words and the options.
function split-fake-az-arguments
{
    param([object[]] $argv)
    $command = New-Object System.Collections.ArrayList
    $options = @{}
    $i = 0
    while ($i -lt $argv.Count -and -not ([string]$argv[$i]).StartsWith('-'))
    {
        [void]$command.Add([string]$argv[$i])
        $i++
    }
    while ($i -lt $argv.Count)
    {
        $name = [string]$argv[$i]
        $i++
        if ($name -eq '-o')
        {
            $name = '--output'
        }
        elseif ($name -eq '--org')
        {
            $name = '--organization'
        }
        else
        {
            # canonical name
        }
        if ($global:FakeAzSwitches -contains $name)
        {
            $options[$name] = $true
        }
        elseif ($global:FakeAzMultiValueOptions -contains $name)
        {
            $values = New-Object System.Collections.ArrayList
            while ($i -lt $argv.Count -and -not ([string]$argv[$i] -match '^--?[A-Za-z]'))
            {
                [void]$values.Add([string]$argv[$i])
                $i++
            }
            $options[$name] = @($values)
        }
        elseif ($name.StartsWith('-') -and $i -lt $argv.Count)
        {
            $options[$name] = [string]$argv[$i]
            $i++
        }
        else
        {
            $options[$name] = $true
        }
    }
    return @{ Command = ($command -join ' '); Options = $options }
}

# The identity az authenticates Azure DevOps commands with, or $null when signed out.
function get-fake-az-caller
{
    $az = $global:FakeAdoState.Az
    $user = get-fake-ado-user
    if ($az.Pat)
    {
        return @{ Kind = 'az-pat'; Id = $user.Id; Name = $user.Name }
    }
    elseif ($az.LoggedIn)
    {
        return @{ Kind = 'az-wam'; Id = $user.Id; Name = $user.Name }
    }
    else
    {
        return $null
    }
}

# Output like az: JSON as the lines of an indented document, or tsv values.
function write-fake-az-output
{
    param(
        $value,
        [string] $format
    )
    if ($format -eq 'tsv')
    {
        foreach ($item in @($value))
        {
            [string]$item
        }
    }
    else
    {
        (ConvertTo-Json -InputObject $value -Depth 30) -split "`r?`n"
    }
}

function get-fake-az-query-result
{
    param(
        $value,
        [string] $query
    )
    # Array results are returned with the comma operator so a single item stays an array, as az prints it.
    $name = $global:FakeAzQueries[$query]
    if ($name -eq 'extension-name')
    {
        return ,@($value | Where-Object { $_.name -eq 'azure-devops' } | ForEach-Object { $_.name })
    }
    elseif ($name -eq 'pr-project')
    {
        return [ordered]@{ ProjectId = $value.repository.project.id; ProjectName = $value.repository.project.name; OrgUrl = $value.repository.project.url; RepoName = $value.repository.name }
    }
    elseif ($name -eq 'policy-summary')
    {
        return ,@($value | ForEach-Object {
            [ordered]@{ Policy = $_.configuration.type.displayName; Status = $_.status; BuildId = $_.context.buildId; ProjectId = @($_.configuration.settings.scope)[0].repositoryId; IsBlocking = $_.configuration.isBlocking }
        })
    }
    else
    {
        throw "fake az does not support --query $query"
    }
}

function get-fake-az-pr
{
    param([hashtable] $options)
    $id = [string]$options['--id']
    if ($id -notmatch '^\d+$')
    {
        throw (new-fake-ado-error 400 "argument --id: invalid int value: '$id'")
    }
    else
    {
        return (get-fake-ado-pr-by-id $id)
    }
}

function test-fake-az-true
{
    param($value)
    return ([string]$value -match '^(true|yes|on|1)$')
}

# Run one az command. Returns @{ Exit; Value; Error }: Value is printed in the --output format.
function invoke-fake-az-command
{
    param(
        [string] $command,
        [hashtable] $options,
        [object[]] $piped
    )
    $state = $global:FakeAdoState
    $az = $state.Az
    if ($command -eq 'extension list')
    {
        return @{ Exit = 0; Value = @(@{ name = 'azure-devops'; version = '1.0.1'; extensionType = 'whl' }) }
    }
    elseif ($command -eq 'extension add')
    {
        return @{ Exit = 0; Value = $null }
    }
    elseif ($command -eq 'devops' -and ($options['-h'] -or $options['--help']))
    {
        return @{ Exit = 0; Text = @('Group', '    az devops : Manage Azure DevOps organization level operations.') }
    }
    elseif ($command -match '^config set( |$)')
    {
        return @{ Exit = 0; Value = $null }
    }
    elseif ($command -eq 'devops login')
    {
        $pat = (@($piped) -join '').Trim()
        if ($pat -and $pat -ceq $global:FakeAdoWorld.Ado.Pat)
        {
            $az.Pat = $pat
            save-fake-ado-state
            add-fake-event @{ kind = 'az.devops-login' }
            return @{ Exit = 0; Value = $null }
        }
        else
        {
            return @{ Exit = 1; Error = 'Failed to authenticate using the supplied token.' }
        }
    }
    elseif ($command -eq 'devops configure')
    {
        if ($options['--list'])
        {
            $lines = @('[defaults]')
            foreach ($key in @($az.Defaults.Keys | Sort-Object))
            {
                $lines += "$key = $($az.Defaults[$key])"
            }
            return @{ Exit = 0; Text = $lines }
        }
        else
        {
            foreach ($pair in @($options['--defaults']))
            {
                $parts = $pair -split '=', 2
                $az.Defaults[$parts[0]] = $parts[1]
            }
            save-fake-ado-state
            return @{ Exit = 0; Value = $null }
        }
    }
    elseif ($command -eq 'login')
    {
        $az.LoggedIn = $true
        save-fake-ado-state
        add-fake-event @{ kind = 'az.login' }
        return @{ Exit = 0; Value = @(@{ name = 'Fake subscription'; tenantId = $global:FakeAdoWorld.Az.HomeTenantId; user = @{ name = $global:FakeAdoWorld.Az.Account; type = 'user' } }) }
    }
    elseif ($command -eq 'account show')
    {
        if ($az.LoggedIn)
        {
            return @{ Exit = 0; Value = @{ name = 'Fake subscription'; tenantId = $global:FakeAdoWorld.Az.HomeTenantId; user = @{ name = $global:FakeAdoWorld.Az.Account; type = 'user' } } }
        }
        else
        {
            return @{ Exit = 1; Error = "Please run 'az login' to setup account." }
        }
    }
    elseif ($command -eq 'account get-access-token')
    {
        if (-not $az.LoggedIn)
        {
            return @{ Exit = 1; Error = "Please run 'az login' to setup account." }
        }
        else
        {
            # signed in
        }
        $tenant = [string]$options['--tenant']
        if (-not $tenant)
        {
            $tenant = $global:FakeAdoWorld.Az.HomeTenantId
        }
        else
        {
            # a token for the requested tenant
        }
        $resource = [string]$options['--resource']
        $token = 'fake-wam-' + [guid]::NewGuid().ToString('N')
        [void]$state.Tokens.Add(@{ Token = $token; Resource = $resource; Tenant = $tenant; Revoked = $false })
        save-fake-ado-state
        add-fake-event @{ kind = 'az.token'; resource = $resource; tenant = $tenant; issued = $state.Tokens.Count }
        $expires = [DateTimeOffset]::UtcNow.AddHours(1)
        return @{ Exit = 0; Value = [ordered]@{ accessToken = $token; expiresOn = $expires.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss.ffffff'); expires_on = $expires.ToUnixTimeSeconds(); subscription = [guid]::Empty.ToString(); tenant = $tenant; tokenType = 'Bearer' } }
    }
    else
    {
        # an Azure DevOps command
    }

    $caller = get-fake-az-caller
    if (-not $caller)
    {
        return @{ Exit = 1; Error = 'Before you can run Azure DevOps commands, you need to run the login command (az login if using AAD/MSA identity else az devops login if using PAT token) to setup credential.' }
    }
    else
    {
        # authenticated
    }
    if ($command -eq 'repos pr list')
    {
        $repo = get-fake-ado-repo ([string]$options['--repository'])
        if (-not $repo)
        {
            throw (new-fake-ado-error 404 "TF401019: The Git repository with name or identifier $($options['--repository']) does not exist or you do not have permissions for the operation you are attempting.")
        }
        else
        {
            # known repository
        }
        $status = 'active'
        if ($options['--status'])
        {
            $status = [string]$options['--status']
        }
        else
        {
            # active by default
        }
        $source = $null
        if ($options['--source-branch'])
        {
            $source = 'refs/heads/' + ([string]$options['--source-branch'] -replace '^refs/heads/', '')
        }
        else
        {
            # any source branch
        }
        $target = $null
        if ($options['--target-branch'])
        {
            $target = 'refs/heads/' + ([string]$options['--target-branch'] -replace '^refs/heads/', '')
        }
        else
        {
            # any target branch
        }
        return @{ Exit = 0; Value = @(get-fake-ado-pr-list -repo $repo -status $status -source $source -target $target -top 0) }
    }
    elseif ($command -eq 'repos pr show')
    {
        $pr = get-fake-az-pr $options
        return @{ Exit = 0; Value = (get-fake-ado-pr ([string]$pr.Id)) }
    }
    elseif ($command -eq 'repos pr create')
    {
        $repo = get-fake-ado-repo ([string]$options['--repository'])
        if (-not $repo -or ($options['--project'] -and -not (test-fake-ado-project ([string]$options['--project']))))
        {
            throw (new-fake-ado-error 404 "TF401019: The Git repository with name or identifier $($options['--repository']) does not exist or you do not have permissions for the operation you are attempting.")
        }
        else
        {
            # known repository
        }
        $request = [pscustomobject]@{
            sourceRefName = 'refs/heads/' + ([string]$options['--source-branch'] -replace '^refs/heads/', '')
            targetRefName = 'refs/heads/' + ([string]$options['--target-branch'] -replace '^refs/heads/', '')
            title = [string]$options['--title']
            description = (@($options['--description']) -join "`n")
        }
        return @{ Exit = 0; Value = (new-fake-ado-pr -caller $caller -repo $repo -request $request) }
    }
    elseif ($command -eq 'repos pr work-item add')
    {
        $pr = get-fake-az-pr $options
        $work_items = New-Object System.Collections.ArrayList
        foreach ($id in @($options['--work-items']))
        {
            $work_item = get-fake-ado-work-item-by-id $id
            add-fake-ado-work-item-link -caller $caller -work_item $work_item -rel 'ArtifactLink' -url (get-fake-ado-artifact-url $pr) -name 'Pull Request'
            [void]$work_items.Add((get-fake-ado-work-item-view $work_item))
        }
        return @{ Exit = 0; Value = @($work_items) }
    }
    elseif ($command -eq 'repos pr set-vote')
    {
        $pr = get-fake-az-pr $options
        $votes = @{ approve = 10; 'approve-with-suggestions' = 5; reset = 0; 'wait-for-author' = -5; reject = -10 }
        $vote = [string]$options['--vote']
        if (-not $votes.ContainsKey($vote))
        {
            throw (new-fake-ado-error 400 "argument --vote: invalid choice: '$vote'")
        }
        else
        {
            return @{ Exit = 0; Value = (set-fake-ado-vote -caller $caller -pr $pr -user $caller.Id -vote $votes[$vote]) }
        }
    }
    elseif ($command -eq 'repos pr update')
    {
        $pr = get-fake-az-pr $options
        $set_by = $null
        $completion = $null
        if ($options.ContainsKey('--auto-complete'))
        {
            if (test-fake-az-true $options['--auto-complete'])
            {
                $set_by = $caller.Id
            }
            else
            {
                add-fake-event @{ kind = 'az.unexpected'; reason = 'auto-complete turned off'; args = $global:FakeAzArgs }
            }
            $strategy = 'noFastForward'
            if (test-fake-az-true $options['--squash'])
            {
                $strategy = 'squash'
            }
            else
            {
                # a merge commit
            }
            $completion = [pscustomobject]@{ mergeStrategy = $strategy; deleteSourceBranch = (test-fake-az-true $options['--delete-source-branch']) }
        }
        else
        {
            # no auto-complete change
        }
        return @{ Exit = 0; Value = (update-fake-ado-pr -caller $caller -pr $pr -status ([string]$options['--status']) -auto_complete_set_by $set_by -completion_options $completion) }
    }
    elseif ($command -eq 'repos pr policy list')
    {
        $pr = get-fake-az-pr $options
        return @{ Exit = 0; Value = @(get-fake-ado-pr-evaluations $pr) }
    }
    elseif ($command -eq 'devops invoke' -and $options['--area'] -eq 'build' -and $options['--resource'] -eq 'timeline')
    {
        $build_id = 0
        foreach ($pair in @($options['--route-parameters']))
        {
            if ($pair -match '^buildId=(\d+)$')
            {
                $build_id = [int]$Matches[1]
            }
            else
            {
                # project or another route parameter
            }
        }
        return @{ Exit = 0; Value = (get-fake-ado-timeline $build_id) }
    }
    else
    {
        add-fake-event @{ kind = 'az.unexpected'; reason = 'unsupported command'; args = $global:FakeAzArgs }
        return @{ Exit = 2; Error = "fake az: unsupported command az $command" }
    }
}

function global:az
{
    # Callers may run with -ErrorAction Stop; the fake's own work must not turn into terminating errors.
    $ErrorActionPreference = 'Continue'
    $argv = @($args | ForEach-Object { [string]$_ })
    $piped = @($input)
    $global:FakeAzArgs = $argv
    $parsed = split-fake-az-arguments $argv
    $result = $null
    try
    {
        $result = invoke-fake-az-command -command $parsed.Command -options $parsed.Options -piped $piped
    }
    catch
    {
        if ($_.Exception.FakeAdoError)
        {
            $message = $_.Exception.Message
            if ($_.ErrorDetails -and $_.ErrorDetails.Message)
            {
                try { $message = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { $message = $_.ErrorDetails.Message }
            }
            else
            {
                # no service message
            }
            $result = @{ Exit = 1; Error = $message }
        }
        else
        {
            add-fake-event @{ kind = 'fake.error'; source = 'az'; message = "$($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" }
            $result = @{ Exit = 1; Error = "fake az internal error: $($_.Exception.Message)" }
        }
    }
    $caller = get-fake-az-caller
    $auth = $null
    if ($caller)
    {
        $auth = $caller.Kind
    }
    else
    {
        # signed out
    }
    add-fake-event @{ kind = 'az.call'; command = $parsed.Command; args = $argv; exitCode = $result.Exit; auth = $auth; error = $result.Error }
    if ($result.Error)
    {
        # az reports errors on stderr, which callers either discard or show.
        [Console]::Error.WriteLine("ERROR: $($result.Error)")
    }
    else
    {
        # no error
    }
    if ($result.Exit -eq 0)
    {
        if ($result.Text)
        {
            $result.Text
        }
        elseif ($null -ne $result.Value)
        {
            $value = $result.Value
            if ($parsed.Options['--query'])
            {
                $value = get-fake-az-query-result -value $value -query ([string]$parsed.Options['--query'])
            }
            else
            {
                # the whole result
            }
            write-fake-az-output -value $value -format ([string]$parsed.Options['--output'])
        }
        else
        {
            # no output
        }
    }
    else
    {
        # failed
    }
    $global:LASTEXITCODE = $result.Exit
}
