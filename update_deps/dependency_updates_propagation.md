# Dependency Updates Propagation

## Overview

This toolset builds dependency graphs and propagates updates from the lowest level up to root repositories by making PRs to each repo, bottom-up. A repo's PR is opened as soon as every repo it depends on has been propagated (its PR merged, or it had no changes), so independent dependency chains are reviewed and merged in parallel instead of waiting for each other.

## Running via the Pipeline

The supported way to run a propagation is the `aa_propagate_submodules` pipeline
(definition 464812: https://msazure.visualstudio.com/One/_build?definitionId=464812),
defined by Azure-MessagingStore's [`build/propagate_deps.yml`](https://msazure.visualstudio.com/One/_git/Azure-MessagingStore?path=/build/propagate_deps.yml). It runs
`propagate_updates.ps1` as the build service account so the resulting PRs are
bot-authored. A bot-authored PR lets any developer act as a valid non-contributor
approver, so a single Approve plus the script's armed auto-complete merges each PR.
GitHub repos in the chain are merged by the Microsoft GitHub Policy Service. The
build service identity needs **Contribute to pull requests** on each target Azure
repo.

### How to queue a run

1. Open the pipeline and click **Run pipeline** (run it from `master`, the default).
2. Provide `workItemId` and the `ghToken` secret variable (see Inputs below).
3. The run blocks while it waits for the required human approvals, advancing up the
   dependency chain as PRs merge. Cancel the run manually to abort.

### Inputs

| Input | Kind | Description |
|-------|------|-------------|
| `workItemId` | Parameter (required) | Id of any tracked work item in the One project, linked to every PR to satisfy the linked-work-items policy. Entered in the Run pipeline dialog. |
| `ghToken` | Secret variable, settable at queue time | GitHub token for the script's `gh` calls and pushes to github.com. It is a secret variable (not a parameter) because parameters are not masked in logs. Needs `repo` (write) scope and `Azure` org SSO authorization, exactly like `GH_TOKEN` in [Authentication](#github-gh_token). Add it under Pipeline -> Edit -> Variables as `ghToken`, marked secret and settable at queue time. Verify before queueing: `gh api repos/Azure/macro-utils-c --jq .permissions.push` should print `true`. |

Azure DevOps auth (git and REST) uses the job's `System.AccessToken`, so no
`SYSTEM_ACCESSTOKEN` setup is needed when running in the pipeline. The `gh` CLI is
installed by the script if the agent does not already have it.

### What the YAML fixes (edit the file to change)

- **Roots**: `root_list` is hardcoded to `Azure-Messaging-ElasticLog` and
  `Azure-Messaging-GeoReplication`. Change it in `build/propagate_deps.yml` (or run
  the script directly, see below) to target a different set of roots.
- **Pool**: `Azure-MessagingStore-WinBuildPoolVS2022_1`.
- **`-NoCloseFailedPr`**: failed PRs stay open so a later approval can still merge
  them even if the run was cancelled first.
- **No timeout**: the job sets `timeoutInMinutes: 0`; the default 60-minute job
  timeout would otherwise cancel the run mid human-gated wait, so it is disabled to
  let the run block for hours across sequential approvals.
- **No waiting on prompts or dead connections**: git, Git Credential Manager and `gh`
  are told never to prompt (nobody could answer), and git aborts any transfer that
  moves less than 1 byte/s for 1 minute instead of waiting on it forever.

To run with a custom root list, a different account, or interactively, invoke
`propagate_updates.ps1` directly as described below.

### Monitoring a run

While PRs are open, the log shows a status table after every poll round (about every 30
seconds; longer while requests are being retried):

```
--- Propagation Status (2026-09-30 06:31:53) ---
Repos: 14 of 18 done (12 updated, 2 skipped), 1 in progress, 3 not started, 0 failed
   #   REPOSITORY                     STATUS      PR
-  1.  azure-messaging-ai-context     SKIPPED
+  3.  Azure-MessagingStore-AITools   UPDATED     https://dev.azure.com/msazure/One/_git/Azure-MessagingStore-AITools/pullrequest/17339084
...
+  14. Azure-Messaging-Metrics        UPDATED     https://dev.azure.com/msazure/One/_git/Azure-Messaging-Metrics/pullrequest/17339074
*  15. zrpc                           IN PROGRESS https://dev.azure.com/msazure/One/_git/zrpc/pullrequest/17339125
       waiting on 2 of 12 gates: 1 running, 1 awaiting action [Required reviewers]; 10 done
.  16. Azure-Messaging-GeoReplication PENDING
       waiting for zrpc
.  17. Azure-MessagingStore           PENDING
       waiting for zrpc
.  18. Azure-Messaging-ElasticLog     PENDING
       waiting for zrpc, Azure-MessagingStore
```

The line under each open PR counts its gates: for an Azure DevOps PR, its blocking
branch policies (builds, reviewer requirements, status checks, ...); for a GitHub PR,
its checks plus the review requirement. A gate is done, running, not started, awaiting
action (usually a human approval), or failed; gates awaiting action or failed are named.
Anything else that keeps the PR from merging is appended, such as
`merge status: conflicts` or `auto-complete not set`. The line under a repo that has not
started yet names the dependencies it is still waiting for.

Requests that stop responding fail instead of stalling the run: Azure DevOps REST calls
time out after 60 seconds (300 for writes), `gh` calls after 120 seconds, and the git
fetches and pulls the script depends on after 10 minutes per attempt. A failed poll is
retried on the next one, so the log keeps moving. If no new log line appears for more than
15 minutes, the run is stuck: cancel it and, once the PRs it already opened have merged
(they are armed to merge on their own), queue a new run; repos that are already up to date
are skipped.

## Folder Structure

```
update_deps/
|-- propagate_updates.ps1      # Main orchestration script
|-- ignores.json               # Repos to exclude from updates
|-- helper_scripts/
|   |-- build_graph.ps1        # Discovers the dependency graph (BFS) and a bottom-up order
|   |-- update_repo.ps1        # Greedy scheduling: create/poll PRs as dependencies merge
|   |-- status_tracking.ps1    # Progress display functions
|   |-- git_operations.ps1     # Local git operations + mirror cache
|   |-- azure_repo_ops.ps1     # Azure DevOps PR operations (REST)
|   |-- github_repo_ops.ps1    # GitHub PR operations (gh)
|   |-- logging.ps1            # Structured logging, secret redaction, time-bounded native calls
|   |-- preflight.ps1          # GitHub/ADO self-test before any work
|   |-- check_powershell_version.ps1
|   `-- install_gh_cli.ps1     # Ensures gh is installed + authenticated
```

## propagate_updates.ps1

Given root repos, this script builds the dependency graph and propagates updates from the lowest level up to the roots. It opens a repo's PR as soon as all of that repo's dependencies have been propagated, polls all open PRs together, and on each merge advances that repo's pinned commit before starting whatever depends on it. For example, `Azure-Messaging-GeoReplication` does not depend on `Azure-MessagingStore`, so both are updated in parallel, while `Azure-Messaging-ElasticLog` waits for `Azure-MessagingStore`.

### Usage

```powershell
# Authentication comes from the environment (the pipeline sets these); see Authentication below.
$env:GH_TOKEN = "<github token>"          # gh PRs + git pushes to github.com
$env:SYSTEM_ACCESSTOKEN = "<ado token>"   # Azure DevOps REST + git

.\propagate_updates.ps1 -azure_work_item {work_item_id} -root_list {root1},{root2},...
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `-root_list` | Yes | Comma-separated list of URLs of the repositories up to which updates must be propagated |
| `-azure_work_item` | Yes | Work item ID to link to PRs made to Azure repos |
| `-poll_interval` | No | Seconds between status polls while waiting for a PR to merge (default: 15) |
| `-NoCloseFailedPr` | No | Keep the PR open if it fails (default: close/abandon failed PRs) |

## build_graph.ps1

This script takes a list of repository URLs and builds the dependency graph. It records each repo's direct dependencies (used to start a repo as soon as they are done) and orders the repos bottom-up by the length of the longest dependency chain below each one, which is roughly the order in which they can start. A dependency cycle fails the run.

### Usage

```powershell
.\helper_scripts\build_graph.ps1 -root_list {root1}, {root2}, ...
```

## Local git object cache

The same dependency (for example `c-build-tools`, `c-pal`, `c-util`) is a submodule of many repos, so a naive run would clone it once per parent. To avoid that, `git_operations.ps1` mirrors each unique repository once into a per-run `_gitmirrors` cache and then clones it (both at top level and as a submodule) with git alternates pointing at that mirror. Objects are shared from local disk instead of being fetched again, while full history is preserved so PR-description log reads and fixed-commit checkouts still work. The cache lives under the run's work directory and is discarded with it.

## Authentication

Authentication is provided through the environment (the pipeline sets these), not script parameters.

### GitHub (`GH_TOKEN`)

Used by `gh` for pull requests and by git for pushes to github.com. The propagation opens PRs on the
upstream `Azure/*` GitHub repos (`c-build-tools`, `macro-utils-c`, `c-pal`, ...), so the token must
have `repo` (write) scope AND be SSO-authorized for the `Azure` organization, which enforces SAML
SSO. A token that lacks this returns HTTP 403 ("Resource protected by organization SAML enforcement")
on push/PR. Create a PAT at https://github.com/settings/tokens, then click `Configure SSO` next to it
and authorize the `Azure` org. The preflight self-test validates this before any work: it runs
`gh api repos/<owner>/<repo> --jq .permissions.push` for every GitHub repo in the dependency graph and
fails fast with guidance if any is not writable/authorized (verify yourself: the command should print
`true`).

### Azure DevOps (`SYSTEM_ACCESSTOKEN`)

Azure DevOps PR operations call the REST API directly (no `az` CLI) and git authenticates via an http
extraheader, both using the build account OAuth token in `SYSTEM_ACCESSTOKEN`. The job token stays
valid for the lifetime of the job, so a single run can wait through hours of human approvals without
the token expiring.

## Prerequisites

- **GitHub CLI (`gh`)**: used for pull requests. The propagation script uses it if already installed
  and otherwise downloads a pinned release automatically (the build agent has no winget), so no manual
  install is needed.
- **Git**: required for cloning and submodule operations.
- No Azure CLI is required: all Azure DevOps operations use the REST API directly.

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

Externalizing the SHA into a separate file (`deps/c_build_tools_ref.yml`) and referencing it via `${{ variables.c_build_tools_ref }}` does not work: the value silently falls back to the default branch (`master`) at compile time.

Per the Sprint 212 release notes:
> "you can use `parameters` and system predefined variables, but you **cannot use YAML or Pipelines UI-defined variables**"

A feature request has been filed to support variable template values in `ref:`: https://dev.azure.com/mseng/AzureDevOps/_workitems/edit/2371096

### Impact on Auto-Approve

Because the SHA must be hardcoded inline in `build/*.yml`, propagation PRs touch both `deps/` files and pipeline YAML files.

**GitHub repos**: Auto-approve policies use `titleContains: [autogenerated]` combined with `filesMatchPattern` to auto-approve these PRs without manual review.

**ADO repos**: ADO branch policies do not support title-based conditions. The "Required reviewers" policy uses file path patterns, but cannot conditionally approve based on PR metadata. As a result, **propagation PRs to ADO repos that include pipeline YAML changes will require sign-off from another team member**.
