# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Fun animation showing dependencies propagating through a tree

function play-success-animation
{
    param(
        [int] $speed = 80  # milliseconds between frames
    )

    # Save cursor and clear screen
    $originalCursorVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    Clear-Host

    # Tree structure - each level represents depth in dependency tree
    # Characters: ○ = pending, ● = propagated, ◉ = currently propagating
    # Topological order: bottom (leaves) to top (root)

    $tree_frames = @(
        # Frame 0 - all pending
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ○  ○   ○   ○  ○
                                    /|  |   |   |  |\
                                   ○ ○  ○   ○   ○  ○ ○


"@,
        # Frame 1 - bottom row (leaves) lighting up left to right
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ○  ○   ○   ○  ○
                                    /|  |   |   |  |\
                                   ◉ ○  ○   ○   ○  ○ ○


"@,
        # Frame 2
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ○  ○   ○   ○  ○
                                    /|  |   |   |  |\
                                   ● ◉  ○   ○   ○  ○ ○


"@,
        # Frame 3
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ○  ○   ○   ○  ○
                                    /|  |   |   |  |\
                                   ● ●  ◉   ○   ○  ○ ○


"@,
        # Frame 4
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ○  ○   ○   ○  ○
                                    /|  |   |   |  |\
                                   ● ●  ●   ◉   ○  ○ ○


"@,
        # Frame 5
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ○  ○   ○   ○  ○
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ◉  ○ ○


"@,
        # Frame 6
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ○  ○   ○   ○  ○
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ◉ ○


"@,
        # Frame 7 - bottom row complete
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ○  ○   ○   ○  ○
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ◉


"@,
        # Frame 8 - level 2 starting (left to right)
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ◉  ○   ○   ○  ○
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@,
        # Frame 9
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ●  ◉   ○   ○  ○
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@,
        # Frame 10
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ●  ●   ◉   ○  ○
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@,
        # Frame 11
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ●  ●   ●   ◉  ○
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@,
        # Frame 12 - level 2 complete
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ○   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ●  ●   ●   ●  ◉
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@,
        # Frame 13 - level 3 starting
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ◉   ○   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ●  ●   ●   ●  ●
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@,
        # Frame 14
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ●   ◉   ○
                                       /|   |   |\
                                      / |   |   | \
                                     ●  ●   ●   ●  ●
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@,
        # Frame 15 - level 3 complete
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ○
                                           /|\
                                          / | \
                                         /  |  \
                                        ●   ●   ◉
                                       /|   |   |\
                                      / |   |   | \
                                     ●  ●   ●   ●  ●
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@,
        # Frame 16 - root propagating
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ◉
                                           /|\
                                          / | \
                                         /  |  \
                                        ●   ●   ●
                                       /|   |   |\
                                      / |   |   | \
                                     ●  ●   ●   ●  ●
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@,
        # Frame 17 - all complete
        @"

                              ┌─────────────────────────────────────┐
                              │   DEPENDENCY PROPAGATION COMPLETE   │
                              └─────────────────────────────────────┘

                                            ●
                                           /|\
                                          / | \
                                         /  |  \
                                        ●   ●   ●
                                       /|   |   |\
                                      / |   |   | \
                                     ●  ●   ●   ●  ●
                                    /|  |   |   |  |\
                                   ● ●  ●   ●   ●  ● ●


"@
    )

    # Play animation
    foreach ($frame in $tree_frames)
    {
        [Console]::SetCursorPosition(0, 0)

        # Color the output
        $lines = $frame -split "`n"
        foreach ($line in $lines)
        {
            $colored_line = $line
            # Write character by character for coloring
            foreach ($char in $colored_line.ToCharArray())
            {
                switch ($char)
                {
                    '●' { Write-Host $char -NoNewline -ForegroundColor Green }
                    '◉' { Write-Host $char -NoNewline -ForegroundColor Yellow }
                    '○' { Write-Host $char -NoNewline -ForegroundColor DarkGray }
                    '│' { Write-Host $char -NoNewline -ForegroundColor Cyan }
                    '─' { Write-Host $char -NoNewline -ForegroundColor Cyan }
                    '┌' { Write-Host $char -NoNewline -ForegroundColor Cyan }
                    '┐' { Write-Host $char -NoNewline -ForegroundColor Cyan }
                    '└' { Write-Host $char -NoNewline -ForegroundColor Cyan }
                    '┘' { Write-Host $char -NoNewline -ForegroundColor Cyan }
                    default { Write-Host $char -NoNewline -ForegroundColor White }
                }
            }
            Write-Host ""
        }

        Start-Sleep -Milliseconds $speed
    }

    # Celebration sparkles
    $sparkle_chars = @('✨', '⭐', '🌟', '💫', '✦', '★')
    $positions = @(
        @{X=20; Y=3}, @{X=60; Y=3}, @{X=40; Y=5},
        @{X=15; Y=8}, @{X=65; Y=8}, @{X=35; Y=10},
        @{X=45; Y=10}, @{X=25; Y=12}, @{X=55; Y=12}
    )

    for ($i = 0; $i -lt 6; $i++)
    {
        foreach ($pos in $positions)
        {
            if ((Get-Random -Maximum 3) -eq 0)
            {
                [Console]::SetCursorPosition($pos.X, $pos.Y)
                $sparkle = $sparkle_chars[(Get-Random -Maximum $sparkle_chars.Count)]
                Write-Host $sparkle -NoNewline -ForegroundColor Yellow
            }
        }
        Start-Sleep -Milliseconds 150

        # Clear sparkles
        foreach ($pos in $positions)
        {
            [Console]::SetCursorPosition($pos.X, $pos.Y)
            Write-Host " " -NoNewline
        }
        Start-Sleep -Milliseconds 100
    }

    # Final message
    [Console]::SetCursorPosition(0, 16)
    Write-Host ""
    Write-Host "                                   " -NoNewline
    Write-Host "ALL REPOS UPDATED!" -ForegroundColor Green
    Write-Host ""

    # Restore cursor
    [Console]::CursorVisible = $originalCursorVisible
}
