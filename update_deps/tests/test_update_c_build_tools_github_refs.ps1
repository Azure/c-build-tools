# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param([string] $ValidatorExe)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\..\helper_scripts\git_operations.ps1"

function assert-contains
{
    param(
        [string] $content,
        [string] $expected
    )

    if (-not $content.Contains($expected))
    {
        throw "Expected content was not found: $expected"
    }
    else
    {
        # expected content found
    }
}

$test_root = Join-Path $env:TEMP "c-build-tools-ref-test-$([guid]::NewGuid())"

try
{
    [void](New-Item -ItemType Directory -Path (Join-Path $test_root ".github\workflows") -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $test_root "build") -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $test_root "custom") -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $test_root "deps\c-build-tools") -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $test_root ".github\workflow-templates") -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $test_root "javascript") -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $test_root ".ci\actions\test") -Force)

    git -C $test_root init --quiet
    git -C $test_root config user.email "test@example.com"
    git -C $test_root config user.name "Test User"

    $submodule_path = Join-Path $test_root "deps\c-build-tools"
    git -C $submodule_path init --quiet
    git -C $submodule_path config user.email "test@example.com"
    git -C $submodule_path config user.name "Test User"
    git -C $submodule_path commit --allow-empty --quiet -m "test commit"
    if ($LASTEXITCODE -ne 0)
    {
        throw "Failed to create the test c-build-tools commit."
    }
    else
    {
        # test commit created
    }

    $new_sha = (git -C $submodule_path rev-parse HEAD).Trim()
    if ($new_sha -notmatch '^[0-9a-f]{40}$')
    {
        throw "Failed to resolve the test c-build-tools SHA."
    }
    else
    {
        # valid SHA resolved
    }

    $gitmodules = @'
[submodule "deps/c-build-tools"]
	path = deps/c-build-tools
	url = https://github.com/Azure/c-build-tools
'@
    $pipeline = @'
resources:
  repositories:
  - repository: c_build_tools
    type: github
    name: Azure/c-build-tools
    ref: refs/heads/master
'@
    $workflow = @'
name: Test
description: |
    uses: "Azure/c-build-tools/.github/workflows/test.yml@master" # preserve workflow comment
jobs:
  reusable:
    uses: "Azure/c-build-tools/.github/workflows/test.yml@master" # preserve workflow comment
  short:
    uses: Azure/c-build-tools/.github/workflows/short.yml@deadbeef
  tag:
    uses: 'Azure/c-build-tools/.github/workflows/tag.yml@v1' # tag comment
  hash:
    uses: Azure/c-build-tools/.github/workflows/hash.yml@refs/heads/feature#1 # hash branch
  local:
    uses: ./local
'@
    $action = @'
name: Test action
runs:
  using: composite
  steps:
    - uses: 'Azure/c-build-tools/actions/test@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' # preserve action comment
    - uses: docker://alpine:3.20
    - uses: actions/checkout@v4
    # uses: Azure/c-build-tools/actions/test@comment
    - run: |
        uses: Azure/c-build-tools/actions/test@script
'@
    $javascript = @'
name: JavaScript action
description: |
  uses: Azure/c-build-tools/actions/test@description
runs:
  using: node20
  main: index.js
