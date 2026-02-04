# parse_pr_threads.ps1
# Fetches and parses Azure DevOps PR thread comments directly via REST API
# Filters out bot comments and PR-level comments
# Outputs to cmake/ folder of current project for easy access
#
# Usage:
#   pwsh -File .github/scripts/parse_pr_threads.ps1 -prUrl "https://dev.azure.com/msazure/One/_git/zrpc/pullrequest/14336583" -ShowResolved NO
#   pwsh -File .github/scripts/parse_pr_threads.ps1 -org "msazure" -project "One" -repo "zrpc" -prId 14336583 -ShowResolved NO
#   pwsh -File .github/scripts/parse_pr_threads.ps1 -jsonFile "<path-to-json>" -ShowResolved YES
#
# Parameters:
#   -ShowResolved YES    Include closed/resolved threads (for extracting learnings from all feedback)
#   -ShowResolved NO     Only show active threads (for addressing PR review comments)
#
# Requires: Azure CLI (az) authenticated

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("YES", "NO")]
    [string]$ShowResolved,
    [string]$prUrl = "",
    [string]$org = "",
    [string]$project = "",
    [string]$repo = "",
    [int]$prId = 0,
    [string]$jsonFile = "",
    [string]$outputDir = "cmake",
    [string]$outputFileName = "pr_threads_parsed.txt"
)

# Parse URL if provided
if ($prUrl) {
    # Pattern 1: https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}
    # Pattern 2: https://{org}.visualstudio.com/{project}/_git/{repo}/pullrequest/{id}
    if ($prUrl -match "dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+)/pullrequest/(\d+)") {
        $org = $Matches[1]
        $project = $Matches[2]
        $repo = $Matches[3]
        $prId = [int]$Matches[4]
    } elseif ($prUrl -match "([^/.]+)\.visualstudio\.com/([^/]+)/_git/([^/]+)/pullrequest/(\d+)") {
        $org = $Matches[1]
        $project = $Matches[2]
        $repo = $Matches[3]
        $prId = [int]$Matches[4]
    } else {
        Write-Error "Invalid Azure DevOps PR URL format. Expected: https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id} or https://{org}.visualstudio.com/{project}/_git/{repo}/pullrequest/{id}"
        exit 1
    }
}

# Determine data source: fetch from API or read from file
$threads = $null

if ($jsonFile) {
    # Legacy mode: read from pre-fetched JSON file
    if (-not (Test-Path $jsonFile)) {
        Write-Error "File not found: $jsonFile"
        exit 1
    }
    Write-Host "Reading PR threads from file: $jsonFile" -ForegroundColor Cyan
    $json = Get-Content $jsonFile -Raw | ConvertFrom-Json
    $threads = $json[0].text | ConvertFrom-Json
} else {
    # Fetch mode: get threads directly from Azure DevOps REST API
    if (-not $org -or -not $project -or -not $repo -or $prId -eq 0) {
        Write-Host "Usage:" -ForegroundColor Yellow
        Write-Host "  pwsh -File parse_pr_threads.ps1 -prUrl 'https://dev.azure.com/msazure/One/_git/zrpc/pullrequest/14336583' -ShowResolved NO"
        Write-Host "  pwsh -File parse_pr_threads.ps1 -org 'msazure' -project 'One' -repo 'zrpc' -prId 14336583 -ShowResolved NO"
        Write-Host "  pwsh -File parse_pr_threads.ps1 -jsonFile '<path>' -ShowResolved YES  (legacy: read from file)"
        exit 1
    }

    Write-Host "Fetching PR threads for: $org/$project/$repo PR#$prId" -ForegroundColor Cyan
    Write-Host "=" * 60

    # Get access token for Azure DevOps
    try {
        $token = az account get-access-token --resource '499b84ac-1321-427f-aa17-267ca6975798' --query 'accessToken' -o tsv 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to get access token. Make sure 'az login' has been run. Error: $token"
            exit 1
        }
        $token = $token.Trim()
    } catch {
        Write-Error "Failed to get Azure DevOps access token: $_"
        exit 1
    }

    # Fetch threads from REST API
    $apiUrl = "https://dev.azure.com/$org/$project/_apis/git/repositories/$repo/pullRequests/$prId/threads?api-version=7.1"
    try {
        $headers = @{
            Authorization = "Bearer $token"
            "Content-Type" = "application/json"
        }
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
        $threads = $response.value
    } catch {
        Write-Error "Failed to fetch PR threads from API: $_"
        exit 1
    }
}

# Ensure output directory exists
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$outputFile = Join-Path $outputDir $outputFileName

# Filter and display threads
# Excludes: MerlinBot, Azure Pipelines bot, threads without file context
# When ShowResolved=NO, only keeps threads with status "active" (excludes closed, fixed, byDesign, wontFix, pending, etc.)
$filteredThreads = $threads | Where-Object {
    $_.comments[0].author.displayName -ne 'MerlinBot' -and
    $_.comments[0].author.displayName -notmatch 'Azure Pipelines' -and
    $_.threadContext -ne $null -and
    ($ShowResolved -eq "YES" -or $_.status -eq 'active')
}

# Count statistics
$totalThreads = ($threads | Measure-Object).Count
$resolvedThreads = ($threads | Where-Object { $_.status -ne 'active' -and $_.status -ne $null } | Measure-Object).Count
$botThreads = ($threads | Where-Object { $_.comments[0].author.displayName -eq 'MerlinBot' -or $_.comments[0].author.displayName -match 'Azure Pipelines' } | Measure-Object).Count
$noContextThreads = ($threads | Where-Object { $_.threadContext -eq $null } | Measure-Object).Count

