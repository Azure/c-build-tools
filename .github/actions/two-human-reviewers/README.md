# Two human reviewers action

This composite action publishes `mrbot/two-human-reviewers` on a pull request's head
commit. Fetch it only from a trusted ref, never from the pull request being judged.
It requires Bash, `gh`, and `jq`; the workflow token needs `contents: read`,
`pull-requests: read`, and `statuses: write`.

The gate requires two distinct, push-capable human approvals of the current head
when any open PR sharing that head is authored by a non-exempt bot. It pools
reviews across those PRs and uses each human's latest approval, change request,
or dismissal. Comments and pending reviews do not change a verdict. By default,
`dependabot[bot]` is exempt. Human-only and exempt-only heads pass.

| Input | Meaning |
| --- | --- |
| `pr` | Required PR number, including for manual dispatch. |
| `required-approvals` | Positive integer; omitted or empty means `2`. |
| `exempt-bots` | Comma-separated logins, with surrounding whitespace ignored. Omitted or empty means `dependabot[bot]`; a nonempty value replaces that default. |
| `expected-head` | Optional exact PR head SHA captured by the loader. |
| `expected-target` | Optional exact target branch name (`base.ref`, not `base.sha` or `refs/heads/...`). |

Status publication remains best effort: a read-only fork token produces a warning,
not a job failure. A maintainer must dispatch the workflow with a write-capable
token and the PR number after each push or review; re-running the fork's original
run does not grant write access. API failures during evaluation fail the action
without publishing a verdict.

## Snapshot contract version 1

The exact standalone marker in `action.yml` is:

```text
# two-human-reviewers-snapshot-contract: 1
```

A snapshot-aware loader must require this marker **before executing** the fetched
action. Older actions may silently ignore unknown inputs and must be rejected.
The loader should capture the PR head and target, initialize `pending` on that
head before fetching the trusted action, and pass both snapshot inputs.

When either snapshot input is nonempty:

- The initial PR read must match every supplied value. The omitted member, if
  any, is captured from that read.
- Immediately before every status POST, the action reads the PR again and
  requires both head and target to match that snapshot.
- A mismatch exits nonzero with an error and makes no status POST. A failed
  freshness read also fails without posting. Existing statuses are left unchanged;
  no verdict is redirected to a newer head.

When both inputs are omitted or empty, the action retains the legacy behavior:
it evaluates the live PR from its initial API read without a final freshness read.
Target-branch advancement without a retarget is not a mismatch. The final read and
status POST are not atomic; GitHub's status API has no compare-and-set operation.
A loader's failure handler must independently revalidate its captured head and
target before writing a status.

## Fixture tests

Run `python .github/tests/test_two_human_reviewers.py` with Bash, `jq`, and the
Python dependencies in `.github/tests/requirements.txt` available. On Windows,
use Git Bash rather than WSL's `bash.exe`. The harness loads the action's actual
inline Bash blocks and environment expressions, replacing only `gh` with fixture
API responses. It uses no real token or GitHub writes. Temporary fixture files and
per-fixture logs are confined to the ignored `cmake/two-human-reviewers-tests/`
directory.

The prerequisite PR deliberately leaves both production caller workflows
unchanged. A subsequent loader change can consume this contract after the action
is available on its trusted target branch.
