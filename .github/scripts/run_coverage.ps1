<#
.SYNOPSIS
    Runs a unit test executable with MSVC code coverage and reports per-file coverage.

.DESCRIPTION
    Uses Microsoft.CodeCoverage.Console (VS Enterprise) to collect dynamic code coverage
    from a native test executable, then parses the Cobertura XML output and displays
    per-file line coverage statistics.

.PARAMETER TestExe
    Path to the unit test executable.

.PARAMETER SourceFilter
    One or more wildcard patterns to filter which source files appear in the report.
    Only files whose path matches at least one pattern (using -like) are shown.
    Example: "*src\peer_library.c", "*src\*.c"

.PARAMETER OutputDir
    Directory for coverage output files. Defaults to .\coverage under script directory.

.PARAMETER ShowFunctions
    If set, also shows per-function coverage for each matched file.

.PARAMETER ShowUncoveredLines
    If set, lists each uncovered (hits=0) line number for each matched file.

.PARAMETER SettingsFile
    Optional path to an XML coverage settings file for fine-grained control
    over which modules/sources are instrumented.

.EXAMPLE
    .\run_coverage.ps1 -TestExe "build\Debug\my_ut.exe" -SourceFilter "*src\my_module.c"

.EXAMPLE
    .\run_coverage.ps1 -TestExe "build\Debug\my_ut.exe" -SourceFilter "*src\*.c" -ShowFunctions -ShowUncoveredLines
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TestExe,

    [Parameter()]
    [string[]]$SourceFilter,

    [Parameter()]
    [string]$OutputDir,

    [Parameter()]
    [switch]$ShowFunctions,

    [Parameter()]
    [switch]$ShowUncoveredLines,

    [Parameter()]
    [string]$SettingsFile
)

$ErrorActionPreference = 'Stop'

# --- Locate Microsoft.CodeCoverage.Console.exe ---
function Find-CoverageConsole {
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        Write-Error "vswhere.exe not found. Is Visual Studio installed?"
        return $null
    }

    $vsPath = & $vswhere -latest -property installationPath
    if (-not $vsPath) {
        Write-Error "No Visual Studio installation found."
        return $null
    }

    $consolePath = Join-Path $vsPath 'Common7\IDE\Extensions\Microsoft\CodeCoverage.Console\Microsoft.CodeCoverage.Console.exe'
    if (Test-Path $consolePath) {
        return $consolePath
    }

    Write-Error "Microsoft.CodeCoverage.Console.exe not found at: $consolePath`nVisual Studio Enterprise is required for native code coverage."
    return $null
}

$coverageTool = Find-CoverageConsole
if (-not $coverageTool) { exit 1 }

# --- Validate test executable ---
if (-not (Test-Path $TestExe)) {
    Write-Error "Test executable not found: $TestExe"
    exit 1
}

$TestExe = (Resolve-Path $TestExe).Path

