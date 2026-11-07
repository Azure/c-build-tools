#Copyright (c) Microsoft. All rights reserved.
#Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Requires Git Bash and jq on PATH. From the repository root:
# pwsh -NoProfile -ExecutionPolicy Bypass -Command ".\.github\actions\two-human-reviewers\test-snapshot.ps1"
param([string]$Bash = 'bash')

$ErrorActionPreference = 'Stop'
$bashPath = (Get-Command $Bash -ErrorAction Stop).Source
$jqDirectory = & $bashPath --noprofile --norc -c 'jq_path=$(command -v jq) || exit 1; cygpath -w "${jq_path%/*}"'
if ($LASTEXITCODE -ne 0) { throw 'jq must be available in Git Bash' }
$repoRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$action = [IO.File]::ReadAllText("$PSScriptRoot\action.yml").Replace("`r`n", "`n")

# Deliberately check this action's wiring, not a YAML or GitHub expression interpreter.
$wiring = @'
        GH_TOKEN: ${{ github.token }}
        REPO: ${{ github.repository }}
        PR: ${{ inputs.pr }}
        EXPECTED_HEAD: ${{ inputs.expected-head }}
        EXPECTED_TARGET: ${{ inputs.expected-target }}
        EXEMPT_BOTS: ${{ inputs.exempt-bots || 'dependabot[bot]' }}
        REQUIRED_APPROVALS: ${{ fromJSON(inputs.required-approvals || '0') || 2 }}
        STATUS_CONTEXT: mrbot/two-human-reviewers
        RUN_URL: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}
'@
foreach ($line in ($wiring.Replace("`r`n", "`n") -split "`n")) {
    if (($action -split "`n") -cnotcontains $line) { throw "Missing env wiring: $line" }
}
foreach ($inputName in @('expected-head', 'expected-target')) {
    if ($action -cnotmatch "(?m)^  ${inputName}:\n    description: [^\n]+\n    required: false$") {
        throw "Expected optional input: $inputName"
    }
}
if ($action -cnotmatch '(?m)^# two-human-reviewers-snapshot-contract: 1$') {
    throw 'Missing snapshot contract marker'
}
$block = [regex]::Match($action, '(?m)^      run: \|\n(?<body>(?: {8}[^\n]*\n|\n)*)\z')
if (-not $block.Success) { throw 'Expected the final inline Bash block at eight-space indentation' }
$body = [regex]::Replace($block.Groups['body'].Value, '(?m)^ {8}', '')
$work = Join-Path $repoRoot ("cmake\reviewer-snapshot-tests-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
[IO.File]::WriteAllText("$work\action.sh", $body)

$mock = @'
cd -- "$FIXTURE_CASE" || exit 99
gh() {
  case "$*" in
    "api repos/fixture/repo/pulls/7")
      printf '.\n' >> reads
      local count head="$FIXTURE_HEAD" target=master base="$FIXTURE_HEAD"
      count=$(wc -l < reads)
      case "$SCENARIO:$count" in
        initial-head:1|late-head:2) head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
        initial-target:1|late-target:2) target=release ;;
        late-api:2) echo "fixture freshness API failure" >&2; return 73 ;;
        advance-base:2) base=cccccccccccccccccccccccccccccccccccccccc ;;
      esac
      jq -nc --arg head "$head" --arg target "$target" --arg base "$base" --arg kind "$AUTHOR_TYPE" '
        {number:7, state:"open", head:{sha:$head}, base:{ref:$target, sha:$base},
         user:{type:$kind, login:(if $kind == "Bot" then "fixture[bot]" else "fixture-human" end)}}'
      ;;
    "api --paginate repos/fixture/repo/commits/$FIXTURE_HEAD/pulls --jq .[]")
      : > evaluated
      ;;
    "api graphql --paginate "*)
      jq -nc --arg head "$FIXTURE_HEAD" --argjson count "$APPROVALS" '
        range(1; $count + 1) | {databaseId:., state:"APPROVED", authorCanPushToRepository:true,
          author:{login:("human" + tostring), __typename:"User"}, commit:{oid:$head}}'
      ;;
    "api --method POST repos/fixture/repo/statuses/"*)
      printf '%s\n' "$*" >> posts
      ;;
    *)
      printf 'Unexpected gh call: %s\n' "$*" >> unexpected
      return 99
      ;;
  esac
}
'@
[IO.File]::WriteAllText("$work\fixture.sh", $mock.Replace("`r`n", "`n") + "`n" + $body)

