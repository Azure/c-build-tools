# @Copyright (c) Microsoft. All rights reserved.

#this script checks for every submodule of the current repo if its SHA is an ancestor of SHA at the current the master branch of the submodule

# Initialize return code to 0
$global:returnCode = 0

# Iterate over each submodule
$submodules = git submodule foreach --quiet 'echo $name $sha1'
foreach ($submodule in $submodules) {
    $parts = $submodule -split ' '
    $submodulePath = $parts[0]
    $submoduleSHA = $parts[1]

    # Navigate to the submodule directory
    Push-Location -LiteralPath $submodulePath

    # Fetch the latest changes from the remote repository
    git fetch origin

    # Check if the master branch exists
    git show-ref --verify --quiet refs/remotes/origin/master

    # Capture the exit code
    $exitCode = $LASTEXITCODE

    if ($exitCode -gt 0) {
        Write-Host "Master branch not found in $submodulePath, skipping..."
    } else {
        # Check if the SHA is an ancestor of the master branch
        git merge-base --is-ancestor $submoduleSHA origin/master

        $isAncestor = $LASTEXITCODE -eq 0

        if ($isAncestor) {
           Write-Host "SHA $submoduleSHA found in master branch of $submodulePath"
        } else {
            
            Write-Host "SHA $submoduleSHA not found in master branch of $submodulePath"
            $global:returnCode = 1
        }
    }

    # Navigate back to the main repo
    Pop-Location
}

# Exit with the appropriate return code
exit $global:returnCode