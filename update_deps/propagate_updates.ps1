# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

<#
.SYNOPSIS

Propagates dependency updates for git repositories.

.DESCRIPTION

Given a root repo and personal access tokens for Github and Azure Devops Services, this script \
builds the dependency graph and propagates updates from the lowest level up to the \
root repo by making PRs to each repo in bottom-up level-order.

.PARAMETER root

URL of the repository upto which updates must be propagated.

.PARAMETER github_token

Personal access token for Github

.PARAMETER azure_token

Personal access token for Azure Devops Services

.PARAMETER azure_work_item

Work item id that is linked to PRs made to Azure repos.

.INPUTS

ignore.json: list of repositories that must be ignored for updates.
order.json: reads order in which repositories must be updated from order.json

.OUTPUTS

None.

.EXAMPLE

PS> .\{PATH_TO_SCRIPT}\propagate_updates.ps1 -azure_token {token1} -github_token {token2} [-root {root_repo_url}]
#>


param(
    [Parameter(Mandatory=$true)][string]$root, # url for repo upto which updates must be propagated
    [Parameter(Mandatory=$true)][string]$github_token, # Github personal access token: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token
    [Parameter(Mandatory=$true)][string]$azure_token, # Azure Devops Services personal access token: https://docs.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate?view=azure-devops&tabs=preview-page
    [Parameter(Mandatory=$true)][Int32]$azure_work_item # Azure Devops Services personal access token: https://docs.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate?view=azure-devops&tabs=preview-page
)


