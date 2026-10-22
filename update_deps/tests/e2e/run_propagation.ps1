# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Runs one propagation for test_e2e.ps1, which starts this script as
#   powershell.exe (or pwsh.exe) -Command ". '<this file>' '<run-N.json>'"
# with the environment the run would have.
#
# Pipeline runs follow the Azure-MessagingStore pipeline (build/propagate_deps.yml), which has two steps:
# - A "stamp" step writes the bot identity and an Azure DevOps extraheader into GIT_CONFIG_GLOBAL.
# - A PowerShell@2 inline task (Windows PowerShell 5.1, errorActionPreference continue) runs
#   "& $script <parameters>; exit $LASTEXITCODE".
# Interactive runs follow a developer running propagate_updates.ps1 in a console: the runner gives
# the process a hidden console of its own, and this script records a transcript of what the run
# shows. Nobody answers prompts: a run that asks for input (Read-Host) ends with exit code 97.
# Windows notifications are recorded instead of shown, and the only web request served is the
# anonymous Azure DevOps request that reveals the organization's tenant.
#
# fake_ado.ps1 serves Azure DevOps REST calls, and in interactive runs fake_az.ps1 serves the az
# command. Sleeps take no time but are counted; a run that never finishes ends with exit code 98
# instead of hanging.
param([string] $FakeRunFile)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'fake_services.ps1')
$fake_run = [System.IO.File]::ReadAllText($FakeRunFile) | ConvertFrom-Json
$fake_interactive = [bool]$fake_run.Interactive
. (Join-Path $PSScriptRoot 'fake_ado.ps1')
if ($fake_interactive)
{
    . (Join-Path $PSScriptRoot 'fake_az.ps1')
}
else
{
    # pipeline runs never use the Azure CLI
}

# End the run now with $exit_code.
function stop-fake-driver
{
    param(
        [int] $exit_code,
        [string] $message
    )
    Write-Host $message
    if ($fake_interactive)
    {
        try { Stop-Transcript | Out-Null } catch { }
    }
    else
    {
        # no transcript
    }
    [Console]::Out.Flush()
    [Environment]::Exit($exit_code)
}

# Virtual time: a sleep only counts its calls and seconds. Interactive scripts wait in 100 ms steps,
# so their budget is in seconds as well as calls.
$global:FakeSleepCalls = 0
$global:FakeSleepSeconds = 0.0
$global:FakeSleepBudget = [int]$global:FakeAdoWorld.SleepBudget
$global:FakeSleepBudgetSeconds = [double]$global:FakeAdoWorld.SleepBudgetSeconds
$global:FakeSleepRealMilliseconds = 5
if ($fake_interactive)
{
    $global:FakeSleepRealMilliseconds = 0
}
else
{
    # a short real pause keeps pipeline polling loops from spinning
}

# Start-Sleep, Invoke-WebRequest (below) and Invoke-RestMethod (fake_ado.ps1) keep the parameters
# this PowerShell edition declares for them (see set-fake-cmdlet-proxy).
set-fake-cmdlet-proxy -name 'Start-Sleep' -body @'
    $global:FakeSleepCalls++
    $fake_seconds = 0.0
    if ($PSBoundParameters.ContainsKey('Seconds'))
    {
        $fake_seconds += [double]$PSBoundParameters['Seconds']
    }
    else
    {
        # no seconds given
    }
    if ($PSBoundParameters.ContainsKey('Milliseconds'))
    {
        $fake_seconds += [double]$PSBoundParameters['Milliseconds'] / 1000.0
    }
    else
    {
        # no milliseconds given
    }
    if ($PSBoundParameters.ContainsKey('Duration'))
    {
        $fake_seconds += $PSBoundParameters['Duration'].TotalSeconds
    }
    else
    {
        # no duration given (PowerShell 7.3+ only)
    }
    $global:FakeSleepSeconds += $fake_seconds
    if ($global:FakeSleepCalls -gt $global:FakeSleepBudget -or ($global:FakeSleepBudgetSeconds -gt 0 -and $global:FakeSleepSeconds -gt $global:FakeSleepBudgetSeconds))
    {
        add-fake-event @{ kind = 'driver.budget-exceeded'; sleeps = $global:FakeSleepCalls; seconds = $global:FakeSleepSeconds }
        stop-fake-driver 98 "e2e driver: $($global:FakeSleepCalls) sleeps ($([int]$global:FakeSleepSeconds) virtual seconds); the propagation is not finishing"
    }
    else
    {
        [System.Threading.Thread]::Sleep($global:FakeSleepRealMilliseconds)
    }
'@