$count = ($filteredThreads | Measure-Object).Count

# Build output content
$output = @()
if (-not $jsonFile) {
    $output += "PR: $org/$project/$repo PR#$prId"
    $output += ""
}
$output += "Thread Statistics:"
$output += "  Total threads: $totalThreads"
$output += "  Resolved (non-active): $resolvedThreads" + $(if ($ShowResolved -eq "YES") { " (included)" } else { " (filtered)" })
$output += "  Bot threads: $botThreads (filtered)"
$output += "  PR-level (no file context): $noContextThreads (filtered)"
$output += "  Active threads: $count"
$output += ""
$output += "=" * 60
$output += "THREADS:"
$output += "=" * 60

function Format-ThreadLocation($threadContext) {
    $parts = @()
    $ctx = $threadContext

    # Right side (new file) location
    if ($ctx.rightFileStart) {
        $startLine = $ctx.rightFileStart.line
        $startCol = $ctx.rightFileStart.offset
        $endLine = if ($ctx.rightFileEnd) { $ctx.rightFileEnd.line } else { $null }
        $endCol = if ($ctx.rightFileEnd) { $ctx.rightFileEnd.offset } else { $null }

        if ($endLine -and $endLine -ne $startLine) {
            $parts += "Lines: $($startLine):$($startCol) - $($endLine):$($endCol) (right/new)"
        } elseif ($endCol -and $endCol -ne $startCol) {
            $parts += "Line: $startLine, Columns: $startCol-$endCol (right/new)"
        } else {
            $loc = "$startLine"
            if ($startCol) { $loc += ":$startCol" }
            $parts += "Line: $loc (right/new)"
        }
    }

    # Left side (old file) location
    if ($ctx.leftFileStart) {
        $startLine = $ctx.leftFileStart.line
        $startCol = $ctx.leftFileStart.offset
        $endLine = if ($ctx.leftFileEnd) { $ctx.leftFileEnd.line } else { $null }
        $endCol = if ($ctx.leftFileEnd) { $ctx.leftFileEnd.offset } else { $null }

        if ($endLine -and $endLine -ne $startLine) {
            $parts += "Lines: $($startLine):$($startCol) - $($endLine):$($endCol) (left/old)"
        } elseif ($endCol -and $endCol -ne $startCol) {
            $parts += "Line: $startLine, Columns: $startCol-$endCol (left/old)"
        } else {
            $loc = "$startLine"
            if ($startCol) { $loc += ":$startCol" }
            $parts += "Line: $loc (left/old)"
        }
    }

    return $parts
}

$filteredThreads | ForEach-Object {
    $output += ""
    $output += "=== Thread $($_.id) (Status: $($_.status)) ==="
    $output += "File: $($_.threadContext.filePath)"
    $locationParts = Format-ThreadLocation $_.threadContext
    foreach ($loc in $locationParts) {
        $output += $loc
    }
    $output += "Author: $($_.comments[0].author.displayName)"
    $output += "Comment: $($_.comments[0].content)"

    # Show replies if any (beyond the first comment)
    if ($_.comments.Count -gt 1) {
        $output += "--- Replies ---"
        for ($i = 1; $i -lt $_.comments.Count; $i++) {
            $output += "  [$($_.comments[$i].author.displayName)]: $($_.comments[$i].content)"
        }
    }
}

# Write to file
$output | Out-File -FilePath $outputFile -Encoding UTF8

# Also display to console
Write-Host ""
if (-not $jsonFile) {
    Write-Host "PR: $org/$project/$repo PR#$prId" -ForegroundColor Gray
    Write-Host ""
}
Write-Host "Thread Statistics:" -ForegroundColor Yellow
Write-Host "  Total threads: $totalThreads"
Write-Host "  Resolved (non-active): $resolvedThreads$(if ($ShowResolved -eq 'YES') { ' (included)' } else { ' (filtered)' })" -ForegroundColor $(if ($ShowResolved -eq 'YES') { 'Gray' } else { 'DarkGray' })
Write-Host "  Bot threads: $botThreads (filtered)" -ForegroundColor DarkGray
Write-Host "  PR-level (no file context): $noContextThreads (filtered)" -ForegroundColor DarkGray
Write-Host "  Active threads: $count" -ForegroundColor Green
Write-Host ""
Write-Host ("=" * 60)
Write-Host "THREADS:" -ForegroundColor Cyan
Write-Host ("=" * 60)
$filteredThreads | ForEach-Object {
    Write-Output ""
    Write-Output "=== Thread $($_.id) (Status: $($_.status)) ==="
    Write-Output "File: $($_.threadContext.filePath)"
    $locationParts = Format-ThreadLocation $_.threadContext
    foreach ($loc in $locationParts) {
        Write-Output $loc
    }
    Write-Output "Author: $($_.comments[0].author.displayName)"
    Write-Output "Comment: $($_.comments[0].content)"

    # Show replies if any (beyond the first comment)
    if ($_.comments.Count -gt 1) {
        Write-Output "--- Replies ---"
        for ($i = 1; $i -lt $_.comments.Count; $i++) {
            Write-Output "  [$($_.comments[$i].author.displayName)]: $($_.comments[$i].content)"
        }
    }
}

Write-Host ""
Write-Host "Output written to: $outputFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "Tips:" -ForegroundColor Yellow
Write-Host "  -ShowResolved YES    Include closed threads (for learning extraction)"
Write-Host "  -ShowResolved NO     Only active threads (for addressing PR comments)"
