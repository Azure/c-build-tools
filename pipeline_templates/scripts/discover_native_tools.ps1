# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS
    Finds native build tools (CMake, MSBuild, CTest, dumpbin, vstest, midl, TlbImp, appverif) for the
    given architecture and publishes their paths as pipeline variables.

.DESCRIPTION
    Called by pipeline_templates/discover_native_tools.yml, which documents the output variables.
    Kept out of the template so the script text is not repeated in every job of the expanded
    pipeline YAML (Azure DevOps rejects pipelines whose expanded YAML is too large).

    The template comes from the c_build_tools pipeline resource while this script comes from the
    consumer's c-build-tools checkout, so the two can be at different commits. ContractVersion
    turns a mismatch into a hard failure. Bump it here and in the template whenever the parameters change
    or output variables are removed or renamed; adding output variables needs no bump.

.PARAMETER Architecture
    Target architecture: x64, x86 or ARM64.

.PARAMETER ContractVersion
    Contract version expected by the calling template.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('x64', 'x86', 'ARM64')]
    [string]$Architecture,

    [Parameter(Mandatory = $true)]
    [int]$ContractVersion
)

$ErrorActionPreference = 'Stop'

$scriptContractVersion = 1
if ($ContractVersion -ne $scriptContractVersion) {
    Write-Host "##vso[task.logissue type=error]discover_native_tools.yml expects contract version $ContractVersion but $PSCommandPath implements version $scriptContractVersion. The c_build_tools pipeline resource ref and the c-build-tools checkout are at incompatible commits; update both to the same commit."
    exit 1
}

$arch = $Architecture

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "===== $Title ====="
}

# Reads the machine type out of a PE header so we can report each tool's architecture.
function Get-PEArchitecture {
    param([string]$FilePath)
    if (-not $FilePath -or -not (Test-Path $FilePath)) { return $null }
    try {
        $stream = [System.IO.File]::OpenRead($FilePath)
        $reader = New-Object System.IO.BinaryReader($stream)
        $stream.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
        $peOffset = $reader.ReadInt32()
        $stream.Seek($peOffset + 4, [System.IO.SeekOrigin]::Begin) | Out-Null
        $machine = $reader.ReadUInt16()
        $reader.Close()
        $stream.Close()
        switch ($machine) {
            0x014C { return "x86" }
            0x8664 { return "x64" }
            0xAA64 { return "ARM64" }
            default { return "Unknown (0x$($machine.ToString('X4')))" }
        }
    } catch {
        return "Error reading PE header"
    }
}

Write-Section "DISCOVERING NATIVE BUILD TOOLS FOR $arch"

# ----------------------------------------------------------------
# Azure Pipelines agent
# ----------------------------------------------------------------
# Agent.* variables describe the agent the job is running on. ProcessArchitecture
# reveals whether PowerShell itself is emulated (e.g. an x86 process on an ARM64
# host), which is precisely the condition this template exists to work around.
Write-Section "AZURE PIPELINES AGENT"
function Coalesce { param([string]$Value) if ([string]::IsNullOrEmpty($Value)) { "(unknown)" } else { $Value } }
$agentName    = Coalesce $env:AGENT_NAME
$agentVersion = Coalesce $env:AGENT_VERSION
$agentOS      = Coalesce $env:AGENT_OS
$agentOSArch  = Coalesce $env:AGENT_OSARCHITECTURE
$processArch  = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
$osArch       = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
Write-Host ("  Name:               {0}" -f $agentName)
Write-Host ("  Version:            {0}" -f $agentVersion)
Write-Host ("  OS:                 {0}" -f $agentOS)
Write-Host ("  OS architecture:    {0}" -f $agentOSArch)
Write-Host ("  Task process arch:  {0}" -f $processArch)
Write-Host ("  Host OS arch:       {0}" -f $osArch)
if ("$processArch" -ne "$osArch") {
    Write-Host "##[warning]PowerShell task process architecture ($processArch) differs from host OS architecture ($osArch); the agent is running under emulation."
}

