# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Test helper: runs the c_build_tools_ref check on a real git repository (no --submodule-sha) and
# verifies GitHub Actions refs must pin the deps/c-build-tools gitlink SHA.

param(
    [Parameter(Mandatory=$true)]
    [string]$ValidatorPath
)

$ErrorActionPreference = "Stop"
$sha = "aabbccdd00112233445566778899aabbccddeeff"
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("cbt_ref_" + [guid]::NewGuid().ToString("N"))

function Invoke-Git {
    git -C $root -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false @args
    if ($LASTEXITCODE -ne 0) { throw "git $args failed" }
}

function Invoke-Validator([switch]$Fix) {
    $extra = @()
    if ($Fix) { $extra = @("--fix") }
    $output = & $ValidatorPath --repo-root $root --check c_build_tools_ref @extra 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output.Replace("\", "/") }
}

function Assert-True([bool]$Condition, [string]$Message, [string]$Details) {
    if (-not $Condition) { throw "$Message`n$Details" }
}

function Write-TestFile([string]$Path, [string]$Content) {
    $full = Join-Path $root $Path
    New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
    [System.IO.File]::WriteAllText($full, $Content)
}

$modules = "[submodule `"deps/c-build-tools`"]`n`tpath = deps/c-build-tools`n`turl = https://github.com/Azure/c-build-tools.git`n"
$files = [ordered]@{
    # CRLF workflow: a commented-out ref, an unquoted ref containing '#', and a quoted ref with a comment
    ".github/workflows/test.yml" = "jobs:`r`n  test:`r`n    steps:`r`n      # - uses: Azure/c-build-tools/actions/a@main`r`n      - uses: Azure/c-build-tools/actions/a@refs/heads/feature#1`r`n      - uses: 'Azure/c-build-tools/actions/b@v1.0' # keep`r`n"
    # Composite action in a hidden directory
    ".ci/actions/test/action.yml" = "runs:`n  using: `"composite`"`n  steps:`n    - uses: `"Azure/c-build-tools/actions/c@abc1234`"`n"
    # Not executable: non-composite action metadata and workflow templates
    "node/action.yml" = "runs:`n  using: node20`n  main: index.js`ndescription: |`n  uses: Azure/c-build-tools/actions/d@main`n"
    ".github/workflow-templates/test.yml" = "jobs:`n  test:`n    uses: Azure/c-build-tools/.github/workflows/e.yml@main`n"
}

try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Invoke-Git init -q
    Write-TestFile ".gitmodules" $modules
    foreach ($path in $files.Keys) { Write-TestFile $path $files[$path] }
    Invoke-Git update-index --add --cacheinfo "160000,$sha,deps/c-build-tools"
    Invoke-Git commit -q --no-verify -m gitlink

    $result = Invoke-Validator
    $failures = ([regex]::Matches($result.Output, "\[FAIL\]")).Count
    Assert-True ($result.Code -eq 1 -and $failures -eq 3) "Expected exactly 3 stale refs" $result.Output

    $result = Invoke-Validator -Fix
    Assert-True ($result.Code -eq 0) "Fix mode should pin every stale ref" $result.Output
    $files[".github/workflows/test.yml"] = $files[".github/workflows/test.yml"].Replace("@refs/heads/feature#1", "@$sha").Replace("@v1.0", "@$sha")
    $files[".ci/actions/test/action.yml"] = $files[".ci/actions/test/action.yml"].Replace("@abc1234", "@$sha")
    foreach ($path in $files.Keys) {
        $actual = [System.IO.File]::ReadAllText((Join-Path $root $path))
        Assert-True ($actual -ceq $files[$path]) "Unexpected content after fix in $path" $actual
    }

    $result = Invoke-Validator
    Assert-True ($result.Code -eq 0) "Refs pinned to the gitlink SHA should pass" $result.Output

    # Every ref must still be reported with file:line when the matching submodule or gitlink is missing
    $missing = [ordered]@{
        "no gitlink in HEAD" = { Invoke-Git rm -q --cached deps/c-build-tools; Invoke-Git commit -q --no-verify -m removed }
        "blob instead of gitlink" = {
            $blob = "x" | git -C $root hash-object -w --stdin
            Invoke-Git update-index --add --cacheinfo "100644,$blob,deps/c-build-tools"
            Invoke-Git commit -q --no-verify -m blob
        }
        "wrong submodule path" = { Write-TestFile ".gitmodules" $modules.Replace("path = deps/c-build-tools", "path = external/c-build-tools") }
        "wrong submodule url" = { Write-TestFile ".gitmodules" $modules.Replace("c-build-tools.git", "c-pal.git") }
        "no .gitmodules" = { Remove-Item (Join-Path $root ".gitmodules") }
    }
    foreach ($case in $missing.Keys) {
        & $missing[$case]
        foreach ($fix in $false, $true) {
            $result = Invoke-Validator -Fix:$fix
            $reported = $result.Output.Contains(".github/workflows/test.yml:5: Azure/c-build-tools/actions/a@$sha has no matching deps/c-build-tools gitlink")
            Assert-True ($result.Code -eq 1 -and $reported) "$case (fix: $fix) should report each ref" $result.Output
        }
    }
}
catch {
    Write-Host "[FAIL] $_" -ForegroundColor Red
    exit 1
}
finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host "[PASS] GitHub Actions refs are checked against the deps/c-build-tools gitlink" -ForegroundColor Green
exit 0
