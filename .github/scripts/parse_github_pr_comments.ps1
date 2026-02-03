# parse_github_pr_comments.ps1
# Fetches and parses GitHub PR comments from multiple sources:
#   1. Review threads (line-level comments via GraphQL)
#   2. PR-level reviews (approval/request-changes comments)
#   3. Issue comments (general PR discussion comments)
#
# Filters out:
#   - Resolved threads (isResolved == true)
#   - Comments with #Closed or #Resolved marker
#   - Bot comments (azure-pipelines[bot], etc.)
#   - Pipeline trigger comments (/AzurePipelines run)
#
# Creates an output folder inside the specified directory (default: cmake/extract-learnings/)
#
# Usage:
#   pwsh -File .github/scripts/parse_github_pr_comments.ps1 -prUrl "https://github.com/owner/repo/pull/123" -ShowResolved YES
#   pwsh -File .github/scripts/parse_github_pr_comments.ps1 -prUrl "https://github.com/owner/repo/pull/123" -ShowResolved NO
#   pwsh -File .github/scripts/parse_github_pr_comments.ps1 -owner "Azure" -repo "c-pal" -prNumber 520 -ShowResolved NO
#
# Parameters:
#   -ShowResolved YES    Include resolved comments (for extracting learnings from all feedback)
#   -ShowResolved NO     Only show active/unresolved comments (for addressing PR review comments)
#
# Requires: GitHub CLI (gh) authenticated

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("YES", "NO")]
    [string]$ShowResolved,
    [string]$prUrl = "",
    [string]$owner = "",
    [string]$repo = "",
    [int]$prNumber = 0,
    [string]$outputDir = "cmake",
    [string]$outputFileName = "github_pr_comments_parsed.txt"
)

# Parse URL if provided
if ($prUrl) {
    # Pattern: https://github.com/owner/repo/pull/123
    if ($prUrl -match "github\.com/([^/]+)/([^/]+)/pull/(\d+)") {
        $owner = $Matches[1]
        $repo = $Matches[2]
        $prNumber = [int]$Matches[3]
    } else {
        Write-Error "Invalid GitHub PR URL format. Expected: https://github.com/owner/repo/pull/123"
        exit 1
    }
}

# Validate required parameters
if (-not $owner -or -not $repo -or $prNumber -eq 0) {
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  pwsh -File parse_github_pr_comments.ps1 -prUrl 'https://github.com/owner/repo/pull/123'"
    Write-Host "  pwsh -File parse_github_pr_comments.ps1 -owner 'Azure' -repo 'c-pal' -prNumber 520"
    exit 1
}

# Create output folder inside $outputDir
$outputFolder = Join-Path $outputDir "extract-learnings"
if (-not (Test-Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
}

$outputFile = Join-Path $outputFolder $outputFileName

Write-Host "Fetching PR comments for: $owner/$repo#$prNumber" -ForegroundColor Cyan
Write-Host "=" * 60

# Get PR author first
try {
    $prInfoJson = gh api "repos/$owner/$repo/pulls/$prNumber" --jq '.user.login' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch PR info: $prInfoJson"
        exit 1
    }
    $prAuthor = $prInfoJson.Trim()
    Write-Host "PR Author: $prAuthor" -ForegroundColor Gray
} catch {
    Write-Error "Failed to get PR author: $_"
    exit 1
}

# GraphQL query to fetch review threads with resolution status
$graphqlQuery = @"
{
  repository(owner: "$owner", name: "$repo") {
    pullRequest(number: $prNumber) {
      reviewThreads(first: 100) {
        totalCount
        nodes {
          isResolved
          path
          line
          startLine
          diffSide
          comments(first: 20) {
            nodes {
              body
              author { login }
              url
            }
          }
        }
      }
    }
  }
}
"@

# Fetch review threads using GraphQL
try {
    $graphqlResult = gh api graphql -f query="$graphqlQuery" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to fetch review threads: $graphqlResult"
        exit 1
    }
    $data = $graphqlResult | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse review threads: $_"
    exit 1
}

$threads = $data.data.repository.pullRequest.reviewThreads.nodes
$totalCount = $data.data.repository.pullRequest.reviewThreads.totalCount

# Filter threads
$activeThreads = @()
$resolvedByApi = 0
$resolvedByMarker = 0
$botComments = 0

foreach ($thread in $threads) {
    # Skip if API says resolved
    if ($thread.isResolved -and $ShowResolved -eq "NO") {
        $resolvedByApi++
        continue
    }

    # Check if any comment in thread has #Resolved or #Closed marker
    $hasResolvedMarker = $false
    foreach ($comment in $thread.comments.nodes) {
        if ($comment.body -match "#(Resolved|Closed)") {
            $hasResolvedMarker = $true
            break
        }
    }

    if ($hasResolvedMarker -and $ShowResolved -eq "NO") {
        $resolvedByMarker++
        continue
    }

    # Get the first comment (the original review comment)
    $firstComment = $thread.comments.nodes[0]

    # Skip bot comments
    $authorLogin = $firstComment.author.login
    if ($authorLogin -match "\[bot\]$" -or $authorLogin -match "^azure-pipelines") {
        $botComments++
        continue
    }

    # This is an active thread
    $activeThreads += [PSCustomObject]@{
        Path = $thread.path
        Line = $thread.line
        StartLine = $thread.startLine
        DiffSide = $thread.diffSide
        Author = $authorLogin
        Body = $firstComment.body
        Url = $firstComment.url
    }
}