# ----------------------------------------------------------------
# Architecture mapping
# ----------------------------------------------------------------
Write-Section "ARCHITECTURE MAPPING"
switch ($arch) {
    'x64'   {
        $cmakeArch = 'x64'
        $targetPlatform = 'x64'
        $msbuildHost = 'amd64'
    }
    'x86'   {
        $cmakeArch = 'Win32'
        $targetPlatform = 'Win32'
        $msbuildHost = 'amd64'  # Use x64 MSBuild even for x86 targets
    }
    'ARM64' {
        $cmakeArch = 'ARM64'
        $targetPlatform = 'ARM64'
        $msbuildHost = 'arm64'
    }
    default {
        Write-Error "Unknown architecture: $arch"
        exit 1
    }
}
Write-Host ("  CMake -A flag:     {0}" -f $cmakeArch)
Write-Host ("  MSBuild Platform:  {0}" -f $targetPlatform)
Write-Host ("  MSBuild Host:      {0}" -f $msbuildHost)
Write-Host "##vso[task.setvariable variable=cmakeArch]$cmakeArch"
Write-Host "##vso[task.setvariable variable=targetPlatform]$targetPlatform"

# ----------------------------------------------------------------
# Visual Studio
# ----------------------------------------------------------------
Write-Section "VISUAL STUDIO"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found at $vswhere"
    exit 1
}

$vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
if (-not $vsPath) {
    Write-Error "Could not find Visual Studio installation"
    exit 1
}
$vsVersion = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationVersion
$vsMajor = [int]($vsVersion -split '\.')[0]
$cmakeGenerator = switch ($vsMajor) {
    18 { "Visual Studio 18 2026" }
    17 { "Visual Studio 17 2022" }
    16 { "Visual Studio 16 2019" }
    default { "Visual Studio $vsMajor" }
}
Write-Host ("  Path:             {0}" -f $vsPath)
Write-Host ("  Version:          {0} (major {1})" -f $vsVersion, $vsMajor)
Write-Host ("  CMake generator:  {0}" -f $cmakeGenerator)
Write-Host "##vso[task.setvariable variable=vsPath]$vsPath"
Write-Host "##vso[task.setvariable variable=cmakeGenerator]$cmakeGenerator"

# ----------------------------------------------------------------
# Tool discovery
# ----------------------------------------------------------------
Write-Section "TOOL DISCOVERY"

# CMake / CTest bundled with Visual Studio
$cmakeBinDir = Join-Path $vsPath "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin"
$cmakePath = Join-Path $cmakeBinDir "cmake.exe"
$ctestPath = Join-Path $cmakeBinDir "ctest.exe"
if (-not (Test-Path $cmakePath)) {
    Write-Error "CMake not found at $cmakePath"
    exit 1
}
Write-Host "  cmake.exe   found"
if (Test-Path $ctestPath) {
    Write-Host "  ctest.exe   found"
} else {
    Write-Host "##[warning]ctest.exe not found at $ctestPath"
}
Write-Host "##vso[task.setvariable variable=cmakePath]$cmakePath"
Write-Host "##vso[task.setvariable variable=ctestPath]$ctestPath"

# MSBuild for the correct host architecture.
# For ARM64 we need MSBuild\Current\Bin\arm64\MSBuild.exe to get native compilation.
$msbuildPath = Join-Path $vsPath "MSBuild\Current\Bin\$msbuildHost\MSBuild.exe"
if (-not (Test-Path $msbuildPath)) {
    $msbuildPath = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"
    Write-Host "##[warning]Architecture-specific MSBuild not found, falling back to: $msbuildPath"
}
if (-not (Test-Path $msbuildPath)) {
    Write-Error "MSBuild not found"
    exit 1
}
Write-Host "  MSBuild.exe found"
Write-Host "##vso[task.setvariable variable=msbuildPath]$msbuildPath"

