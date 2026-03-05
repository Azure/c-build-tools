# @Copyright (c) Microsoft. All rights reserved.

#this script checks for every submodule of the current repo if its SHA is an ancestor of SHA at the current the master branch of the submodule

Param(
    # A comma-separated list of submodule paths to ignore when performing the check
    $ignoreSubmodules = "",
    # Custom branches to check against instead of the default master branch, can be specified as a comma-separated list in format "submodulePath:branchName"
    # Example: "deps/submodule1:main,deps/submodule2:develop"
    $customSubmoduleBranches = ""
)

# Initialize return code to 0
$global:returnCode = 0

$ignoreSubmoduleParts = $ignoreSubmodules -split ','

$customSubmoduleBranchParts = $customSubmoduleBranches -split ','

# Iterate over each submodule
$submodules = git submodule foreach --quiet 'echo $name $sha1'
foreach ($submodule in $submodules) {
    $parts = $submodule -split ' '
    $submodulePath = $parts[0]
    $submoduleSHA = $parts[1]

    # Check if the submodule path is in the ignore list
    if ($ignoreSubmoduleParts -contains $submodulePath) {
        Write-Host "Ignoring submodule $submodulePath"
        continue
    }

    # Determine the branch to check against
    $branchToCheck = "master"  # Default branch
    foreach ($customBranch in $customSubmoduleBranchParts) {
        $branchParts = $customBranch -split ':'

        # Check if the submodule path matches the custom branch definition
        if ($branchParts[0] -eq $submodulePath) {
            if ($branchParts.Length -gt 1){
                $branchToCheck = $branchParts[1]
            }
            break
        }
    }

    # Navigate to the submodule directory
    Push-Location -LiteralPath $submodulePath

    # Fetch the latest changes from the remote repository
    git fetch origin

    # compute ref
    $ref = "refs/remotes/origin/$branchToCheck"
    $originBranch = "origin/$branchToCheck"

    # Check if the SHA is an ancestor of the desired branch
    git merge-base --is-ancestor $submoduleSHA $originBranch

    $isAncestor = $LASTEXITCODE -eq 0

    if ($isAncestor) {
        Write-Host "SHA $submoduleSHA found in $branchToCheck branch of $submodulePath"
    } else {
        Write-Host "##[warning]SHA $submoduleSHA not found in $branchToCheck branch of $submodulePath"
        $global:returnCode = 1
    }

    # Navigate back to the main repo
    Pop-Location
}

# Report results but don't fail the build (temporary for parallel ARM64 development)
if ($global:returnCode -ne 0) {
    Write-Host "##[warning]============================================================"
    Write-Host "##[warning]SUBMODULE MASTER CHECK: Issues detected but not blocking build"
    Write-Host "##[warning]============================================================"
}

# Always exit 0 - check is informational only during parallel development
exit 0