if ($fake_interactive)
{
    Start-Transcript -LiteralPath $fake_run.Transcript -Force | Out-Null
    # A wide console buffer, so formatted output (errors) is not wrapped mid-message.
    try
    {
        $fake_raw_ui = $Host.UI.RawUI
        $fake_raw_ui.BufferSize = New-Object System.Management.Automation.Host.Size (4096, [Math]::Max(3000, $fake_raw_ui.BufferSize.Height))
    }
    catch
    {
        add-fake-event @{ kind = 'driver.console'; message = "could not widen the console buffer: $($_.Exception.Message)" }
    }

    function global:Read-Host
    {
        param(
            [Parameter(Position = 0)][object] $Prompt,
            [switch] $AsSecureString,
            [switch] $MaskInput
        )
        add-fake-event @{ kind = 'driver.prompt'; prompt = "$Prompt" }
        stop-fake-driver 97 "e2e driver: the propagation asked for input ($Prompt); nobody answers prompts in these tests"
    }

    # A Windows notification that records what it would show.
    function new-fake-notify-icon
    {
        $icon = [pscustomobject]@{ Icon = $null; Visible = $false; BalloonTipTitle = ''; BalloonTipText = ''; BalloonTipIcon = $null; Text = '' }
        $icon | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value {
            param($timeout)
            add-fake-event @{ kind = 'notification'; title = $this.BalloonTipTitle; text = $this.BalloonTipText; visible = $this.Visible }
        }
        $icon | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $icon
    }

    function global:New-Object
    {
        [CmdletBinding(DefaultParameterSetName = 'Net')]
        param(
            [Parameter(ParameterSetName = 'Net', Mandatory = $true, Position = 0)][string] $TypeName,
            [Parameter(ParameterSetName = 'Net', Position = 1)][Alias('Args')][object[]] $ArgumentList,
            [Parameter(ParameterSetName = 'Com', Mandatory = $true)][string] $ComObject,
            [Parameter(ParameterSetName = 'Com')][switch] $Strict,
            [System.Collections.IDictionary] $Property
        )
        if ($PSCmdlet.ParameterSetName -eq 'Net' -and $TypeName -eq 'System.Windows.Forms.NotifyIcon')
        {
            new-fake-notify-icon
        }
        else
        {
            # A statement, not a return value: the created object (even an empty collection) passes through as is.
            Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
        }
    }

    # The anonymous request that reveals the tenant owning an Azure DevOps organization: 401 with the
    # X-VSS-ResourceTenant header, as Windows PowerShell (WebHeaderCollection) and PowerShell 7
    # (HttpResponseMessage) report it.
    function new-fake-tenant-probe-error
    {
        $tenant = $global:FakeAdoWorld.Ado.TenantId
        if ($PSVersionTable.PSEdition -eq 'Core')
        {
            $response = New-Object System.Net.Http.HttpResponseMessage ([System.Net.HttpStatusCode]::Unauthorized)
            [void]$response.Headers.TryAddWithoutValidation('X-VSS-ResourceTenant', $tenant)
        }
        else
        {
            $headers = New-Object System.Net.WebHeaderCollection
            $headers.Add('X-VSS-ResourceTenant', $tenant)
            $response = [pscustomobject]@{ StatusCode = 401; Headers = $headers }
        }
        $exception = New-Object System.Exception ('Response status code does not indicate success: 401 (Unauthorized).')
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
        return (New-Object System.Management.Automation.ErrorRecord ($exception, 'WebCmdletWebResponseException', 'InvalidOperation', $null))
    }

    set-fake-cmdlet-proxy -name 'Invoke-WebRequest' -body @'
        $fake_url = get-fake-request-url $PSBoundParameters['Uri']
        $fake_headers = $PSBoundParameters['Headers']
        if ($fake_url -match '^https://dev\.azure\.com/[^/]+/_apis/connectionData' -and -not ($fake_headers -and $fake_headers['Authorization']))
        {
            add-fake-event @{ kind = 'web.tenant-probe'; url = $fake_url }
            throw (new-fake-tenant-probe-error)
        }
        else
        {
            add-fake-event @{ kind = 'web.unexpected'; url = $fake_url }
            throw 'The end-to-end tests block Invoke-WebRequest: no network access is allowed.'
        }
'@
}
else
{
    set-fake-cmdlet-proxy -name 'Invoke-WebRequest' -body @'
        add-fake-event @{ kind = 'web.unexpected'; url = (get-fake-request-url $PSBoundParameters['Uri']) }
        throw 'The end-to-end tests block Invoke-WebRequest: no network access is allowed.'
'@

    # Step 1: "Stamp bot git identity + ADO git auth (isolated global config)".
    & git config --global user.name 'Azure-MessagingStore Deps Bot'
    & git config --global user.email 'azure-messagingstore-deps-bot@noreply.microsoft.com'
    & git config --global http.https://msazure.visualstudio.com.extraheader "AUTHORIZATION: bearer $($env:SYSTEM_ACCESSTOKEN)"
}

# Step 2 (pipeline), or the developer's command: the propagation.
Set-Location -LiteralPath $fake_run.WorkDirectory
$fake_parameters = @{}
foreach ($fake_property in $fake_run.Parameters.PSObject.Properties)
{
    $fake_parameters[$fake_property.Name] = $fake_property.Value
}
$fake_logged_parameters = @{}
foreach ($fake_name in $fake_parameters.Keys)
{
    if ($fake_name -eq 'azure_token')
    {
        $fake_logged_parameters[$fake_name] = '<pat>'
    }
    else
    {
        $fake_logged_parameters[$fake_name] = $fake_parameters[$fake_name]
    }
}
add-fake-event @{ kind = 'driver.start'; entry = $fake_run.EntryScript; parameters = $fake_logged_parameters; edition = $PSVersionTable.PSEdition }
# A script that ends without "exit" leaves the exit code of its last native command.
$global:LASTEXITCODE = 0
try
{
    & $fake_run.EntryScript @fake_parameters
}
catch
{
    add-fake-event @{ kind = 'driver.exception'; message = "$($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" }
    Write-Host "e2e driver: the propagation script threw: $($_.Exception.Message)"
    $global:LASTEXITCODE = 1
}
$fake_exit_code = $LASTEXITCODE
add-fake-event @{ kind = 'driver.end'; exitCode = $fake_exit_code; sleeps = $global:FakeSleepCalls; seconds = $global:FakeSleepSeconds }
if ($fake_interactive)
{
    try { Stop-Transcript | Out-Null } catch { }
}
else
{
    # no transcript
}
exit $fake_exit_code