# dumpbin lives in the VC tools bin directory alongside cl.exe.
$vcToolsDir = Join-Path $vsPath "VC\Tools\MSVC"
$dumpbinPath = $null
if (Test-Path $vcToolsDir) {
    $msvcVersions = Get-ChildItem $vcToolsDir -Directory | Sort-Object Name -Descending
    foreach ($msvcVersion in $msvcVersions) {
        if ($arch -eq "ARM64") {
            $hostTarget = "Hostarm64\arm64"
        } elseif ($arch -eq "x86") {
            $hostTarget = "Hostx86\x86"
        } else {
            $hostTarget = "Hostx64\x64"
        }

        $candidatePath = Join-Path $msvcVersion.FullName "bin\$hostTarget\dumpbin.exe"
        if (Test-Path $candidatePath) {
            $dumpbinPath = $candidatePath
            break
        }

        # Fallback to x64 if arch-specific not found
        $candidatePath = Join-Path $msvcVersion.FullName "bin\Hostx64\x64\dumpbin.exe"
        if (Test-Path $candidatePath) {
            $dumpbinPath = $candidatePath
            Write-Host "##[warning]Architecture-specific dumpbin not found, falling back to x64"
            break
        }
    }
}
if ($dumpbinPath -and (Test-Path $dumpbinPath)) {
    Write-Host "  dumpbin.exe found"
    Write-Host "##vso[task.setvariable variable=dumpbinPath]$dumpbinPath"
    # Also expose to subprocesses (like ctest) via an environment variable.
    Write-Host "##vso[task.setvariable variable=DUMPBIN_PATH]$dumpbinPath"
    [Environment]::SetEnvironmentVariable("DUMPBIN_PATH", $dumpbinPath, "Process")
} else {
    Write-Host "##[warning]dumpbin not found - reals_check may fail"
}

# Application Verifier (appverif.exe).
# Detection is mandatory: if appverif.exe cannot be located, this discovery
# step aborts the job. Every consumer of c-build-tools is expected to run on
# build pools that have AppVerifier installed; a missing appverif is treated
# as an environmental error, not as a condition the helper should paper over.
# AppVerifier is a configuration tool whose own PE architecture is
# informational only - it can configure verifier settings for binaries of any
# architecture - and is therefore intentionally NOT included in the strict
# PE-architecture verification block below.
#
# WOW64 file-system redirection note:
# When this script runs in an x86-emulated PowerShell on a 64-bit / ARM64
# host (for example, the 1ES ARM64 hosted pool agent currently runs as x86
# under emulation), accesses to "$env:SystemRoot\System32" are silently
# redirected to "$env:SystemRoot\SysWOW64", which contains x86 binaries -
# not the native ARM64 / x64 build of appverif.exe that lives in real
# System32. The "Sysnative" alias bypasses that redirector and exposes the
# native System32 to x86 processes; on a native 64-bit / ARM64 process
# Sysnative simply does not exist (Test-Path returns false) and we fall
# through to System32. Probe Sysnative first so the x86-emulated case
# actually sees the native binary.
$appverifPath = $null
$appverifCandidates = @()
if ($arch -eq "ARM64") {
    $appverifCandidates += "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\arm64\appverif.exe"
    $appverifCandidates += "$env:ProgramFiles\Windows Kits\10\Debuggers\arm64\appverif.exe"
}
$appverifCandidates += "${env:ProgramFiles(x86)}\Windows Kits\10\Debuggers\x64\appverif.exe"
$appverifCandidates += "$env:ProgramFiles\Windows Kits\10\Debuggers\x64\appverif.exe"
$appverifCandidates += "${env:ProgramFiles(x86)}\Application Verifier\appverif.exe"
$appverifCandidates += "$env:ProgramFiles\Application Verifier\appverif.exe"
$appverifCandidates += "$env:SystemRoot\Sysnative\appverif.exe"
$appverifCandidates += "$env:SystemRoot\System32\appverif.exe"

foreach ($candidate in $appverifCandidates) {
    if ($candidate -and (Test-Path $candidate)) {
        $appverifPath = $candidate
        break
    }
}

if (-not $appverifPath) {
    $appverifCmd = Get-Command appverif.exe -ErrorAction SilentlyContinue
    if ($appverifCmd) {
        $appverifPath = $appverifCmd.Source
    }
}

if (-not $appverifPath) {
    $searched = ($appverifCandidates | ForEach-Object { "  $_" }) -join "`n"
    Write-Host "##vso[task.logissue type=error]appverif.exe could not be located. Searched the following locations and PATH:`n$searched"
    Write-Host "##[error]appverif.exe is required on every build pool. Aborting native tools discovery."
    exit 1
}
Write-Host "  appverif.exe found"
Write-Host "##vso[task.setvariable variable=appverifPath]$appverifPath"