'@

    $utf8_no_bom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $test_root ".gitmodules"), $gitmodules, $utf8_no_bom)
    [System.IO.File]::WriteAllText((Join-Path $test_root "build\devops_gated.yml"), $pipeline, $utf8_no_bom)
    [System.IO.File]::WriteAllText((Join-Path $test_root ".github\workflows\test.yml"), $workflow, $utf8_no_bom)
    [System.IO.File]::WriteAllText((Join-Path $test_root "custom\action.yml"), $action, $utf8_no_bom)
    [System.IO.File]::WriteAllText((Join-Path $test_root ".ci\actions\test\action.yml"), $action, $utf8_no_bom)
    [System.IO.File]::WriteAllText((Join-Path $test_root "javascript\action.yaml"), $javascript, $utf8_no_bom)
    [System.IO.File]::WriteAllText((Join-Path $test_root ".github\workflow-templates\example.yml"), $workflow, $utf8_no_bom)
    git -C $test_root add -- .gitmodules
    git -C $test_root update-index --add --cacheinfo "160000,$new_sha,deps/c-build-tools"
    git -C $test_root commit --quiet -m "test dependency gitlink"
    if ($LASTEXITCODE -ne 0)
    {
        throw "Failed to create the test repository gitlink."
    }
    else
    {
        # real gitlink available for validation and propagation
    }

    if ($ValidatorExe)
    {
        & $ValidatorExe --repo-root $test_root --check c_build_tools_ref
        if ($LASTEXITCODE -ne 1) { throw "Expected invalid refs to fail validation." }
        else { # expected failure
        }
        & $ValidatorExe --repo-root $test_root --check c_build_tools_ref --fix
        if ($LASTEXITCODE -ne 0) { throw "Expected ref fixes to succeed." }
        else { # fixed
        }
        $fixed_workflow = [System.IO.File]::ReadAllText((Join-Path $test_root ".github\workflows\test.yml"))
        assert-contains $fixed_workflow "test.yml@$new_sha`" # preserve workflow comment"
        assert-contains $fixed_workflow "short.yml@$new_sha"
        assert-contains $fixed_workflow "tag.yml@$new_sha' # tag comment"
        assert-contains $fixed_workflow "hash.yml@$new_sha # hash branch"
        $fixed_action = [System.IO.File]::ReadAllText((Join-Path $test_root "custom\action.yml"))
        assert-contains $fixed_action "test@$new_sha' # preserve action comment"
        assert-contains $fixed_action "test@script"
        $fixed_hidden_action = [System.IO.File]::ReadAllText((Join-Path $test_root ".ci\actions\test\action.yml"))
        assert-contains $fixed_hidden_action "test@$new_sha' # preserve action comment"
        & $ValidatorExe --repo-root $test_root --check c_build_tools_ref
        if ($LASTEXITCODE -ne 0) { throw "Expected matching refs to pass validation." }
        else { # clean
        }
        if ([System.IO.File]::ReadAllText((Join-Path $test_root ".github\workflow-templates\example.yml")) -cne $workflow)
        { throw "Validator changed a workflow template." }
        else { # ignored
        }

        # Reset the YAML to independently exercise propagation, not validator fixes.
        [System.IO.File]::WriteAllText((Join-Path $test_root ".github\workflows\test.yml"), $workflow, $utf8_no_bom)
        [System.IO.File]::WriteAllText((Join-Path $test_root "custom\action.yml"), $action, $utf8_no_bom)
        [System.IO.File]::WriteAllText((Join-Path $test_root ".ci\actions\test\action.yml"), $action, $utf8_no_bom)
    }
    else
    {
        # propagation-only invocation
    }

    # Advance the checkout after the parent gitlink was committed.
    git -C $submodule_path commit --allow-empty --quiet -m "advanced dependency"
    $new_sha = (git -C $submodule_path rev-parse HEAD).Trim()

    Push-Location $test_root
    try
    {
        update-c-build-tools-yaml-refs
    }
    finally
    {
        Pop-Location
    }

    $updated_pipeline = [System.IO.File]::ReadAllText((Join-Path $test_root "build\devops_gated.yml"))
    $updated_workflow = [System.IO.File]::ReadAllText((Join-Path $test_root ".github\workflows\test.yml"))
    $updated_action = [System.IO.File]::ReadAllText((Join-Path $test_root "custom\action.yml"))

    if ($updated_pipeline -cne $pipeline) { throw "Propagation changed an Azure DevOps resource ref." }
    else { # ignored
    }
    assert-contains $updated_workflow "Azure/c-build-tools/.github/workflows/test.yml@$new_sha`" # preserve workflow comment"
    assert-contains $updated_workflow "Azure/c-build-tools/.github/workflows/short.yml@$new_sha"
    assert-contains $updated_workflow "tag.yml@$new_sha' # tag comment"
    assert-contains $updated_workflow "hash.yml@$new_sha # hash branch"
    assert-contains $updated_workflow "uses: ./local"
    assert-contains $updated_workflow 'uses: "Azure/c-build-tools/.github/workflows/test.yml@master" # preserve workflow comment'
    assert-contains $updated_action "Azure/c-build-tools/actions/test@$new_sha' # preserve action comment"
    assert-contains $updated_action "uses: docker://alpine:3.20"
    assert-contains $updated_action "uses: actions/checkout@v4"
    assert-contains $updated_action "test@comment"
    assert-contains $updated_action "test@script"
    $updated_hidden_action = [System.IO.File]::ReadAllText((Join-Path $test_root ".ci\actions\test\action.yml"))
    assert-contains $updated_hidden_action "test@$new_sha' # preserve action comment"
    if ([System.IO.File]::ReadAllText((Join-Path $test_root "javascript\action.yaml")) -cne $javascript)
    { throw "Propagation changed non-composite action metadata." }
    else { # ignored
    }
    if ([System.IO.File]::ReadAllText((Join-Path $test_root ".github\workflow-templates\example.yml")) -cne $workflow)
    { throw "Propagation changed a workflow template." }
    else { # ignored
    }

    git -C $test_root add -- deps/c-build-tools .github/workflows/test.yml custom/action.yml .ci/actions/test/action.yml
    git -C $test_root commit --quiet -m "propagate dependency and pins"
    if ($LASTEXITCODE -ne 0) { throw "Failed to commit propagated change." }
    else { # committed
    }
    if ($ValidatorExe)
    {
        & $ValidatorExe --repo-root $test_root --check c_build_tools_ref
        if ($LASTEXITCODE -ne 0) { throw "Propagated pins do not match the new gitlink." }
        else { # parity verified
        }
        $modules_path = Join-Path $test_root ".gitmodules"
        foreach ($bad_modules in @("", $gitmodules.Replace("deps/c-build-tools", "other/tools"), $gitmodules.Replace("Azure/c-build-tools", "other/c-build-tools")))
        {
            [System.IO.File]::WriteAllText($modules_path, $bad_modules, $utf8_no_bom)
            & $ValidatorExe --repo-root $test_root --check c_build_tools_ref --fix
            if ($LASTEXITCODE -ne 1) { throw "References without a matching dependency must fail, including fix mode." }
            else { # expected failure
            }
        }
        [System.IO.File]::WriteAllText($modules_path, $gitmodules, $utf8_no_bom)
        [System.IO.File]::WriteAllText((Join-Path $test_root ".github\workflows\test.yml"), "name: no references", $utf8_no_bom)
        [System.IO.File]::WriteAllText((Join-Path $test_root "custom\action.yml"), "name: no references", $utf8_no_bom)
        [System.IO.File]::WriteAllText((Join-Path $test_root ".ci\actions\test\action.yml"), "name: no references", $utf8_no_bom)
        & $ValidatorExe --repo-root $test_root --check c_build_tools_ref
        if ($LASTEXITCODE -ne 0) { throw "Submodule-only repository must pass." }
        else { # no references
        }
        [System.IO.File]::WriteAllText($modules_path, "", $utf8_no_bom)
        & $ValidatorExe --repo-root $test_root --check c_build_tools_ref
        if ($LASTEXITCODE -ne 0) { throw "Repository with neither submodule nor references must pass." }
        else { # no dependency
        }
        [System.IO.File]::WriteAllText($modules_path, $gitmodules, $utf8_no_bom)
        [System.IO.File]::WriteAllText((Join-Path $test_root ".github\workflows\test.yml"), $workflow, $utf8_no_bom)
        git -C $test_root update-index --force-remove -- deps/c-build-tools
        git -C $test_root commit --quiet -m "remove gitlink"
        $diagnostics = & $ValidatorExe --repo-root $test_root --check c_build_tools_ref
        if ($LASTEXITCODE -ne 1) { throw "A .gitmodules entry without a gitlink must fail." }
        else { # expected failure
        }
        assert-contains (($diagnostics -join "`n").Replace('\', '/')) ".github/workflows/test.yml:6"
        assert-contains ($diagnostics -join "`n") "uses ref 'master' has no matching deps/c-build-tools gitlink"
        & $ValidatorExe --repo-root $test_root --check c_build_tools_ref --fix
        if ($LASTEXITCODE -ne 1) { throw "Fix mode must not accept references without a gitlink." }
        else { # cannot fix a missing gitlink
        }
        $blob_sha = git -C $test_root hash-object -w -- .gitmodules
        git -C $test_root update-index --add --cacheinfo "100644,$blob_sha,deps/c-build-tools"
        git -C $test_root commit --quiet -m "ordinary file is not a submodule"
        & $ValidatorExe --repo-root $test_root --check c_build_tools_ref
        if ($LASTEXITCODE -ne 1) { throw "An ordinary file must not be treated as a gitlink." }
        else { # expected failure
        }
    }
    else
    {
        # propagation-only invocation
    }
}
finally
{
    if (Test-Path $test_root)
    {
        Remove-Item -Path $test_root -Recurse -Force
    }
    else
    {
        # test directory was not created
    }
}
