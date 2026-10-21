# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# Logging, secret redaction, and time-bounded native command helpers shared by both modes.
# Pipeline mode writes timestamped lines mapped to Azure DevOps log commands; interactive mode
# writes plain colored messages.

# True when propagate_updates.ps1 runs with -Pipeline.
function test-pipeline-mode
{
    return ($script:propagation_mode -eq 'pipeline')
}

# Secret values to scrub from any logged text.
$script:RedactValues = @()

# Register a secret so that it is scrubbed from all logged text.
function add-redaction-value
{
    param([string] $Value)
    if ($Value -and $Value.Length -ge 6 -and ($script:RedactValues -notcontains $Value))
    {
        $script:RedactValues += $Value
    }
    else
    {
        # empty, too short to redact safely, or already registered
    }
}

foreach ($name in @('SYSTEM_ACCESSTOKEN', 'GH_TOKEN', 'AZURE_DEVOPS_EXT_PAT', 'ghToken'))
{
    add-redaction-value ([Environment]::GetEnvironmentVariable($name))
}

# Replace any known secret value or common token shape with a placeholder.
function Protect-Secret
{
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($s in $script:RedactValues)
    {
        if ($s) { $Text = $Text.Replace($s, '***REDACTED***') }
    }
    $Text = [regex]::Replace($Text, 'gh[pousr]_[A-Za-z0-9]{20,}', '***REDACTED***')
    $Text = [regex]::Replace($Text, '(?i)(authorization:\s*(bearer|basic)\s+)\S+', '$1***REDACTED***')
    return $Text
}

# Write a redacted log line. Levels: INFO, WARN, ERROR, DEBUG, STEP.
function Write-Log
{
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG', 'STEP')][string] $Level = 'INFO',
        [Parameter(ValueFromRemainingArguments = $true)][object[]] $Message
    )
    $text = Protect-Secret (($Message | ForEach-Object { "$_" }) -join ' ')
    if (test-pipeline-mode)
    {
        $line = "[{0}] [{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $text
        switch ($Level)
        {
            'ERROR' { Write-Host "##[error]$line" }
            'WARN'  { Write-Host "##[warning]$line" }
            'STEP'  { Write-Host "##[section]$line" }
            default { Write-Host $line }
        }
    }
    else
    {
        switch ($Level)
        {
            'ERROR' { Write-Host $text -ForegroundColor Red }
            'WARN'  { Write-Host $text -ForegroundColor Yellow }
            'STEP'  { Write-Host "`n$text" -ForegroundColor Cyan }
            'DEBUG' { Write-Host $text -ForegroundColor DarkGray }
            default { Write-Host $text }
        }
    }
}