# vstest.console.exe under Common7\IDE\CommonExtensions\<Microsoft|Platform>\TestPlatform
$vstestPath = $null
$vstestExeName = "vstest.console.exe"
$commonExtensions = Join-Path $vsPath "Common7\IDE\CommonExtensions"
$searchPaths = @(
    (Join-Path $commonExtensions "Microsoft\TestPlatform"),
    (Join-Path $commonExtensions "Platform\TestPlatform"),
    (Join-Path $commonExtensions "Microsoft\TestWindow"),
    (Join-Path $commonExtensions "Platform\TestWindow")
)
foreach ($searchPath in $searchPaths) {
    $candidatePath = Join-Path $searchPath $vstestExeName
    if (Test-Path $candidatePath) {
        $vstestPath = $candidatePath
        break
    }
}
if (-not $vstestPath) {
    # Fallback: use vswhere -find
    $vstestCandidates = & $vswhere -latest -products * -requires Microsoft.VisualStudio.TestTools.TestPlatform -find "**\$vstestExeName" 2>$null
    if ($vstestCandidates) {
        if ($vstestCandidates -is [array]) {
            $vstestPath = $vstestCandidates[0]
        } else {
            $vstestPath = $vstestCandidates
        }
    }
}
if ($vstestPath -and (Test-Path $vstestPath)) {
    Write-Host "  vstest.console.exe found"
    Write-Host "##vso[task.setvariable variable=vstestPath]$vstestPath"
} else {
    Write-Host "##[warning]$vstestExeName not found"
}

# midl.exe from the newest Windows SDK that has it for this host architecture.
# The SDK ships midl for x86, x64 and arm64 hosts; like MSBuild, x86 targets use the x64 host build.
$midlHost = switch ($arch) {
    'ARM64' { 'arm64' }
    default { 'x64' }
}
$kitsRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -Name KitsRoot10 -ErrorAction SilentlyContinue).KitsRoot10
if (-not $kitsRoot) {
    $kitsRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\"
}
$midlPath = $null
$kitsBin = Join-Path $kitsRoot "bin"
if (Test-Path $kitsBin) {
    $sdkVersions = Get-ChildItem $kitsBin -Directory | Where-Object { $_.Name -match '^\d+(\.\d+){3}$' } | Sort-Object { [version]$_.Name } -Descending
    foreach ($sdkVersion in $sdkVersions) {
        $candidatePath = Join-Path $sdkVersion.FullName "$midlHost\midl.exe"
        if (Test-Path $candidatePath) {
            $midlPath = $candidatePath
            break
        }
    }
}
if ($midlPath) {
    Write-Host "  midl.exe    found"
    Write-Host "##vso[task.setvariable variable=midlPath]$midlPath"
} else {
    Write-Host "##vso[task.logissue type=error]midl.exe ($midlHost host) not found under $kitsBin"
    exit 1
}

# TlbImp.exe from the newest .NET Framework SDK (NETFXSDK). As of 09 Nov 2026 there is no ARM64 TlbImp, and the
# struct layout TlbImp computes follows its own process bitness: the 32-bit TlbImp generates
# 4-byte-pointer layouts, which corrupt COM interop on 64-bit targets. So 64-bit targets (x64 and
# ARM64) use the x64 TlbImp and x86 targets use the x86 one.
$tlbimpToolsKey = switch ($arch) {
    'x86'   { 'WinSDK-NetFx40Tools-x86' }
    default { 'WinSDK-NetFx40Tools-x64' }
}
$tlbimpExpectedArch = switch ($arch) {
    'x86'   { 'x86' }
    default { 'x64' }
}
$tlbimpPath = $null
$netfxSdkRoot = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\NETFXSDK'
if (Test-Path $netfxSdkRoot) {
    $netfxSdks = Get-ChildItem $netfxSdkRoot | Where-Object { $_.PSChildName -match '^\d+(\.\d+)+$' } | Sort-Object { [version]$_.PSChildName } -Descending
    foreach ($netfxSdk in $netfxSdks) {
        $toolsFolder = (Get-ItemProperty (Join-Path $netfxSdk.PSPath $tlbimpToolsKey) -Name InstallationFolder -ErrorAction SilentlyContinue).InstallationFolder
        if ($toolsFolder) {
            $candidatePath = Join-Path $toolsFolder "TlbImp.exe"
            if (Test-Path $candidatePath) {
                $tlbimpPath = $candidatePath
                break
            }
        }
    }
}
if ($tlbimpPath) {
    Write-Host "  TlbImp.exe  found"
    Write-Host "##vso[task.setvariable variable=tlbimpPath]$tlbimpPath"
} else {
    Write-Host "##vso[task.logissue type=error]TlbImp.exe ($tlbimpToolsKey) not found under $netfxSdkRoot"
    exit 1
}

