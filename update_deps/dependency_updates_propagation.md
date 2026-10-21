# Dependency Updates Propagation

## Overview

`propagate_updates.ps1` builds the submodule dependency graph of one or more root repositories and
propagates updates from the lowest level up to the roots, opening one PR per repository in
bottom-up order. Each PR moves the repository's submodules to the commits merged below it and
updates the c-build-tools `ref:` in its pipeline YAML.

The script runs in one of two modes. Both use the same helper scripts (`helper_scripts/`); the
code branches on the mode only where a person at a workstation and a build agent need different
behavior:

- **Interactive** (default): an engineer runs it on Windows. It signs in with WAM or a PAT, reuses
  `known_graph.json`, follows each PR with a live watcher, and supports `-Resume` and `-AutoFix`.
- **Pipeline** (`-Pipeline`): an Azure DevOps job runs it unattended. It never prompts,
  authenticates with `SYSTEM_ACCESSTOKEN` and `GH_TOKEN`, checks access before opening any PR, and
  opens each PR as soon as its dependencies have merged.

## Folder Structure

```
update_deps/
├── propagate_updates.ps1          # Entry point for interactive and -Pipeline runs
├── ignores.json                   # Repos to exclude from updates
├── known_graph.json               # Cached dependency graph (interactive mode)
├── update_deps.ps1                # Standalone: update every submodule of the current repo
├── helper_scripts/                # One helper set shared by both modes
│   ├── load_helpers.ps1           # Dot-sources every helper in dependency order
│   ├── logging.ps1                # Mode-aware logging, secret redaction, time-bounded native calls
│   ├── preflight.ps1              # Credential and repository access checks
│   ├── pipeline_environment.ps1   # Prompt-free git and gh environment for -Pipeline
│   ├── build_graph.ps1            # Dependency graph discovery and update order
│   ├── git_operations.ps1         # Clones, mirror cache, submodule updates, commits, PR text
│   ├── azure_repo_ops.ps1         # Azure DevOps REST client and PR operations
│   ├── github_repo_ops.ps1        # GitHub PR operations
│   ├── update_repo.ps1            # Per-repo flow: sequential (interactive) or greedy (pipeline)
│   ├── status_tracking.ps1        # Status table and failure handling
│   ├── propagation_state.ps1      # -Resume state
│   ├── watch_azure_pr.ps1         # Azure PR policy watcher (interactive)
│   ├── watch_github_pr.ps1        # GitHub PR check watcher (interactive)
│   ├── pr_watch_utils.ps1         # Shared watcher display and completion logic
│   ├── autofix.ps1                # -AutoFix build-failure fixes with Copilot CLI
│   ├── check_powershell_version.ps1
│   ├── check_script_update.ps1    # Checks origin/master for a newer update_deps (interactive)
│   ├── install_az_cli.ps1         # Interactive Azure DevOps sign-in (PAT, or WAM via Azure CLI)
│   ├── install_gh_cli.ps1         # GitHub CLI installation and authentication
│   └── success_animation.ps1
└── tests/
    ├── CMakeLists.txt             # Registers the tests with CTest
    └── test_propagate_updates.ps1 # Tests for both modes; no branches or PRs are created
```

## propagate_updates.ps1

Given root repositories, this script builds the dependency graph and propagates updates from the
lowest level up to the roots by making a PR to each repo in bottom-up order.

### Usage

