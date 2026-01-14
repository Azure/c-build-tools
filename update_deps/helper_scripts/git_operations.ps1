# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Git operations functions for propagate_updates.ps1

# create a global variable $ignore_pattern
# $ignore pattern is used in the shell command for 'git submodule foreach' to ignore repos
function create-ignore-pattern {
    $path_to_ignores = Join-Path $PSScriptRoot "..\ignores.json"
    # get list of repos to ignore from ignores.json
    $repos_to_ignore = (Get-Content -Path $path_to_ignores) | ConvertFrom-Json
    $ignore_list = New-Object -TypeName "System.Collections.ArrayList"
    # prepend "deps/" to the name of each repo
    foreach($repo_to_ignore in $repos_to_ignore) {
        [void]$ignore_list.Add("deps/"+$repo_to_ignore)
    }
    # join repo names to get pattern of the form "deps/{repo1}|deps/repo{2}|..."
    $global:ignore_pattern = $ignore_list -join "|"
}

# Initialize the ignore pattern when script is sourced
create-ignore-pattern

function refresh-submodules {
    $submodules = git submodule | Out-String
    Get-ChildItem "deps\" | ForEach-Object {
        # There can be folders in deps\ that are not listed in .gitmodules.
        # Only delete dep that is listed in .gitmodules
        if($submodules.Contains($_.Name)) {
            Remove-Item $_.FullName -Recurse -Force
        }
        else {
            # not a submodule, leave it
        }
    }
}

# update the submodules of the given repo and push changes
# returns $true if the local repo was update
# returns $false if no changes were made
function update-local-repo {
    param (
        [string] $repo_name,
        [string] $new_branch_name
    )
    Push-Location $repo_name
    git checkout master
    git pull
    # Sometimes git fails to detect updates in submodules
    # Fix is to delete the submodule and reinitializes it
    if (Test-Path "deps\") {
        refresh-submodules
    }
    else {
        # no deps folder
    }
    git submodule update --init
    # update all submodules except the ones mentioned in ignores.json
    git submodule foreach "case `$name in $ignore_pattern ) ;; *) git checkout master && git pull;; esac"
    # create new branch
    git checkout -B $new_branch_name
    # add updates and push to remote
    git add .
    $commit_output = git commit -m "Update dependencies" 2>&1
    $commit_result = $LASTEXITCODE
    # Only push if commit succeeded (there were changes)
    if($commit_result -eq 0) {
        git push -f origin $new_branch_name
    }
    else {
        # nothing to push
    }
    Pop-Location
    # Return the commit output for caller to check
    return $commit_output
}

# determine whether given repo is an azure repo or a github repo
function get-repo-type {
    param (
        [string] $repo_name
    )
    Push-Location $repo_name
    $repo_url = git config --get remote.origin.url
    Pop-Location
    Write-Host $repo_url -NoNewline
    if($repo_url.Contains("github")){
        return "github"
    }elseif ($repo_url.Contains("azure") -or $repo_url.Contains("visualstudio.com")) {
        return "azure"
    }
    return "unknown"
}