# sleep for $seconds seconds and play spinner animation
function spin {
    param(
        [int] $seconds
    )
    $steps = @('|','/','-','\')
    $interval_ms = 50
    for($i=0; $i -lt (($seconds*1000)/$interval_ms); $i++){
        Write-Host "`b$($steps[$i % $steps.Length])" -NoNewline -ForegroundColor Yellow
        Start-Sleep -Milliseconds $interval_ms
    }
    # erase spinner
    Write-Host "`b"-NoNewLine
}


# create a global variable $ignore_pattern
# $ignore pattern is used in the shell command for 'git submodule foreach' to ignore repos
function create-ignore-pattern {
    $path_to_ignores = $PSScriptRoot + "\ignores.json"
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

create-ignore-pattern

# name for branch which will be used to create PR
$new_branch_name = "new_deps"

function refresh-submodules {
    $submodules = git submodule | Out-String
    Get-ChildItem "deps\" | ForEach-Object {
        # There can be folders in deps\ that are not listed in .gitmodules.
        # Only delete dep that is listed in .gitmodules
        if($submodules.Contains($_.Name)) {
            Remove-Item $_.FullName -Recurse -Force
        }
    }
}

# update the submodules of the given repo and push changes
# returns $true if the local repo was update
# returns $false if no changes were made
function update-local-repo {
    param (
        [string] $repo_name
    )
    cd $repo_name
    git checkout master
    git pull
    # Sometimes git fails to detect updates in submodules
    # Fix is to delete the submodule and reinitializes it
    if (Test-Path "deps\") {
        refresh-submodules
    }
    git submodule update --init
    # update all submodules except the ones mentioned in ignores.json
    git submodule foreach "case `$name in $ignore_pattern ) ;; *) git checkout master && git pull;; esac"
    # delete pre-existing branch
    git branch -D $new_branch_name
    # create new branch
    git checkout -b $new_branch_name
    # add updates and push to remote
    git add .
    git commit -m "Update dependencies"
    git push -f origin $new_branch_name
    cd ..
}


# create global variable $github_header
# $github_header is used to authenticate requests to the Github REST API: https://docs.github.com/en/rest
function create-header-github {
    param(
        [string] $token
    )
    $global:github_header = @{
        Authorization="token $token"
    }
}

create-header-github $github_token


# create PR to update dependencies for Github repo
function create-pr-github {
    param(
        [string] $repo_name
    )
    $request_url = "https://api.github.com/repos/Azure/$repo_name/pulls"
    $body = @{
        title='[autogenerated] update dependencies'
        head='new_deps'
        base='master'
    }
    $body = $body | ConvertTo-Json
    $response = Invoke-WebRequest -URI $request_url -UseBasicParsing -Method Post -Headers $github_header -Body $body
    if(!$response) {
        Write-Error "Failed to create PR for repo $repo_name"
        exit -1
    }
    $content = $response.Content | ConvertFrom-Json
    $api_url = $content.url
    $html_url = $content.html_url
    return $api_url, $html_url
}


# wait until build completes for Github repo
function wait-until-mergeable-github {
    param(
        [string] $repo_name,
        [string] $api_url,
        [string] $html_url
    )
    $request_url = "https://api.github.com/repos/Azure/$repo_name/commits/$new_branch_name/check-runs"

    # iterate over all check-runs
    while($true) {
        spin 10
        # get checks-runs
        $check_run_response = Invoke-WebRequest -URI $request_url -UseBasicParsing -Method Get -Headers $github_header
        if(!$check_run_response) {
            Write-Error "Failed to get check-run status for PR: $html_url"
            exit -1
        }
        $check_run_content = $check_run_response.Content | ConvertFrom-Json
        $check_runs = $check_run_content.check_runs
        if($check_runs.Length -eq 0) {
            # retry if check-runs have not started yet
            continue
        }
        for($i=0; $i -lt $check_runs.Length; $i++) {
            $check = $check_runs[$i]
            # if check has not completed, wait and retry
            if($check.status -ne "completed") {
                break
            }
            # if check has complete but was not successful, throw error
            elseif ($check.conclusion -ne "success") {
                Write-Error "Checks are failing for PR: $html_url"
                exit -1
            }
            # if all checks have completed and were successful, exit while loop
            if($i -eq ($check_runs.Length - 1)) {
                # timeout to let mergeable state stabilize
                spin 10
                $get_pr_response = Invoke-WebRequest -URI $api_url -UseBasicParsing -Method Get -Headers $github_header
                if(!$get_pr_response) {
                    Write-Error "Failed to get PR: $html_url"
                    exit -1
                }
                $get_pr_response = $get_pr_response.Content | ConvertFrom-Json
                # PR should be in mergeable_state "clean"
                # if it is not, something unexpected happened and error should be thrown
                if($get_pr_response.mergeable_state -ne "clean"){
                    Write-Host "Unexpected mergeable state `"$($get_pr_response.mergeable_state)`" for PR: $html_url"
                    exit -1
                }
                return
            }
        }
    }
}


# merge Github PR into master
function merge-pr-github {
    param(
        [string] $api_url,
        [string] $html_url
    )
    $request_url = $api_url + "/merge"
    $body = @{
        merge_method="squash"
    }
    $body = $body | ConvertTo-Json
    $response = Invoke-WebRequest -URI $request_url -UseBasicParsing -Method Put -Headers $github_header -Body $body
    if(!$response) {
        Write-Error "Failed to merge PR: $html_url"
        exit -1
    }
    $content = $response.Content | ConvertFrom-Json
    # if PR fails to merge, throw error
    if(!$content.merged){
        Write-Error "Failed to merge PR: $html_url"
        Write-Error $content
        exit -1
    }
}


# update dependencies for Github repo
function update-repo-github {
    param(
        [string] $repo_name
    )
    Write-Host "`nCreating PR"
    $api_url, $html_url = create-pr-github $repo_name
    Write-Host "Waiting for build to complete"
    wait-until-mergeable-github $repo_name $api_url $html_url
    Write-Host "Merging PR"
    merge-pr-github $api_url $html_url
}


# create global variable $azure_header
# $azure_header is used to authenticate requests to the Azure Devops Services API: https://docs.microsoft.com/en-us/rest/api/azure/devops/?view=azure-devops-rest-6.1
function create-header-azure {
    param(
        [string] $token
    )
    $base64_azure_pat = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":$token"))
    $global:azure_header = @{
        Authorization="Basic $base64_azure_pat"
    }
}

create-header-azure $azure_token


# create PR to update dependencies for Azure repo
function create-pr-azure {
    param(
        [string] $repo_name
    )
    $request_url = "https://dev.azure.com/msazure/One/_apis/git/repositories/$repo_name/pullrequests?api-version=6.0"
    $body = @{
        sourceRefName='refs/heads/new_deps'
        targetRefName='refs/heads/master'
        title='[autogenerated] update dependencies'
    }
    $body = $body | ConvertTo-Json
    $response = Invoke-WebRequest -URI $request_url -UseBasicParsing -Method Post -Headers $azure_header -Body $body -ContentType "application/json"
    if(!$response) {
        Write-Error "Failed to create PR for repo $repo_name"
        exit -1
    }
    $content = $response.Content | ConvertFrom-Json
    return $content
}


# link work item to PR for Azure repo
function link-work-item-to-pr-azure {
    param(
        [string] $pr_artifact_id
    )
    if(!$azure_work_item){
        Write-Error "Updating Azure repos requires providing a work item id. Provide work item id as: -azure_work_item [id]"
        exit -1
    }
    $request_url = 'https://dev.azure.com/msazure/One/_apis/wit/workitems/'+$azure_work_item+'?api-version=6.0'
    # body format found here: https://stackoverflow.com/questions/65111930/how-to-link-a-work-item-to-a-pull-request-using-rest-api-in-azure-devops
    $body = @(
        @{
            op='add'
            path='/relations/-'
            value=@{
                rel='ArtifactLink'
                url=$pr_artifact_id
                attributes=@{
                    name="pull request"
                }
            }
        }
    )
    $body = $body | ConvertTo-Json
    # This PATCH endpoint takes a list of patch objects so $body must be encased in a list
    $response = Invoke-WebRequest -URI $request_url -UseBasicParsing -Method Patch -Headers $azure_header -Body "[$body]" -ContentType "application/json-patch+json"
    if(!$response) {
        Write-Error "Failed to link work item to PR.`nWork item: $work_item_id`nPR: $pr_artifact_id"
        exit -1
    }
}


# approve PR for Azure repo
function approve-pr-azure {
    param(
        [string] $pr_url,
        [string] $creator_id
    )
    $request_url = $pr_url + '/reviewers/' + $creator_id + '?api-version=6.0'
    $body = @{
        vote=10
    }
    $body = $body | ConvertTo-Json
    $response = Invoke-WebRequest -URI $request_url -UseBasicParsing -Method Put -Headers $azure_header -Body $body -ContentType "application/json"
    if(!$response) {
        Write-Error "Failed to approve PR: $pr_url"
        exit -1
    }
}


# set PR for Azure repo to merge automatically once build completes
function set-autocomplete-azure {
    param(
        $pr_url,
        $creator_id
    )
    $request_url = $pr_url + '?api-version=6.0'
    $body =@{
        autoCompleteSetBy=@{
            id=$creator_id
        }
        completionOptions=@{
            mergeStrategy="squash"
        }
    }
    $body = $body | ConvertTo-Json
    $response = Invoke-WebRequest -URI $request_url -UseBasicParsing -Method Patch -Headers $azure_header -Body $body -ContentType "application/json"
    if(!$response) {
        Write-Error "Failed to set autocomplete for PR $pr_url"
        exit -1
    }
}


# wait until build completes for Azure repo
function wait-until-complete-azure {
    param(
        [string] $pr_url
    )
    $status = ""
    while($true){
        $response = Invoke-WebRequest -URI $pr_url -UseBasicParsing -Method Get -Headers $azure_header
        if(!$response) {
            Write-Error "Failed to get PR: $pr_url"
            exit -1
        }
        $content =  $response.Content | ConvertFrom-Json
        $status = $content.status
        $merge_status = $content.mergeStatus
        if($status -ne "active" -or !($merge_status -eq "succeeded" -or $merge_status -eq "queued")) {
            break
        }
        spin 10
    }
    if($status -ne "completed") {
        Write-Host "Problem with pull request: $pr_url"
        Write-Error $response.Content
        exit -1
    }
}


# update dependencies for Azure repo
function update-repo-azure {
    param(
        [string] $repo_name
    )
    Write-Host "`nCreating PR"
    $create_pr_response = create-pr-azure $repo_name
    $pr_artifact_id = $create_pr_response.artifactId
    Write-Host "Linking work item to PR"
    link-work-item-to-pr-azure $pr_artifact_id
    Write-Host "Approving PR"
    approve-pr-azure $create_pr_response.url $create_pr_response.createdBy.id
    Write-Host "Enabling PR to autocomplete"
    set-autocomplete-azure $create_pr_response.url $create_pr_response.createdBy.id
    Write-Host "Waiting for build to complete"
    wait-until-complete-azure $create_pr_response.url
}


# determine whether given repo is an azure repo or a github repo
function  get-repo-type {
    param (
        [string] $repo_name
    )
    cd $repo_name
    $repo_url = git config --get remote.origin.url
    cd ..
    Write-Host $repo_url -NoNewline
    if($repo_url.Contains("github")){
        return "github"
    }elseif ($repo_url.Contains("azure")) {
        return "azure"
    }
    return "unknown"
}


# update dependencies for given repo
function update-repo {
    param(
        [string] $repo_name
    )
    Write-Host "`n`nUpdating repo $repo_name"
    [string]$git_output = (update-local-repo $repo_name)
    if($git_output.Contains("nothing to commit")) {
        Write-Host "Nothing to commit, skipping repo $repo_name"
    } else {
        $repo_type = get-repo-type $repo_name
        if($repo_type -eq "github") {
            update-repo-github $repo_name
        } elseif ($repo_type -eq "azure") {
            update-repo-azure $repo_name
        } else {
            Write-Error "Unable to update repository $repo_name. Only Github and Azure repositories are supported."
            exit -1
        }
    }
    Write-Host "Done updating repo $repo_name"
}

function clear-directory {
    $proceed = Read-Host("This script will clear the current directory. Enter [Y] to proceed.")
    if($proceed -ne "Y")
    {
        exit 0
    }
    $Path = Get-Location | Select -expand Path
    Set-Location ..
    Remove-Item -LiteralPath $Path -Recurse -Force
    $out = mkdir $Path
    Set-Location $Path
}

# iterate over all repos and update them
function propagate-updates {
    clear-directory
    # build dependency graph
    Write-Host "Building dependency graph..."
    .$PSScriptRoot\build_graph.ps1 $root
    if($LASTEXITCODE -ne 0)
    {
        Write-Error("Could not build dependency graph.")
        exit -1
    }
    Write-Host "Done building dependency graph"
    $repo_order = (Get-Content -Path order.json) | ConvertFrom-Json
    Write-Host "Updating repositories in the following order: "
    for($i = 0; $i -lt $repo_order.Length; $i++){
        Write-Host "$($i+1). $($repo_order[$i])"
    }
    foreach ($repo in $repo_order) {
        update-repo $repo
    }
    Write-Host "Done updating all repos!"
}

propagate-updates