```powershell
# Using WAM authentication (recommended on Windows)
.\propagate_updates.ps1 -azure_work_item {work_item_id} -root_list {root1}, {root2}, ...

# Using PAT token authentication
.\propagate_updates.ps1 -azure_token {your_pat_token} -azure_work_item {work_item_id} -root_list {root1}, {root2}, ...

# Force a full graph rebuild (ignores known_graph.json)
.\propagate_updates.ps1 -azure_work_item {work_item_id} -ForceBuildGraph -root_list {root1}, {root2}, ...

# Resume the most recent interactive run from the repo that failed
.\propagate_updates.ps1 -Resume

# Noninteractive Azure DevOps pipeline mode
.\propagate_updates.ps1 -Pipeline -azure_work_item {work_item_id} -NoCloseFailedPr -root_list {root1}, {root2}, ...
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `-root_list` | Yes, except with `-Resume` | Comma-separated list of URLs of the repositories up to which updates must be propagated |
| `-azure_work_item` | Yes, except with `-Resume` | Work item ID to link to PRs made to Azure repos |
| `-azure_token` | No | Interactive only. Personal access token for Azure DevOps. Without it, `AZURE_DEVOPS_EXT_PAT` is used when set, otherwise WAM (Web Account Manager) |
| `-poll_interval` | No | Seconds between PR status polls (default: 15; `-Pipeline` polls at most every 30 seconds) |
| `-ForceBuildGraph` | No | Interactive only. Rebuild the graph even if `known_graph.json` matches |
| `-NoCloseFailedPr` | No | Keep the PR open if it fails (default: close/abandon failed PRs) |
| `-Resume` | No | Interactive only. Resume the most recent run from the repo that failed |
| `-AutoFix` | No | Interactive only. Use Copilot CLI to attempt build-failure fixes |
| `-Pipeline` | No | Run noninteractively on an Azure DevOps agent (see [Pipeline mode](#pipeline-mode)) |

The script exits with 0 when every repository was updated or had nothing to update, and with a
non-zero code otherwise.

### Modes

| | Interactive (default) | Pipeline (`-Pipeline`) |
|---|---|---|
| Azure DevOps authentication | WAM token from the Azure CLI, or a PAT (`-azure_token` or `AZURE_DEVOPS_EXT_PAT`) | `SYSTEM_ACCESSTOKEN` |
| GitHub authentication | Existing `gh` sign-in; runs `gh auth login` if needed | `GH_TOKEN` |
| Prompts | Sign-in, the Ctrl+C cancel menu, and `-AutoFix` | Never |
| Dependency graph | `known_graph.json` when the roots' submodules still match it; otherwise discovered live, saved, and proposed in a c-build-tools PR | Always discovered live; `known_graph.json` is neither read nor written |
| Order | One repository at a time in level order, following each PR with a live watcher | Each repository's PR opens as soon as everything it depends on has merged; all open PRs are polled together |
| Failure | State is saved for `-Resume`; `-AutoFix` can attempt a fix | The run fails with a status table |
| PR title prefix | `[autogenerated]` | `[no begging] [autogenerated]` |
| Logs | Colored console output | Timestamped lines with `##[error]`, `##[warning]` and `##[section]` markers |

### Shared behavior

- **Azure DevOps through REST.** Both modes call the Azure DevOps REST API directly; the Azure CLI
  is used only to obtain a WAM token. Every request has a timeout. Reads are retried on
  throttling, server errors and dropped connections; writes are retried only when the service
  reports that it did not process them (HTTP 429/503). A rejected WAM token is refreshed once.
- **Git mirror cache.** Each repository is mirrored once per run into `_gitmirrors` in the work
  directory, and clones and submodule updates take objects from the mirror instead of downloading
  the same dependency for every parent. Network git commands are retried and abort on stalled
  transfers.
- **Commits.** Only the submodule paths and `build/` (the c-build-tools `ref:` updates) are staged.
- **PR descriptions.** The per-commit description is used when it fits the service limit (4000
  characters on Azure DevOps); otherwise a per-repository summary is used.
- **PR completion.** Azure DevOps PRs are linked to the work item, approved, and set to
  auto-complete with squash merge. GitHub PRs get squash auto-merge and a `/AzurePipelines run`
  comment. An existing work item link, or an active PR that already exists for the branch, is
  reused.
- **Secrets.** Known tokens are redacted from logged text.

## Pipeline mode

`-Pipeline` is designed for Azure DevOps agents. It:

- never launches WAM, credential-manager, Azure CLI, GitHub CLI, or git prompts;
- uses `SYSTEM_ACCESSTOKEN` for Azure DevOps REST and git authentication;
- uses `GH_TOKEN` for GitHub API, PR, merge, and git authentication;
- before creating any PR, validates both identities, read access to the Azure DevOps roots, and
  write access to every GitHub repository in the graph;
- gives every native command a wall-clock timeout;
- supports `-azure_work_item`, `-root_list`, `-poll_interval`, and `-NoCloseFailedPr`.

Pipeline mode rejects the interactive-only `-azure_token`, `-Resume`, `-AutoFix`, and
`-ForceBuildGraph` arguments.

### Environment contract