# Name, supplied inputs, API change, author type, approvals, verdict/error, PR reads.
$cases = @(
    @('legacy-human',             'none',   'stable',         'User', 0, 'success',  1),
    @('legacy-approved',          'none',   'late-head',      'Bot',  2, 'success',  1),
    @('legacy-pending',           'none',   'late-target',    'Bot',  0, 'pending',  1),
    @('snapshot-human',           'pair',   'stable',         'User', 0, 'success',  2),
    @('snapshot-approved',        'pair',   'stable',         'Bot',  2, 'success',  2),
    @('snapshot-pending',         'pair',   'stable',         'Bot',  0, 'pending',  2),
    @('head-only',                'head',   'stable',         'Bot',  0, 'inputs',   0),
    @('target-only',              'target', 'stable',         'Bot',  0, 'inputs',   0),
    @('initial-head',             'pair',   'initial-head',   'Bot',  2, 'mismatch', 1),
    @('initial-target',           'pair',   'initial-target', 'Bot',  0, 'mismatch', 1),
    @('late-head-human',          'pair',   'late-head',      'User', 0, 'mismatch', 2),
    @('late-target-human',        'pair',   'late-target',    'User', 0, 'mismatch', 2),
    @('late-head-approved',       'pair',   'late-head',      'Bot',  2, 'mismatch', 2),
    @('late-target-approved',     'pair',   'late-target',    'Bot',  2, 'mismatch', 2),
    @('late-head-pending',        'pair',   'late-head',      'Bot',  0, 'mismatch', 2),
    @('late-target-pending',      'pair',   'late-target',    'Bot',  0, 'mismatch', 2),
    @('freshness-error-human',    'pair',   'late-api',        'User', 0, 'api',      2),
    @('freshness-error-approved', 'pair',   'late-api',        'Bot',  2, 'api',      2),
    @('freshness-error-pending',  'pair',   'late-api',        'Bot',  0, 'api',      2),
    @('advanced-target-sha',      'pair',   'advance-base',    'Bot',  2, 'success',  2)
)
$head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
foreach ($case in $cases) {
    $name, $inputs, $scenario, $author, $approvals, $verdict, $expectedReads = $case
    $caseDir = Join-Path $work $name
    [void][IO.Directory]::CreateDirectory($caseDir)
    $start = [Diagnostics.ProcessStartInfo]::new($bashPath)
    $start.WorkingDirectory = $work
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in @('--noprofile', '--norc', 'fixture.sh')) { $start.ArgumentList.Add($arg) }
    # No inherited tokens, shell startup scripts, or gh configuration; gh above has no real-CLI fallback.
    $start.Environment.Clear()
    $environment = @{
        PATH = "$jqDirectory;$env:PATH"
        SystemRoot = $env:SystemRoot
        HOME = $caseDir
        GH_CONFIG_DIR = $caseDir
        TMPDIR = '.'
        GH_TOKEN = 'fixture-token-not-a-credential'
        REPO = 'fixture/repo'
        PR = '7'
        EXPECTED_HEAD = $(if ($inputs -in @('pair', 'head')) { $head } else { '' })
        EXPECTED_TARGET = $(if ($inputs -in @('pair', 'target')) { 'master' } else { '' })
        EXEMPT_BOTS = 'dependabot[bot]'
        REQUIRED_APPROVALS = '2'
        STATUS_CONTEXT = 'mrbot/two-human-reviewers'
        RUN_URL = 'https://example.invalid/runs/1'
        FIXTURE_HEAD = $head
        FIXTURE_CASE = $name
        SCENARIO = $scenario
        AUTHOR_TYPE = $author
        APPROVALS = [string]$approvals
    }
    foreach ($entry in $environment.GetEnumerator()) { $start.Environment[$entry.Key] = $entry.Value }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        $process.Kill($true)
        throw "$name timed out"
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText("$caseDir\output.log", $output)
    $exitCode = $process.ExitCode
    $process.Dispose()
    $reads = if (Test-Path "$caseDir\reads") { @(Get-Content "$caseDir\reads").Count } else { 0 }
    $posts = @(if (Test-Path "$caseDir\posts") { Get-Content "$caseDir\posts" })
    if ($reads -ne $expectedReads -or (Test-Path "$caseDir\unexpected")) {
        throw "$name made unexpected API calls; see $caseDir"
    }
    if ($verdict -in @('success', 'pending')) {
        if ($exitCode -ne 0 -or $posts.Count -ne 1 -or
            -not $posts[0].StartsWith("api --method POST repos/fixture/repo/statuses/$head -f state=$verdict -f context=mrbot/two-human-reviewers ")) {
            throw "$name did not publish $verdict on the original head; see $caseDir"
        }
    } else {
        $diagnostic = @{
            inputs = 'must be supplied together'
            mismatch = 'does not match expected-head and expected-target'
            api = 'fixture freshness API failure'
        }[$verdict]
        if ($exitCode -eq 0 -or $posts.Count -ne 0 -or -not $output.Contains($diagnostic) -or
            ($expectedReads -le 1 -and (Test-Path "$caseDir\evaluated"))) {
            throw "$name did not fail closed before evaluation/publication; see $caseDir"
        }
    }
    Write-Output "PASS $name"
}
Write-Output "Passed $($cases.Count) snapshot cases. Outputs: $work"
