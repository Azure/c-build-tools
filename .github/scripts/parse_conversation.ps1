# parse_conversation.ps1
# Parses Claude Code conversation JSONL transcripts to find learnings
# Looks for user corrections, repeated instructions, and explicit rules
#
# Usage:
#   pwsh -File .github/scripts/parse_conversation.ps1 -jsonlFile "<path-to-jsonl>"
#   pwsh -File .github/scripts/parse_conversation.ps1 -jsonlFile "<path-to-jsonl>" -ShowAll
#
# Conversation transcripts are stored at:
#   ~/.claude/projects/<project-id>/<conversation-id>.jsonl
# The conversation ID is shown in compaction summary messages.

param(
    [string]$jsonlFile = "",
    [switch]$ShowAll = $false
)

# If no file provided, prompt for it
if (-not $jsonlFile) {
    Write-Host "Usage: pwsh -File parse_conversation.ps1 -jsonlFile '<path-to-jsonl>'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Conversation transcripts are at: ~/.claude/projects/<project-id>/<conversation-id>.jsonl"
    Write-Host "The conversation ID is shown in compaction summary messages."
    exit 1
}

# Validate file exists
if (-not (Test-Path $jsonlFile)) {
    Write-Error "File not found: $jsonlFile"
    exit 1
}

Write-Host "Parsing conversation transcript: $jsonlFile" -ForegroundColor Cyan
Write-Host "=" * 60

# Patterns that indicate user corrections/teachings
$correctionPatterns = @(
    "no,\s*(you\s+)?should",
    "that's\s+(wrong|not\s+right|incorrect)",
    "don't\s+do\s+that",
    "instead\s+(of|use)",
    "always\s+(use|do|make\s+sure)",
    "never\s+(use|do)",
    "remember\s+to",
    "i\s+(already\s+)?told\s+you",
    "the\s+correct\s+(way|pattern|approach)",
    "we\s+prefer",
    "team\s+convention",
    "HAE",
    "here\s+and\s+everywhere"
)

$correctionRegex = ($correctionPatterns -join "|")

# Read and parse JSONL
$lines = Get-Content $jsonlFile
$conversations = @()
$potentialLearnings = @()

$lineNum = 0
foreach ($line in $lines) {
    $lineNum++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try {
        $entry = $line | ConvertFrom-Json

        # Look for user messages
        # JSONL structure: { "type": "user", "message": { "role": "user", "content": [{"type": "text", "text": "..."}] } }
        if ($entry.type -eq "user") {
            $content = ""

            # Primary path: message.content array (Claude Code JSONL format)
            if ($entry.message -and $entry.message.content) {
                if ($entry.message.content -is [array]) {
                    $content = ($entry.message.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n"
                } elseif ($entry.message.content -is [string]) {
                    $content = $entry.message.content
                }
            }
            # Fallback: direct content property
            elseif ($entry.content) {
                if ($entry.content -is [string]) {
                    $content = $entry.content
                } elseif ($entry.content -is [array]) {
                    $content = ($entry.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n"
                }
            }

            if ($content) {
                $conversations += @{
                    Type = "user"
                    Content = $content
                    LineNum = $lineNum
                }

                # Check for correction patterns
                if ($content -imatch $correctionRegex) {
                    $potentialLearnings += @{
                        Type = "correction"
                        Content = $content
                        LineNum = $lineNum
                        MatchedPattern = $Matches[0]
                    }
                }
            }
        }
    }
    catch {
        # Skip malformed lines
        continue
    }
}

Write-Host "`nFound $($conversations.Count) user messages in transcript"
Write-Host "Found $($potentialLearnings.Count) potential learning moments`n"

if ($potentialLearnings.Count -gt 0) {
    Write-Host "=" * 60
    Write-Host "POTENTIAL LEARNINGS (user corrections/instructions):" -ForegroundColor Green
    Write-Host "=" * 60

    foreach ($learning in $potentialLearnings) {
        Write-Host "`n--- Line $($learning.LineNum) (matched: '$($learning.MatchedPattern)') ---" -ForegroundColor Yellow
        # Truncate long content for display
        $displayContent = $learning.Content
        if ($displayContent.Length -gt 500) {
            $displayContent = $displayContent.Substring(0, 500) + "..."
        }
        Write-Host $displayContent
    }
}

if ($ShowAll) {
    Write-Host "`n`n"
    Write-Host "=" * 60
    Write-Host "ALL USER MESSAGES:" -ForegroundColor Cyan
    Write-Host "=" * 60

    foreach ($msg in $conversations) {
        Write-Host "`n--- Line $($msg.LineNum) ---"
        $displayContent = $msg.Content
        if ($displayContent.Length -gt 300) {
            $displayContent = $displayContent.Substring(0, 300) + "..."
        }
        Write-Host $displayContent
    }
}

Write-Host "`n`nTip: Use -ShowAll to see all user messages, not just potential learnings"