$activeCount = $activeThreads.Count

# Group by path for better organization
$groupedThreads = $activeThreads | Group-Object -Property Path

# Build output content
$output = @()
$output += "PR: $owner/$repo#$prNumber"
$output += "PR Author: $prAuthor"
$output += ""
$output += "Review Thread Statistics:"
$output += "  Total threads: $totalCount"
$output += "  Resolved (API): $resolvedByApi"
$output += "  Resolved (marker): $resolvedByMarker"
$output += "  Bot comments: $botComments"
$output += "  Active review comments: $activeCount"
$output += ""
$output += "=" * 60
$output += "ACTIVE REVIEW COMMENTS:"
$output += "=" * 60

if ($activeCount -eq 0) {
    $output += ""
    $output += "(No active review comments found)"
} else {
    foreach ($group in $groupedThreads) {
        $output += ""
        $output += "=== File: $($group.Name) ==="

        foreach ($thread in $group.Group) {
            $output += ""

            # Format line location with optional range and side
            if ($thread.StartLine -and $thread.StartLine -ne $thread.Line) {
                $lineStr = "Lines $($thread.StartLine)-$($thread.Line)"
            } elseif ($thread.Line) {
                $lineStr = "Line $($thread.Line)"
            } else {
                $lineStr = "Line N/A"
            }
            if ($thread.DiffSide) {
                $sideLabel = if ($thread.DiffSide -eq "RIGHT") { "(right/new)" } else { "(left/old)" }
                $lineStr += " $sideLabel"
            }

            $output += "--- $lineStr ---"
            $output += "Author: $($thread.Author)"
            $output += "URL: $($thread.Url)"

            # Truncate long comments for display
            $body = $thread.Body
            if ($body.Length -gt 500) {
                $body = $body.Substring(0, 500) + "..."
            }
            $output += "Comment: $body"
        }
    }
}

# Fetch PR-level review comments (not line-specific)
$output += ""
$output += "=" * 60
$output += "PR-LEVEL REVIEW COMMENTS:"
$output += "=" * 60

try {
    $reviewsJson = gh api "repos/$owner/$repo/pulls/$prNumber/reviews" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $reviews = $reviewsJson | ConvertFrom-Json

        # Filter out PR author and bot reviews, and empty bodies
        $reviewsWithBody = $reviews | Where-Object {
            $_.body -and
            $_.body.Trim() -ne "" -and
            $_.user.login -ne $prAuthor -and
            -not ($_.user.login -match "\[bot\]$")
        }

        if (($reviewsWithBody | Measure-Object).Count -eq 0) {
            $output += ""
            $output += "(No PR-level review comments)"
        } else {
            foreach ($review in $reviewsWithBody) {
                $output += ""
                $output += "--- Review by $($review.user.login) ($($review.state)) ---"
                $body = $review.body
                if ($body.Length -gt 500) {
                    $body = $body.Substring(0, 500) + "..."
                }
                $output += $body
            }
        }
    }
} catch {
    $output += ""
    $output += "(Could not fetch PR reviews)"
}

# Fetch issue comments (general PR discussion, not line-specific)
$output += ""
$output += "=" * 60
$output += "ISSUE COMMENTS (PR Discussion):"
$output += "=" * 60

$activeIssueComments = @()
$issueCommentStats = @{
    Total = 0
    Bot = 0
    Pipeline = 0
    Resolved = 0
    Active = 0
}

try {
    $issueCommentsJson = gh api "repos/$owner/$repo/issues/$prNumber/comments" --paginate 2>&1
    if ($LASTEXITCODE -eq 0) {
        $issueComments = $issueCommentsJson | ConvertFrom-Json
        $issueCommentStats.Total = ($issueComments | Measure-Object).Count

        foreach ($comment in $issueComments) {
            $authorLogin = $comment.user.login
            $body = $comment.body

            # Skip bot comments
            if ($authorLogin -match "\[bot\]$" -or $authorLogin -match "^azure-pipelines") {
                $issueCommentStats.Bot++
                continue
            }

            # Skip pipeline trigger comments
            if ($body -match "^/AzurePipelines") {
                $issueCommentStats.Pipeline++
                continue
            }

            # Skip resolved/closed comments
            if ($body -match "#(Resolved|Closed)" -and $ShowResolved -eq "NO") {
                $issueCommentStats.Resolved++
                continue
            }

            # This is an active issue comment
            $issueCommentStats.Active++
            $activeIssueComments += [PSCustomObject]@{
                Author = $authorLogin
                Body = $body
                Url = $comment.html_url
                CreatedAt = $comment.created_at
            }
        }

        if ($activeIssueComments.Count -eq 0) {
            $output += ""
            $output += "(No active issue comments)"
        } else {
            foreach ($comment in $activeIssueComments) {
                $output += ""
                $output += "--- Comment by $($comment.Author) ---"
                $output += "URL: $($comment.Url)"
                $output += "Date: $($comment.CreatedAt)"

                $body = $comment.Body
                if ($body.Length -gt 500) {
                    $body = $body.Substring(0, 500) + "..."
                }
                $output += "Comment: $body"
            }
        }
    }
} catch {
    $output += ""
    $output += "(Could not fetch issue comments)"
}