# ----------------------------------------------------------------
# Summary + architecture verification
# ----------------------------------------------------------------
# One table reports every discovered tool, its PE architecture, and whether it
# matches the expected architecture.
Write-Section "DISCOVERED TOOLS"
$expectedArch = switch ($arch) {
    'x64'   { 'x64' }
    'x86'   { 'x86' }
    'ARM64' { 'ARM64' }
}
$tools = @(
    [pscustomobject]@{ Name = 'cmake.exe';          Path = $cmakePath;    Expected = $expectedArch }
    [pscustomobject]@{ Name = 'ctest.exe';          Path = $ctestPath;    Expected = $expectedArch }
    [pscustomobject]@{ Name = 'MSBuild.exe';        Path = $msbuildPath;  Expected = $expectedArch }
    [pscustomobject]@{ Name = 'dumpbin.exe';        Path = $dumpbinPath;  Expected = $expectedArch }
    [pscustomobject]@{ Name = 'vstest.console.exe'; Path = $vstestPath;   Expected = $expectedArch }
    [pscustomobject]@{ Name = 'midl.exe';           Path = $midlPath;     Expected = $expectedArch }
    [pscustomobject]@{ Name = 'TlbImp.exe';         Path = $tlbimpPath;   Expected = $tlbimpExpectedArch }
    [pscustomobject]@{ Name = 'appverif.exe';       Path = $appverifPath; Expected = $expectedArch }
)
Write-Host ("  {0,-20} {1,-10} {2,-10} {3}" -f "Tool", "Arch", "Status", "Path")
Write-Host ("  {0,-20} {1,-10} {2,-10} {3}" -f "----", "----", "------", "----")
$archMismatches = @()
$tlbimpMismatch = $null
foreach ($t in $tools) {
    if (-not $t.Path -or -not (Test-Path $t.Path)) {
        Write-Host ("  {0,-20} {1,-10} {2,-10} {3}" -f $t.Name, "-", "missing", "(not found)")
        continue
    }
    $toolArch = Get-PEArchitecture -FilePath $t.Path
    $ok = ($toolArch -eq $t.Expected) -or ($t.Expected -eq 'x86' -and $toolArch -eq 'x64' -and $t.Name -ne 'TlbImp.exe')
    $status = if ($ok) { "OK" } else { "MISMATCH" }
    if (-not $ok -and $t.Name -eq 'TlbImp.exe') {
        $tlbimpMismatch = "$($t.Name) is $toolArch, expected $($t.Expected)"
    } elseif (-not $ok -and $expectedArch -eq 'ARM64') {
        $archMismatches += "$($t.Name) is $toolArch, expected $($t.Expected)"
    }
    Write-Host ("  {0,-20} {1,-10} {2,-10} {3}" -f $t.Name, $toolArch, $status, $t.Path)
}

if ($tlbimpMismatch) {
    Write-Host "##vso[task.logissue type=error]$tlbimpMismatch. Its interop struct layouts would not match a $arch target."
    exit 1
}

if ($archMismatches.Count -gt 0) {
    Write-Host "##[warning]Architecture mismatches detected for ARM64 build:"
    foreach ($mismatch in $archMismatches) {
        Write-Host "##[warning]  - $mismatch"
    }
    Write-Host "##[warning]Some tools may run under emulation, which can affect performance."
}

# ----------------------------------------------------------------
# Usage
# ----------------------------------------------------------------
Write-Section "USAGE"
Write-Host '  CMake:    "$(cmakePath)" -S . -B build -G "$(cmakeGenerator)" -A $(cmakeArch)'
Write-Host '  MSBuild:  "$(msbuildPath)" solution.sln /p:Platform=$(targetPlatform)'
Write-Host '  CTest:    "$(ctestPath)" -C Debug --output-on-failure'
Write-Host '  dumpbin:  "$(dumpbinPath)" /ALL mylib.lib'
Write-Host '  vstest:   "$(vstestPath)" test.dll /Platform:$(targetPlatform)'

Write-Host '  appverif: "$(appverifPath)" -enable Heaps -for foo.exe'
Write-Host "  (environment variable DUMPBIN_PATH is also set for subprocesses such as ctest)"
