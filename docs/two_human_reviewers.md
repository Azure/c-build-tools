# Two-human-reviewers gate

The gate publishes the `mrbot/two-human-reviewers` commit status. A non-exempt bot-authored
PR needs approvals on its head commit from two distinct humans with push access by default.
Human-authored PRs and exempt bots remain subject to the repository's normal review rules.
The default exemption is `dependabot[bot]`. Review aggregation and optional inputs are
described in the [composite action](../.github/actions/two-human-reviewers/README.md).

Require the **commit status** `mrbot/two-human-reviewers` in branch protection or the applicable
ruleset, with GitHub Actions as its expected source. The Actions job named `two-human-reviewers`
is not a substitute: insufficient approvals are represented by a pending status, not a failing
job. Installing a workflow does not change repository protection settings.

## Trust and dependency propagation

For a repository with `deps/c-build-tools`, the caller:

1. Reads the PR's live head and target branch through the API.
2. Publishes `pending` on that captured head before loading the gate.
3. Resolves the target **branch** through the Git refs API and reads its gitlink at that immutable
   commit. It does not use a same-named tag, the PR's gitlink, or a potentially older recorded base SHA.
4. Verifies that the gitlink commit is on the official Azure/c-build-tools master history.
5. Downloads the composite action at that exact commit, requires snapshot contract 1, and invokes
   it with the captured head and target.

There is no production checkout or execution of PR files. A dependency PR is judged using the
target branch's already-merged pointer. Subsequent evaluations use the new pointer after it merges.
The caller itself does not need a workflow SHA edit when the dependency advances.

**Keep dependency auto-approval deps-only.** Do not add a workflow-file exception to make
propagation pass. Installing or modifying the caller is a normal human-reviewed change.

## Install in repositories with the submodule

First ensure the intended target branch's `deps/c-build-tools` contains the composite action with
the standalone marker `# two-human-reviewers-snapshot-contract: 1`. An unmerged c-build-tools branch
is deliberately rejected, even if it contains the action.

Copy [the caller template](../.github/workflow-templates/two-human-reviewers.caller.yml) to
`.github/workflows/two-human-reviewers.yml`, removing the `BEGIN template-only` through
`END template-only` comment block. Submit this installation for human review.

Keep the PR-review triggers: approvals and dismissals must re-evaluate the gate. The `edited`
event also re-evaluates a PR when its base branch changes, including retargeting into master
without a new head commit. Title/body-only edits are ignored.

The workflow does not add protection to other branches. Protection is normally configured for
the repository's default branch; running an evaluation and requiring its status are separate settings.

## Compatibility path without the submodule

Repositories without `deps/c-build-tools`, or not yet migrated to the new caller, can call
`Azure/c-build-tools/.github/workflows/two-human-reviewers.yml` at a reviewed full commit SHA.
The called workflow downloads the action from that same pinned workflow commit, not from the
consumer's default branch or the current c-build-tools master tip.

For example, replace `<reviewed-full-commit-sha>` below with an actual full SHA that contains both
the action and reusable workflow:

```yaml
name: Two human reviewers
on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review, edited]
  pull_request_review:
    types: [submitted, dismissed]
  workflow_dispatch:
    inputs:
      pr:
        description: PR number to evaluate.
        type: string
        required: true
permissions:
  contents: read
  pull-requests: read
  statuses: write
jobs:
  two-human-reviewers:
    if: ${{ github.event_name != 'pull_request' || github.event.action != 'edited' || github.event.changes.base != null }}
    uses: Azure/c-build-tools/.github/workflows/two-human-reviewers.yml@<reviewed-full-commit-sha>
    with:
      pr: ${{ github.event.pull_request.number || inputs.pr }}
```

The existing `required-approvals` and `exempt-bots` workflow inputs remain available. Omitted
approval counts still default to two; a custom exemption list replaces rather than extends the default.
Updating a compatibility caller's pin still needs normal workflow-change review.

On c-build-tools' own PRs, the production workflow instead loads the action from the live target
branch's resolved commit. The action must therefore land before the workflow switch.

## Failure handling and forks

The loader resets the required status to `pending` before resolving or downloading the gate.
If loading or evaluating fails, a final step attempts to publish `error` on the same captured head.
It first rechecks the head and target and does not knowingly publish an obsolete error after a
push or retarget. The action also rechecks this pair before its verdict. Missing actions, invalid
gitlinks, failed ancestry checks, and incompatible snapshot contracts never fall back to PR code
or another gate version.

Fork PR event tokens, and Dependabot event tokens, are normally read-only. Failed status writes
are reported explicitly; a read-only event run does not claim it reset the remote status. A maintainer
must dispatch the trusted workflow after each push or relevant review:

```sh
gh workflow run two-human-reviewers.yml -R <owner>/<repo> -f pr=<number>
```

Use **Run workflow**, not a re-run of the fork's original read-only run. A manual dispatch has a
write-capable token only if the repository permits `statuses: write`.

These are not absolute fail-closed guarantees: an API outage or missing write permission can
prevent resetting an existing status, and a failure before obtaining a head SHA cannot update that
head's status. Freshness reads and status writes are not atomic. A base-branch advance alone does
not replay every open PR's previous result; dispatch affected PRs if a policy update needs immediate
re-evaluation.

## Landing and migration order

1. Merge the prerequisite PR adding the action and snapshot contract while leaving the production
   gate unchanged.
2. Revalidate and merge the workflow/template switch against master. Never bypass a gate failure
   merely to bootstrap the missing action.
3. Propagate c-build-tools normally. Before installing a consumer caller, its target branch must
   already pin a reviewed master commit containing the compatible action.
4. Install consumer callers in human-reviewed PRs. Keep non-submodule consumers on the pinned
   compatibility path.
5. Close obsolete PRs proposing workflow-file auto-approval exceptions; remove those exceptions
   in separately reviewed policy changes if already merged.

Before a broad automated rollout, update the external
`Azure-MessagingStore-AITools` deployment script `Deploy-GitHubReviewPolicy.ps1` and its operations
documentation to select the correct caller for submodule and non-submodule consumers and enforce
these prerequisites. Those repository and protection changes are separate from this implementation.

## Remaining enforcement boundary

`pull_request` workflows can include the PR's own workflow edits before merge. Fetching a trusted
gate does not make the caller itself tamper-proof, and a status tied to a head commit is not
branch-specific. Do not treat this implementation as a replacement for independently enforced
review and protected workflow ownership. Code-owner review can protect merging a workflow change,
but is not a sandbox that prevents its pre-merge execution. Stronger trusted-workflow/status-source
enforcement is separate hardening.

## Regression tests

The read-only `test-two-human-reviewers.yml` workflow runs both fixture suites on Ubuntu.
They execute the actual inline Bash against isolated fake GitHub API transport, with no inherited
credentials or live GitHub writes. Tests cover gate policy compatibility, trusted-ref selection,
status ordering and failures, snapshot changes, and workflow trigger/permission wiring.

Run them with Python, PyYAML, Bash, jq, Git, and grep available:

```sh
python3 -m unittest discover -s .github/tests -p 'test_two_human_reviewers*.py' -v
```

Logs are written under ignored `cmake/two-human-reviewers-tests`; per-case temporary directories
are removed. Older actionlint versions may not recognize the documented `job.workflow_repository`
and `job.workflow_sha` properties. That limitation does not justify ignoring other lint failures.