| Variable | Required | Description |
|----------|----------|-------------|
| `SYSTEM_ACCESSTOKEN` | Yes | Map from `$(System.AccessToken)`. The build identity needs repository read/write, PR contribution, and work-item linking permissions in each Azure DevOps target |
| `GH_TOKEN` | Yes | GitHub token with write access to every GitHub repository in the discovered graph; for the Azure organization it must also be SAML SSO-authorized |
| `AGENT_TEMPDIRECTORY` | No | Used for the isolated git configuration and a downloaded pinned GitHub CLI when available |

The script sets `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`, `GH_PROMPT_DISABLED=1`, and git
low-speed limits itself. Git's global configuration goes to a temporary file unless the caller
already set `GIT_CONFIG_GLOBAL`, and a commit identity is configured only when none exists. The
Azure DevOps bearer token reaches git through `GIT_CONFIG_PARAMETERS` entries appended after any
the caller set, so it is never written to a git config file. These entries replace an Azure DevOps
`http.<url>.extraheader` the caller already configured (for example in its `GIT_CONFIG_GLOBAL`
file), so git sends a single `Authorization` header. These settings are undone when the run ends.

### Azure DevOps YAML example

```yaml
- task: PowerShell@2
  displayName: Propagate dependency updates
  timeoutInMinutes: 0
  inputs:
    targetType: inline
    script: |
      $script = Join-Path $env:BUILD_SOURCESDIRECTORY 'deps\c-build-tools\update_deps\propagate_updates.ps1'
      & $script `
          -Pipeline `
          -azure_work_item '${{ parameters.workItemId }}' `
          -root_list 'https://msazure.visualstudio.com/One/_git/RootRepo' `
          -NoCloseFailedPr
      exit $LASTEXITCODE
  env:
    SYSTEM_ACCESSTOKEN: $(System.AccessToken)
    GH_TOKEN: $(ghToken)
```

The job and task timeout must allow for human-gated PRs to merge. On self-hosted agents,
`timeoutInMinutes: 0` is appropriate when the propagation is expected to wait for approvals.

### Migration from a vendored pipeline copy

Replace a repository-local invocation such as:

```powershell
$script = Join-Path $env:BUILD_SOURCESDIRECTORY 'scripts\update_deps\propagate_updates.ps1'
& $script -azure_work_item $workItemId -root_list $roots -NoCloseFailedPr
```

with the c-build-tools entry point:

```powershell
$script = Join-Path $env:BUILD_SOURCESDIRECTORY 'deps\c-build-tools\update_deps\propagate_updates.ps1'
& $script -Pipeline -azure_work_item $workItemId -root_list $roots -NoCloseFailedPr
```

For branch validation, point the pipeline's c-build-tools checkout/submodule to the PR branch
being tested; the invocation and environment contract remain the same.

## Tests

`tests/test_propagate_updates.ps1` covers both modes without creating branches or PRs: remote
services are mocked and git runs against local repositories in a temporary directory. It checks
parsing, that both modes share one helper set, command and parameter references, argument
handling, logging and redaction, timeouts, Azure DevOps authentication and retries, the pipeline git
environment, update order, PR descriptions and polling, and a local end-to-end `update-local-repo`
in each mode.

```powershell
# Windows PowerShell 5.1 (the -Pipeline runtime) and PowerShell 7
powershell -NoProfile -ExecutionPolicy Bypass -File .\update_deps\tests\test_propagate_updates.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\update_deps\tests\test_propagate_updates.ps1
```

With `-Drun_unittests=ON`, CMake registers them as the `update_deps_propagation_test` (Windows
PowerShell) and `update_deps_propagation_pwsh_test` (PowerShell 7, when installed) CTest tests.

## build_graph.ps1

`helper_scripts/build_graph.ps1` discovers the dependency graph and the update order. It is a
function library loaded by `load_helpers.ps1`:

```powershell
. .\helper_scripts\load_helpers.ps1
$graph = build-dependency-graph -root_list {root1}, {root2}, ...
$graph.repo_order
```

`build-dependency-graph` returns the update order (deepest dependencies first), each repository's
URL, and its direct dependencies. As in an interactive run, it reuses `known_graph.json` when it
still matches, and otherwise saves the discovered graph and opens a c-build-tools PR with it.
`-NoKnownGraph` always discovers the graph without reading or writing `known_graph.json`.

## Prerequisites

### Automatic Setup

Interactive runs handle most setup tasks:

- **Azure DevOps authentication**: Uses a PAT from `-azure_token` or `AZURE_DEVOPS_EXT_PAT` when provided; otherwise signs in with WAM (Web Account Manager) through the Azure CLI
- **Azure CLI**: Automatically installed if not present and WAM is used (Windows only)
- **GitHub CLI**: Automatically installed if not present (Windows only)
- **GitHub authentication**: Prompts for `gh auth login` if not already authenticated

Pipeline runs never install or sign in interactively: they use `gh` from `PATH` or download a
pinned release, and authenticate from the [environment](#environment-contract).

### Manual Setup (if automatic installation fails)

#### Azure CLI

Needed only for WAM authentication; the Azure DevOps CLI extension is not used.

1. Download and install the Azure CLI from [here](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli).

2. Sign in (the script also prompts if needed):
   ```powershell
   az login
   ```

#### GitHub CLI

1. Download the latest version of GitHub CLI from [here](https://cli.github.com/) and install it.

2. Authenticate with GitHub CLI (the script will prompt you if needed):
   ```powershell
   gh auth login
   ```
   Follow the prompts:
   - `What account do you want to log into?` : Select `GitHub.com`
   - `What is your preferred protocol for Git operations?` : Select `HTTPS`
   - `Authenticate Git with your GitHub credentials?` : Enter `Y`
   - `How would you like to authenticate GitHub CLI?` : Select `Login with a web browser`
   - Select the `Azure` organization on the authentication page.

### Azure DevOps PAT Token (Optional)

If WAM authentication doesn't work in your environment, you can use a Personal Access Token instead:

1. Go to `https://msazure.visualstudio.com/` and sign in.

2. Click on the person icon with the gear in the top right corner and select `Personal access tokens` from the menu:

![azure_pat](images/azure_pat.jpg)

3. Click on `+ New Token`. Give your token a name. Give the token `Read, write, & manage` permission for `Work Items` and `Full` permissions for `Code`. Optionally add `Read` for `Build` so the PR watcher can show build job details and `-AutoFix` can read build logs:

![azure_token](images/azure_token.jpg)

4. Click `Create` at the bottom.

5. Copy the generated token and pass it using `-azure_token {your_token}`, or set it in the `AZURE_DEVOPS_EXT_PAT` environment variable.

## Configuration

### ignores.json

`ignores.json` contains a list of repository names that should be ignored while building the dependency graph and should not be updated.

Example:
```json
[
    "repo-to-ignore-1",
    "repo-to-ignore-2"
]
```

## Pipeline YAML Ref Updates

### Background

Each consuming repo references c-build-tools pipeline templates via `resources.repositories` with a pinned `ref:` SHA:

```yaml
resources:
  repositories:
  - repository: c_build_tools
    type: github
    name: azure/c-build-tools
    endpoint: github.com_azure
    ref: a479dd2fd437d3a0adf2010b22d2c944ea8e6047
```

When propagating updates, the script updates both the `deps/c-build-tools` submodule pointer AND the `ref:` SHA in `build/*.yml` pipeline files so they stay in sync.

### Azure DevOps Limitation: ref must be inline

The `ref:` field in `resources.repositories` only supports [template expressions](https://learn.microsoft.com/en-us/azure/devops/release-notes/2022/sprint-212-update#template-expressions-in-repository-resource-definition) (`${{ }}`) with **parameters** and **system predefined variables**. It does **not** support YAML-defined variables, including those loaded from variable template files.

We attempted to externalize the SHA into a separate file (`deps/c_build_tools_ref.yml`) and reference it via `${{ variables.c_build_tools_ref }}`, but the value silently fell back to the default branch (`master`) at compile time.

Per the Sprint 212 release notes:
> "you can use `parameters` and system predefined variables, but you **cannot use YAML or Pipelines UI-defined variables**"

A feature request has been filed to support variable template values in `ref:`: https://dev.azure.com/mseng/AzureDevOps/_workitems/edit/2371096

### Impact on Auto-Approve

Because the SHA must be hardcoded inline in `build/*.yml`, propagation PRs touch both `deps/` files and pipeline YAML files.

**GitHub repos**: Auto-approve policies use `titleContains: [autogenerated]` combined with `filesMatchPattern` to auto-approve these PRs without manual review.

**ADO repos**: ADO branch policies do not support title-based conditions. The "Required reviewers" policy uses file path patterns, but cannot conditionally approve based on PR metadata. As a result, **propagation PRs to ADO repos that include pipeline YAML changes will require sign-off from another team member**.