# Run a native executable, logging the command, its output, and exit code. Authentication is
# provided out of band (git extraheader / env tokens), so arguments are safe to log after
# redaction. Returns a pscustomobject with ExitCode and Output.
function Invoke-Logged
{
    param(
        [Parameter(Mandatory = $true)][string] $File,
        [string[]] $Arguments = @(),
        [int] $TimeoutSec = 120,
        [int] $MaxAttempts = 1,
        [switch] $AllowFail
    )
    Write-Log INFO ("exec: {0} {1}" -f $File, ($Arguments -join ' '))
    $run = Invoke-NativeWithRetry -File $File -Arguments $Arguments -TimeoutSec $TimeoutSec -MaxAttempts $MaxAttempts
    $output = @($run.StdOut, $run.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($line in $output)
    {
        foreach ($part in ($line -split "`r?`n"))
        {
            if ($part) { Write-Log DEBUG ("  | {0}" -f $part) }
        }
    }
    Write-Log INFO ("exit {0}: {1}" -f $run.ExitCode, $File)
    if ($run.ExitCode -ne 0 -and -not $AllowFail)
    {
        Write-Log ERROR ("command failed ({0}): {1} {2}" -f $run.ExitCode, $File, ($Arguments -join ' '))
    }
    return [pscustomobject]@{ ExitCode = $run.ExitCode; Output = $output; TimedOut = $run.TimedOut }
}

# Quote one argument for a Windows command line, following the CommandLineToArgvW parsing rules.
function ConvertTo-NativeArgument
{
    param([string] $Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]')
    {
        return $Value
    }
    # Double the backslashes that precede an embedded quote or the closing quote, and escape quotes.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# Run a native executable with a wall-clock limit so a network call that is never answered cannot
# stall the run. On timeout the process is killed and ExitCode is -1. Never throws: a failure to
# start is reported as ExitCode -1 with the reason in StdErr. StdOut and StdErr are kept apart so
# JSON on stdout is never mixed with diagnostics on stderr.
function Invoke-NativeWithTimeout
{
    param(
        [Parameter(Mandatory = $true)][string] $File,
        [string[]] $Arguments = @(),
        [int] $TimeoutSec = 120
    )
    $result = [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false }
    $proc = $null
    try
    {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Command -Name $File -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path
        $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
        # Match PowerShell's own native invocation, which runs the child in the current location.
        $psi.WorkingDirectory = (Get-Location).ProviderPath
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if ($proc.WaitForExit($TimeoutSec * 1000))
        {
            $result.ExitCode = $proc.ExitCode
        }
        else
        {
            $result.TimedOut = $true
            # Kill the whole tree: a surviving child (e.g. git-remote-https under git) would keep the
            # hung connection alive and the output pipes open. The cleanup itself is time-bounded too.
            try
            {
                $kill_info = New-Object System.Diagnostics.ProcessStartInfo
                $kill_info.FileName = 'taskkill.exe'
                $kill_info.Arguments = "/PID $($proc.Id) /T /F"
                $kill_info.UseShellExecute = $false
                $kill_info.CreateNoWindow = $true
                # taskkill prints one short line per process; redirecting keeps it out of the log.
                $kill_info.RedirectStandardOutput = $true
                $kill_info.RedirectStandardError = $true
                $killer = [System.Diagnostics.Process]::Start($kill_info)
                [void]$killer.WaitForExit(10000)
                $killer.Dispose()
            }
            catch { }
            try { $proc.Kill() } catch { }
            [void]$proc.WaitForExit(10000)
        }
        # Children orphaned by a kill can keep the pipes open; never wait on them indefinitely.
        if ($stdout.Wait(10000)) { $result.StdOut = $stdout.Result }
        if ($stderr.Wait(10000)) { $result.StdErr = $stderr.Result }
        if ($result.TimedOut)
        {
            $result.StdErr = "timed out after $TimeoutSec s. " + $result.StdErr
        }
    }
    catch
    {
        $result.StdErr = "could not run ${File}: $($_.Exception.Message)"
    }
    finally
    {
        if ($proc) { $proc.Dispose() }
    }
    return $result
}

# Run an idempotent native operation with bounded retries. Callers should not use this for commands
# that can create duplicate remote state unless the command itself is safe to repeat.
function Invoke-NativeWithRetry
{
    param(
        [Parameter(Mandatory = $true)][string] $File,
        [string[]] $Arguments = @(),
        [int] $TimeoutSec = 120,
        [int] $MaxAttempts = 3,
        [int] $RetryDelaySec = 5
    )
    $result = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++)
    {
        $result = Invoke-NativeWithTimeout -File $File -Arguments $Arguments -TimeoutSec $TimeoutSec
        if ($result.ExitCode -eq 0)
        {
            break
        }
        if ($attempt -lt $MaxAttempts)
        {
            Write-Log WARN ("{0} failed or timed out (attempt {1}/{2}); retrying in {3}s" -f $File, $attempt, $MaxAttempts, $RetryDelaySec)
            Start-Sleep -Seconds $RetryDelaySec
        }
    }
    return $result
}