# Write to file
$output | Out-File -FilePath $outputFile -Encoding UTF8

# Also display to console
Write-Host ""
Write-Host "PR Author: $prAuthor" -ForegroundColor Gray
Write-Host ""
Write-Host "Review Thread Statistics:" -ForegroundColor Yellow
Write-Host "  Total threads: $totalCount"
Write-Host "  Resolved (API): $resolvedByApi" -ForegroundColor DarkGray
Write-Host "  Resolved (marker): $resolvedByMarker" -ForegroundColor DarkGray
Write-Host "  Bot comments: $botComments" -ForegroundColor DarkGray
Write-Host "  Active review comments: $activeCount" -ForegroundColor Green
Write-Host ""
Write-Host "Issue Comment Statistics:" -ForegroundColor Yellow
Write-Host "  Total comments: $($issueCommentStats.Total)"
Write-Host "  Bot comments: $($issueCommentStats.Bot)" -ForegroundColor DarkGray
Write-Host "  Pipeline triggers: $($issueCommentStats.Pipeline)" -ForegroundColor DarkGray
Write-Host "  Resolved: $($issueCommentStats.Resolved)" -ForegroundColor DarkGray
Write-Host "  Active issue comments: $($issueCommentStats.Active)" -ForegroundColor Green
Write-Host ""
Write-Host "=" * 60
Write-Host "ACTIVE REVIEW COMMENTS:" -ForegroundColor Cyan
Write-Host "=" * 60

if ($activeCount -eq 0) {
    Write-Host ""
    Write-Host "(No active review comments found)" -ForegroundColor Green
} else {
    foreach ($group in $groupedThreads) {
        Write-Output ""
        Write-Output "=== File: $($group.Name) ==="

        foreach ($thread in $group.Group) {
            Write-Output ""

            # Format line location with optional range and side
            if ($thread.StartLine -and $thread.StartLine -ne $thread.Line) {
                $lineStr = "Lines $($thread.StartLine)-$($thread.Line)"
            } elseif ($thread.Line) {
                $lineStr = "Line $($thread.Line)"
            } else {
                $lineStr = "Line N/A"
            }
            if ($thread.DiffSide) {
                $sideLabel = if ($thread.DiffSide -eq "RIGHT") { "(right/new)" } else { "(left/old)" }
                $lineStr += " $sideLabel"
            }

            Write-Output "--- $lineStr ---"
            Write-Output "Author: $($thread.Author)"
            Write-Output "URL: $($thread.Url)"

            $body = $thread.Body
            if ($body.Length -gt 500) {
                $body = $body.Substring(0, 500) + "..."
            }
            Write-Output "Comment: $body"
        }
    }
}

Write-Host ""
Write-Host "=" * 60
Write-Host "PR-LEVEL REVIEW COMMENTS:" -ForegroundColor Cyan
Write-Host "=" * 60

try {
    $reviewsJson = gh api "repos/$owner/$repo/pulls/$prNumber/reviews" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $reviews = $reviewsJson | ConvertFrom-Json

        $reviewsWithBody = $reviews | Where-Object {
            $_.body -and
            $_.body.Trim() -ne "" -and
            $_.user.login -ne $prAuthor -and
            -not ($_.user.login -match "\[bot\]$")
        }

        if (($reviewsWithBody | Measure-Object).Count -eq 0) {
            Write-Host ""
            Write-Host "(No PR-level review comments)" -ForegroundColor Gray
        } else {
            foreach ($review in $reviewsWithBody) {
                Write-Output ""
                Write-Output "--- Review by $($review.user.login) ($($review.state)) ---"
                $body = $review.body
                if ($body.Length -gt 500) {
                    $body = $body.Substring(0, 500) + "..."
                }
                Write-Output $body
            }
        }
    }
} catch {
    Write-Host ""
    Write-Host "(Could not fetch PR reviews)" -ForegroundColor Red
}

Write-Host ""
Write-Host "Output written to: $outputFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "Tips:" -ForegroundColor Yellow
Write-Host "  -ShowResolved YES    Include resolved comments (for learning extraction)"
Write-Host "  -ShowResolved NO     Only active comments (for addressing PR comments)"