# --- Set up output directory ---
if (-not $OutputDir) {
    $OutputDir = Join-Path $PSScriptRoot 'coverage'
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$testName = [System.IO.Path]::GetFileNameWithoutExtension($TestExe)
$coberturaFile = Join-Path $OutputDir "${testName}_${timestamp}.cobertura.xml"

# --- Collect coverage ---
Write-Host "`n=== Collecting code coverage ===" -ForegroundColor Cyan
Write-Host "Tool:   $coverageTool"
Write-Host "Test:   $TestExe"
Write-Host "Output: $coberturaFile"
Write-Host ""

$collectArgs = @(
    'collect'
    '--output', $coberturaFile
    '--output-format', 'cobertura'
    '--nologo'
)

if ($SettingsFile) {
    if (-not (Test-Path $SettingsFile)) {
        Write-Error "Settings file not found: $SettingsFile"
        exit 1
    }
    $collectArgs += '--settings', (Resolve-Path $SettingsFile).Path
}

$collectArgs += '--', $TestExe

& $coverageTool @collectArgs
$exitCode = $LASTEXITCODE

if (-not (Test-Path $coberturaFile)) {
    Write-Error "Coverage file was not created. The test may have failed (exit code: $exitCode)."
    exit 1
}

Write-Host "`nCoverage file written: $coberturaFile" -ForegroundColor Green

# --- Parse Cobertura XML ---
Write-Host "`n=== Parsing coverage report ===" -ForegroundColor Cyan

[xml]$xml = Get-Content $coberturaFile -Encoding UTF8

$allClasses = $xml.coverage.packages.package.classes.class

# Apply source filter (normalize path separators so forward-slash patterns match backslash paths in XML)
if ($SourceFilter -and $SourceFilter.Count -gt 0) {
    $filtered = @()
    foreach ($cls in $allClasses) {
        $normalizedFilename = $cls.filename -replace '\\', '/'
        foreach ($pat in $SourceFilter) {
            $normalizedPat = $pat -replace '\\', '/'
            if ($normalizedFilename -like $normalizedPat) {
                $filtered += $cls
                break
            }
        }
    }
    $allClasses = $filtered
}

if (-not $allClasses -or $allClasses.Count -eq 0) {
    Write-Warning "No source files matched the filter. Showing top-level summary only."
    Write-Host "`nOverall: line-rate=$($xml.coverage.'line-rate'), lines-covered=$($xml.coverage.'lines-covered'), lines-valid=$($xml.coverage.'lines-valid')"
    exit 0
}

# --- Display per-file summary ---
Write-Host ""
$separator = '-' * 100

$totalCovered = 0
$totalValid = 0

$fileSummaries = @()
foreach ($cls in $allClasses) {
    $lines = @()
    if ($cls.lines -and $cls.lines.line) {
        $lines = @($cls.lines.line)
    }

    $valid = $lines.Count
    $covered = ($lines | Where-Object { [int]$_.hits -gt 0 }).Count
    $uncovered = $valid - $covered
    $pct = if ($valid -gt 0) { [math]::Round(($covered / $valid) * 100, 1) } else { 0 }

    $totalCovered += $covered
    $totalValid += $valid

    $fileSummaries += [PSCustomObject]@{
        File      = $cls.filename
        Lines     = $valid
        Covered   = $covered
        Uncovered = $uncovered
        Pct       = $pct
    }
}

# Sort by coverage % ascending (worst first)
$fileSummaries = $fileSummaries | Sort-Object Pct

Write-Host $separator
Write-Host ("{0,-70} {1,6} {2,8} {3,10} {4,7}" -f 'File', 'Lines', 'Covered', 'Uncovered', 'Pct%')
Write-Host $separator

foreach ($f in $fileSummaries) {
    # Truncate long paths: show last 60 chars
    $displayPath = $f.File
    if ($displayPath.Length -gt 68) {
        $displayPath = '...' + $displayPath.Substring($displayPath.Length - 65)
    }

    $color = if ($f.Pct -ge 80) { 'Green' } elseif ($f.Pct -ge 50) { 'Yellow' } else { 'Red' }
    $line = "{0,-70} {1,6} {2,8} {3,10} {4,6:N1}%" -f $displayPath, $f.Lines, $f.Covered, $f.Uncovered, $f.Pct
    Write-Host $line -ForegroundColor $color
}

Write-Host $separator
$totalPct = if ($totalValid -gt 0) { [math]::Round(($totalCovered / $totalValid) * 100, 1) } else { 0 }
$summaryLine = "{0,-70} {1,6} {2,8} {3,10} {4,6:N1}%" -f 'TOTAL', $totalValid, $totalCovered, ($totalValid - $totalCovered), $totalPct
$totalColor = if ($totalPct -ge 80) { 'Green' } elseif ($totalPct -ge 50) { 'Yellow' } else { 'Red' }
Write-Host $summaryLine -ForegroundColor $totalColor
Write-Host ""

# --- Per-function detail ---
if ($ShowFunctions) {
    Write-Host "=== Per-function coverage ===" -ForegroundColor Cyan
    Write-Host ""

    foreach ($cls in $allClasses) {
        Write-Host "  $($cls.filename)" -ForegroundColor White

        $methods = @()
        if ($cls.methods -and $cls.methods.method) {
            $methods = @($cls.methods.method)
        }

        if ($methods.Count -eq 0) {
            Write-Host "    (no methods)" -ForegroundColor DarkGray
            continue
        }

        foreach ($m in ($methods | Sort-Object { [double]$_.'line-rate' })) {
            $mLines = @()
            if ($m.lines -and $m.lines.line) {
                $mLines = @($m.lines.line)
            }
            $mValid = $mLines.Count
            $mCovered = ($mLines | Where-Object { [int]$_.hits -gt 0 }).Count
            $mPct = if ($mValid -gt 0) { [math]::Round(($mCovered / $mValid) * 100, 1) } else { 0 }

            $funcName = $m.name
            if ($funcName.Length -gt 60) {
                $funcName = $funcName.Substring(0, 57) + '...'
            }

            $color = if ($mPct -ge 80) { 'Green' } elseif ($mPct -ge 50) { 'Yellow' } else { 'Red' }
            Write-Host ("    {0,-62} {1,4}/{2,-4} {3,6:N1}%" -f $funcName, $mCovered, $mValid, $mPct) -ForegroundColor $color
        }
        Write-Host ""
    }
}

# --- Uncovered lines ---
if ($ShowUncoveredLines) {
    Write-Host "=== Uncovered lines ===" -ForegroundColor Cyan
    Write-Host ""

    foreach ($cls in $allClasses) {
        $lines = @()
        if ($cls.lines -and $cls.lines.line) {
            $lines = @($cls.lines.line)
        }

        $uncoveredLines = $lines | Where-Object { [int]$_.hits -eq 0 } | ForEach-Object { [int]$_.number } | Sort-Object

        if ($uncoveredLines.Count -eq 0) {
            continue
        }

        Write-Host "  $($cls.filename)" -ForegroundColor White

        # Group consecutive lines into ranges
        $ranges = @()
        $rangeStart = $uncoveredLines[0]
        $rangePrev = $rangeStart

        for ($i = 1; $i -lt $uncoveredLines.Count; $i++) {
            if ($uncoveredLines[$i] -eq $rangePrev + 1) {
                $rangePrev = $uncoveredLines[$i]
            }
            else {
                if ($rangeStart -eq $rangePrev) {
                    $ranges += "$rangeStart"
                }
                else {
                    $ranges += "${rangeStart}-${rangePrev}"
                }
                $rangeStart = $uncoveredLines[$i]
                $rangePrev = $rangeStart
            }
        }
        # Final range
        if ($rangeStart -eq $rangePrev) {
            $ranges += "$rangeStart"
        }
        else {
            $ranges += "${rangeStart}-${rangePrev}"
        }

        Write-Host "    Lines: $($ranges -join ', ')" -ForegroundColor Red
        Write-Host ""
    }
}

Write-Host "Coverage report: $coberturaFile" -ForegroundColor Cyan
