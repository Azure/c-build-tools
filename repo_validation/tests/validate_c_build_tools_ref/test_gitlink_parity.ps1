# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param([Parameter(Mandatory=$true)][string] $ValidatorExe)

$ErrorActionPreference = "Stop"
$test_root = Join-Path $env:TEMP "c-build-tools-ref-test-$([guid]::NewGuid())"
$utf8 = New-Object System.Text.UTF8Encoding $false
$sha = "aabbccdd00112233445566778899aabbccddeeff"

function write-fixture
{
    param([string] $path, [string] $content)
    $full_path = Join-Path $test_root $path
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full_path))
    [System.IO.File]::WriteAllText($full_path, $content, $utf8)
}

function assert-validation
{
    param([int] $exit_code, [switch] $Fix)
    $options = @("--repo-root", $test_root, "--check", "c_build_tools_ref")
    if ($Fix) { $options += "--fix" }
    else { # detection only
    }
    $output = & $ValidatorExe @options
    if ($LASTEXITCODE -ne $exit_code)
    {
        throw "Expected exit $exit_code, got $LASTEXITCODE`n$($output -join "`n")"
    }
    else { # expected result
    }
    return ($output -join "`n").Replace('\', '/')
}

function assert-content
{
    param([string] $path, [string] $expected)
    if ([System.IO.File]::ReadAllText((Join-Path $test_root $path)) -cne $expected)
    {
        throw "Unexpected content in $path"
    }
    else { # exact bytes decoded as UTF-8, including quotes/comments/line endings
    }
}

try
{
    [void][System.IO.Directory]::CreateDirectory($test_root)
    git -C $test_root init --quiet
    git -C $test_root config user.email "test@example.com"
    git -C $test_root config user.name "Test User"
    $modules = @'
[submodule "tools"]
    path = deps/c-build-tools
    url = https://github.com/Azure/c-build-tools.git
'@
    write-fixture ".gitmodules" $modules
    git -C $test_root add -- .gitmodules
    git -C $test_root update-index --add --cacheinfo "160000,$sha,deps/c-build-tools"
    git -C $test_root commit --quiet -m "test dependency gitlink"
    if ($LASTEXITCODE -ne 0) { throw "Failed to create test gitlink." }
    else { # actual HEAD gitlink, no SHA override
    }

    $workflow = @'
name: Test
description: |
  uses: Azure/c-build-tools/actions/test@description
jobs:
  reusable:
    "uses": "Azure/c-build-tools/.github/workflows/test.yml@master" # keep comment
  refs:
    steps:
      - {uses: 'Azure/c-build-tools/actions/test@v1', name: tag}
      - {uses: Azure/c-build-tools/actions/test@deadbeef}
      - uses: Azure/c-build-tools/actions/test@refs/heads/feature#1 # keep hash comment
      - uses: Azure/c-build-tools/actions/test@0000000000000000000000000000000000000000
      - uses: ./local
      - uses: actions/checkout@v4
      # uses: Azure/c-build-tools/actions/test@comment
      - run: |
          uses: Azure/c-build-tools/actions/test@script
'@
    # A multibyte character before the refs exercises byte (not character) offsets.
    $workflow = ($workflow.Replace("Test", "Test $([char]0x03A9)") -replace "\r?\n", "`r`n")
    $action = "name: Composite`nruns: {using: composite, steps: [{uses: 'Azure/c-build-tools/actions/test@main'}]}"
    $javascript = "name: JavaScript`nruns: {using: node20, main: index.js}`n"
    $pipeline = "resources: {repositories: [{repository: c_build_tools, ref: master}]}`n"
    write-fixture ".github/workflows/nested/test.yaml" $workflow
    write-fixture ".ci/actions/test/action.yml" $action
    write-fixture "javascript/action.yaml" $javascript
    write-fixture ".github/workflow-templates/action.yml" $action
    write-fixture ".github/workflow-templates/test.yml" $workflow
    write-fixture "build/test.yml" $pipeline
    [void](assert-validation 1)
    [void](assert-validation 0 -Fix)
    [void](assert-validation 0)
    $expected = $workflow
    foreach ($ref in @("master", "v1", "deadbeef", "refs/heads/feature#1", "0000000000000000000000000000000000000000"))
    {
        $expected = $expected.Replace("@$ref", "@$sha")
    }
    assert-content ".github/workflows/nested/test.yaml" $expected
    assert-content ".ci/actions/test/action.yml" $action.Replace("@main", "@$sha")
    assert-content "javascript/action.yaml" $javascript
    assert-content ".github/workflow-templates/action.yml" $action
    assert-content ".github/workflow-templates/test.yml" $workflow
    assert-content "build/test.yml" $pipeline

    foreach ($bad_modules in @("", $modules.Replace("deps/c-build-tools", "other/tools"), $modules.Replace("Azure/c-build-tools", "other/c-build-tools")))
    {
        write-fixture ".gitmodules" $bad_modules
        [void](assert-validation 1 -Fix)
        assert-content ".github/workflows/nested/test.yaml" $expected
    }
    write-fixture ".gitmodules" $modules
    git -C $test_root update-index --force-remove -- deps/c-build-tools
    git -C $test_root commit --quiet -m "remove gitlink"
    $output = assert-validation 1 -Fix
    if (-not $output.Contains(".github/workflows/nested/test.yaml:6") -or
        -not $output.Contains("has no matching deps/c-build-tools gitlink"))
    { throw "Missing file/line/ref context: $output" }
    else { # reference context retained
    }
    $blob = git -C $test_root hash-object -w -- .gitmodules
    git -C $test_root update-index --add --cacheinfo "100644,$blob,deps/c-build-tools"
    git -C $test_root commit --quiet -m "ordinary file is not a submodule"
    [void](assert-validation 1)

    write-fixture ".github/workflows/nested/test.yaml" "name: no references"
    write-fixture ".ci/actions/test/action.yml" "name: no references"
    git -C $test_root update-index --cacheinfo "160000,$sha,deps/c-build-tools"
    git -C $test_root commit --quiet -m "restore gitlink"
    [void](assert-validation 0)
    write-fixture ".gitmodules" ""
    [void](assert-validation 0)
    Write-Host "Real gitlink validation, fixes, ignored files, and missing-dependency cases passed."
}
finally
{
    if (Test-Path $test_root) { Remove-Item -LiteralPath $test_root -Recurse -Force }
    else { # no test directory to clean
    }
}
