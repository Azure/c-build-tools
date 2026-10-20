# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

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
jobs:
  reusable:
    uses: "Azure/c-build-tools/.github/workflows/test.yml@master" # preserve workflow comment
  short:
    uses: Azure/c-build-tools/.github/workflows/short.yml@deadbeef
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
'@

    $utf8_no_bom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $test_root ".gitmodules"), $gitmodules, $utf8_no_bom)
    [System.IO.File]::WriteAllText((Join-Path $test_root "build\devops_gated.yml"), $pipeline, $utf8_no_bom)
    [System.IO.File]::WriteAllText((Join-Path $test_root ".github\workflows\test.yml"), $workflow, $utf8_no_bom)
    [System.IO.File]::WriteAllText((Join-Path $test_root "custom\action.yml"), $action, $utf8_no_bom)

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

    assert-contains $updated_pipeline "ref: $new_sha"
    assert-contains $updated_workflow "Azure/c-build-tools/.github/workflows/test.yml@$new_sha`" # preserve workflow comment"
    assert-contains $updated_workflow "Azure/c-build-tools/.github/workflows/short.yml@$new_sha"
    assert-contains $updated_workflow "uses: ./local"
    assert-contains $updated_action "Azure/c-build-tools/actions/test@$new_sha' # preserve action comment"
    assert-contains $updated_action "uses: docker://alpine:3.20"
    assert-contains $updated_action "uses: actions/checkout@v4"
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
