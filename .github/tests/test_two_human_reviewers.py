#!/usr/bin/env python3
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

"""Run the composite action's Bash against fixture-only gh API responses."""

import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
ACTION = ROOT / ".github" / "actions" / "two-human-reviewers" / "action.yml"
SCRATCH = ROOT / "cmake" / "two-human-reviewers-tests"
HEAD = "a" * 40
OLD_HEAD = "b" * 40
TARGET = "master"
REPO = "fixture-owner/fixture-repo"
CONTRACT = "# two-human-reviewers-snapshot-contract: 1"
SNAPSHOT = {"expected-head": HEAD, "expected-target": TARGET}


def pull_request(number=1, login="automation[bot]", kind="Bot", head=HEAD, target=TARGET, state="open"):
    return {
        "number": number,
        "state": state,
        "user": {"login": login, "type": kind},
        "head": {"sha": head},
        "base": {"ref": target},
    }


def review(number, login, state="APPROVED", head=HEAD, push=True, kind="User"):
    return {
        "databaseId": number,
        "state": state,
        "authorCanPushToRepository": push,
        "author": {"login": login, "__typename": kind},
        "commit": {"oid": head},
    }


def pending(count=0, required=2):
    return f"Needs {required} approvals from distinct humans on this commit; {count} so far"


@dataclass
class Fixture:
    name: str
    state: str | None = "pending"
    description: str = pending()
    inputs: dict = field(default_factory=dict)
    api: dict = field(default_factory=dict)
    exit_code: int = 0
    message: str = ""
    calls: tuple = ("pr", "shared", "reviews:1", "status")


def fixtures():
    pair = [review(1, "alice"), review(2, "bob")]
    no_bot = "No bot-authored pull request on this commit"
    success = "2 of 2 human approvals on this commit"
    no_reviews = ("pr", "shared", "status")
    guarded = ("pr", "shared", "reviews:1", "pr", "status")
    cases = [
        Fixture("bot-defaults"),
        Fixture("empty-input-defaults", inputs={"required-approvals": "", "exempt-bots": ""}),
        Fixture(
            "human",
            state="success",
            description=no_bot,
            api={"pr": pull_request(login="human", kind="User")},
            calls=no_reviews,
        ),
        Fixture(
            "human-with-bot-like-login",
            state="success",
            description=no_bot,
            api={"pr": pull_request(kind="User")},
            calls=no_reviews,
        ),
        Fixture(
            "default-exempt-bot",
            state="success",
            description=no_bot,
            api={"pr": pull_request(login="dependabot[bot]")},
            calls=no_reviews,
        ),
        Fixture(
            "empty-exemption-keeps-default",
            state="success",
            description=no_bot,
            inputs={"exempt-bots": ""},
            api={"pr": pull_request(login="dependabot[bot]")},
            calls=no_reviews,
        ),
        Fixture(
            "custom-exempt-bots-trimmed",
            state="success",
            description=no_bot,
            inputs={"exempt-bots": "other[bot], , automation[bot]  ,"},
            calls=no_reviews,
        ),
        Fixture(
            "custom-exemption-replaces-default",
            inputs={"exempt-bots": "other[bot]"},
            api={"pr": pull_request(login="dependabot[bot]")},
        ),
        Fixture(
            "explicit-empty-exemption-list",
            inputs={"exempt-bots": " , "},
            api={"pr": pull_request(login="dependabot[bot]")},
        ),
        Fixture(
            "one-approval-is-pending",
            description=pending(1),
            api={"reviews": {"1": [[review(1, "alice")]]}},
        ),
        Fixture(
            "two-current-human-approvals",
            state="success",
            description=success,
            api={"reviews": {"1": [pair]}},
        ),
        Fixture(
            "more-than-required",
            state="success",
            description="3 of 2 human approvals on this commit",
            api={"reviews": {"1": [pair + [review(3, "carol")]]}},
        ),
        Fixture(
            "custom-lower-count",
            state="success",
            description="1 of 1 human approvals on this commit",
            inputs={"required-approvals": "1"},
            api={"reviews": {"1": [[review(1, "alice")]]}},
        ),
        Fixture(
            "custom-higher-count",
            description=pending(2, 3),
            inputs={"required-approvals": "3"},
            api={"reviews": {"1": [pair]}},
        ),
        Fixture(
            "stale-approval",
            description=pending(1),
            api={"reviews": {"1": [[review(1, "alice"), review(2, "bob", head=OLD_HEAD)]]}},
        ),
        Fixture(
            "ineligible-reviewers",
            description=pending(1),
            api={"reviews": {"1": [[
                review(1, "outside-writer") | {"authorAssociation": "NONE"},
                review(2, "org-member", push=False) | {"authorAssociation": "MEMBER"},
                review(3, "read-only-collaborator", push=False),
                review(4, "unknown-access", push=None),
                review(5, "not-a-boolean", push="true"),
                review(6, "review-bot[bot]", kind="Bot"),
            ]]}},
        ),
        Fixture(
            "duplicate-approvals",
            description=pending(1),
            api={"reviews": {"1": [[review(1, "alice"), review(2, "alice")]]}},
        ),
        Fixture(
            "latest-changes-requested-even-out-of-order",
            description=pending(1),
            api={"reviews": {"1": [[review(9, "alice", state="CHANGES_REQUESTED"), *pair]]}},
        ),
        Fixture(
            "dismissal-supersedes-approval",
            description=pending(1),
            api={"reviews": {"1": [pair + [review(3, "alice", state="DISMISSED")]]}},
        ),
        Fixture(
            "dismissed-in-place",
            description=pending(1),
            api={"reviews": {"1": [[review(1, "alice", state="DISMISSED"), review(2, "bob")]]}},
        ),
        Fixture(
            "comments-and-pending-do-not-revoke",
            state="success",
            description=success,
            api={"reviews": {"1": [pair + [
                review(3, "alice", state="COMMENTED"),
                review(4, "bob", state="PENDING"),
            ]]}},
        ),
        Fixture(
            "reapproval-after-rejection",
            state="success",
            description=success,
            api={"reviews": {"1": [[
                review(1, "alice", state="CHANGES_REQUESTED"),
                review(2, "bob", state="DISMISSED"),
                review(3, "alice"),
                review(4, "bob"),
            ]]}},
        ),
        Fixture(
            "latest-verdict-before-head-filter",
            description=pending(1),
            api={"reviews": {"1": [pair + [review(3, "alice", head=OLD_HEAD)]]}},
        ),
        Fixture(
            "review-pagination",
            state="success",
            description=success,
            api={"reviews": {"1": [[review(1, "alice")], [review(2, "bob")]]}},
        ),
        Fixture(
            "shared-head-aggregation-and-index-lag",
            state="success",
            description=success,
            api={
                "pr": pull_request(login="human", kind="User"),
                "shared": [[], [pull_request(2)]],
                "reviews": {"1": [[review(1, "alice")]], "2": [[review(2, "bob")]]},
            },
            calls=("pr", "shared", "reviews:1", "reviews:2", "status"),
        ),
        Fixture(
            "human-trigger-shares-bot-head",
            api={
                "pr": pull_request(login="human", kind="User"),
                "shared": [[pull_request(2)]],
                "reviews": {"1": [[]], "2": [[]]},
            },
            calls=("pr", "shared", "reviews:1", "reviews:2", "status"),
        ),
        Fixture(
            "shared-pr-and-reviewer-deduplication",
            description=pending(1),
            api={
                "shared": [[pull_request(2), pull_request()], [pull_request(2)]],
                "reviews": {"1": [[review(1, "alice")]], "2": [[review(2, "alice")]]},
            },
            calls=("pr", "shared", "reviews:1", "reviews:2", "status"),
        ),
        Fixture(
            "shared-latest-verdict",
            description=pending(1),
            api={
                "shared": [[pull_request(2)]],
                "reviews": {"1": [pair], "2": [[review(3, "alice", state="CHANGES_REQUESTED")]]},
            },
            calls=("pr", "shared", "reviews:1", "reviews:2", "status"),
        ),
        Fixture(
            "closed-and-older-head-prs-ignored",
            state="success",
            description=no_bot,
            api={
                "pr": pull_request(login="human", kind="User"),
                "shared": [[pull_request(2, state="closed"), pull_request(3, head=OLD_HEAD)]],
            },
            calls=no_reviews,
        ),
        Fixture("closed-trigger-fallback", api={"pr": pull_request(state="closed")}),
        Fixture(
            "manual-pr-number-without-event",
            state="success",
            description=no_bot,
            inputs={"pr": "42"},
            api={"pr": pull_request(42, login="human", kind="User")},
            calls=no_reviews,
        ),
        Fixture(
            "fork-read-only-token",
            api={"fail": "status"},
            message="Run workflow (not Re-run) and pr=1",
        ),
        Fixture(
            "missing-pr",
            state=None,
            inputs={"pr": ""},
            exit_code=1,
            message="No pull request to evaluate",
            calls=(),
        ),
        Fixture(
            "initial-api-failure",
            state=None,
            api={"fail": "pr:1"},
            exit_code=1,
            message="Fixture API failure: pr:1",
            calls=("pr",),
        ),
        Fixture(
            "shared-api-failure-is-not-hidden",
            state=None,
            api={"pr": pull_request(login="human", kind="User"), "fail": "shared"},
            exit_code=1,
            message="Fixture API failure: shared",
            calls=("pr", "shared"),
        ),
        Fixture(
            "reviews-api-failure",
            state=None,
            api={"fail": "reviews:1"},
            exit_code=1,
            message="Fixture API failure: reviews:1",
            calls=("pr", "shared", "reviews:1"),
        ),
        Fixture(
            "matching-snapshot",
            state="success",
            description=success,
            inputs=SNAPSHOT,
            api={"reviews": {"1": [pair]}},
            calls=guarded,
        ),
        Fixture(
            "empty-snapshot-keeps-legacy-behavior",
            inputs={"expected-head": "", "expected-target": ""},
            api={"pr_after": pull_request(head=OLD_HEAD, target="release")},
        ),
        Fixture(
            "head-only-snapshot-captures-target",
            state=None,
            inputs={"expected-head": HEAD},
            api={"pr_after": pull_request(target="release")},
            exit_code=1,
            message="no longer matches the captured snapshot",
            calls=guarded[:-1],
        ),
        Fixture(
            "target-only-snapshot-captures-head",
            state=None,
            inputs={"expected-target": TARGET},
            api={"pr_after": pull_request(head=OLD_HEAD)},
            exit_code=1,
            message="no longer matches the captured snapshot",
            calls=guarded[:-1],
        ),
        Fixture(
            "target-branch-advancement-is-not-retarget",
            inputs=SNAPSHOT,
            api={"pr_after": pull_request() | {"base": {"ref": TARGET, "sha": OLD_HEAD}}},
            calls=guarded,
        ),
        Fixture(
            "freshness-api-failure",
            state=None,
            inputs=SNAPSHOT,
            api={"fail": "pr:2"},
            exit_code=1,
            message="Fixture API failure: pr:2",
            calls=guarded[:-1],
        ),
    ]
    for index, value in enumerate(("0", "-1", "1.5", "no", "01", " 2", "+2", "1e2", "2\n3", "$(exit 0)")):
        cases.append(Fixture(
            f"invalid-count-{index}",
            state=None,
            inputs={"required-approvals": value},
            exit_code=1,
            message="required-approvals must be a positive integer",
            calls=(),
        ))
    for input_name, wrong_value in (("expected-head", OLD_HEAD), ("expected-target", "release")):
        for author in ("bot", "human", "exempt"):
            pr = {
                "bot": pull_request(),
                "human": pull_request(login="human", kind="User"),
                "exempt": pull_request(login="dependabot[bot]"),
            }[author]
            cases.append(Fixture(
                f"{input_name}-mismatch-before-evaluation-{author}",
                state=None,
                inputs={**SNAPSHOT, input_name: wrong_value},
                api={"pr": pr},
                exit_code=1,
                message="no longer matches the captured snapshot",
                calls=("pr",),
            ))
    for change, changed_pr in (("push", pull_request(head=OLD_HEAD)), ("retarget", pull_request(target="release"))):
        for verdict in ("human-success", "bot-success", "bot-pending"):
            human = verdict == "human-success"
            cases.append(Fixture(
                f"{change}-before-publishing-{verdict}",
                state=None,
                inputs=SNAPSHOT,
                api={
                    "pr": pull_request(login="human", kind="User") if human else pull_request(),
                    "pr_after": changed_pr,
                    "reviews": {"1": [pair if verdict == "bot-success" else []]},
                },
                exit_code=1,
                message="no longer matches the captured snapshot",
                calls=("pr", "shared", "pr") if human else guarded[:-1],
            ))
    return cases


def fake_gh(argv):
    """Only implement API transport, pagination and gh's --jq filtering, never gate policy."""
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["api"])
    parser.add_argument("endpoint")
    parser.add_argument("--method", "-X", default="GET")
    parser.add_argument("--paginate", action="store_true")
    parser.add_argument("--jq")
    parser.add_argument("-f", "-F", dest="fields", action="append", default=[])
    parser.add_argument("-H", dest="headers", action="append", default=[])
    args = parser.parse_args(argv)
    fields = dict(value.split("=", 1) for value in args.fields)
    fixture = json.loads(Path(os.environ["FIXTURE_DATA"]).read_text(encoding="utf-8"))
    log = Path(os.environ["FIXTURE_CALLS"])
    previous = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
    pr = fixture["pr"]

    if args.endpoint == f"repos/{REPO}/pulls/{pr['number']}":
        kind = "pr"
        read_number = sum(call["kind"] == "pr" for call in previous) + 1
        error_key = f"pr:{read_number}"
        sequence = fixture.get("pr_sequence", [pr, fixture.get("pr_after", pr)])
        pages = [sequence[min(read_number - 1, len(sequence) - 1)]]
    elif args.endpoint == f"repos/{REPO}/commits/{pr['head']['sha']}/pulls":
        kind = error_key = "shared"
        pages = fixture["shared"]
    elif args.endpoint == "graphql":
        number = fields["pr"]
        kind = error_key = f"reviews:{number}"
        if fields["owner"] + "/" + fields["repo"] != REPO:
            raise ValueError("Unexpected GraphQL repository")
        pages = [
            {"data": {"repository": {"pullRequest": {"reviews": {
                "nodes": nodes,
                "pageInfo": {"hasNextPage": index + 1 < len(fixture["reviews"][number]),
                             "endCursor": str(index)},
            }}}}}
            for index, nodes in enumerate(fixture["reviews"][number])
        ]
    elif args.endpoint.startswith(f"repos/{REPO}/statuses/") and args.method == "POST":
        kind = error_key = "status"
        pages = [{"state": fields["state"]}]
    elif args.endpoint in fixture.get("resources", {}):
        kind = "resource"
        error_key = f"resource:{args.endpoint}"
        pages = [fixture["resources"][args.endpoint]]
    else:
        raise ValueError(f"Unexpected fixture API call: {argv!r}")

    failures = fixture.get("fail", [])
    if isinstance(failures, str):
        failures = [failures]
    status_number = sum(call["kind"] == "status" for call in previous) + 1
    failed = error_key in failures or (kind == "status" and f"status:{status_number}" in failures)
    call = {"kind": kind, "endpoint": args.endpoint, "fields": fields, "method": args.method,
            "paginate": args.paginate, "jq": args.jq, "failed": failed}
    with log.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(call) + "\n")
    if failed:
        print(f"Fixture API failure: {error_key}", file=sys.stderr)
        return 1
    for page in pages if args.paginate else pages[:1]:
        if args.jq:
            result = subprocess.run(
                [shutil.which("jq"), "-c", args.jq],
                input=json.dumps(page), text=True, capture_output=True, check=True,
            )
            sys.stdout.write(result.stdout)
        elif "Accept: application/vnd.github.raw+json" in args.headers:
            sys.stdout.write(page)
        else:
            print(json.dumps(page))
    return 0


def action_environment(action, step, inputs, extra_context=None):
    """Render only the input fallbacks and context substitutions used by this action."""
    context = {
        "github.token": "fixture-token-not-a-credential",
        "github.repository": REPO,
        "github.server_url": "https://github.invalid",
        "github.run_id": "123",
        **(extra_context or {}),
    }

    def replace(match):
        expression, *fallback = match.group(1).strip().split(" || ", 1)
        if expression.startswith("inputs."):
            name = expression.removeprefix("inputs.")
            value = inputs.get(name, action["inputs"][name].get("default", ""))
        else:
            value = context[expression]
        if not value and fallback:
            literal = fallback[0]
            if not re.fullmatch(r"'[^']*'|[0-9]+", literal):
                raise ValueError(f"Unsupported fixture expression: {match.group(0)}")
            value = literal.strip("'")
        return str(value)

    return {
        key: re.sub(r"\$\{\{(.*?)\}\}", replace, str(value))
        for key, value in step.get("env", {}).items()
    }


def fixture_environment(work, api):
    data_file = work / "api.json"
    calls_file = work / "calls.jsonl"
    data_file.write_text(json.dumps(api), encoding="utf-8")
    calls_file.write_text("", encoding="utf-8")
    # Do not inherit credentials, gh configuration, shell startup files, or GitHub event data.
    env = {
        key: value for key, value in os.environ.items()
        if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT"}
    }
    env.update({
        "HOME": str(work),
        "GH_CONFIG_DIR": str(work),
        "XDG_CONFIG_HOME": str(work),
        "TEMP": str(work),
        "TMP": str(work),
        "TMPDIR": work.as_posix(),
        "FIXTURE_DATA": str(data_file),
        "FIXTURE_CALLS": str(calls_file),
        "FIXTURE_PYTHON": Path(sys.executable).as_posix(),
        "FIXTURE_SCRIPT": Path(__file__).resolve().as_posix(),
        "FIXTURE_JQ": Path(shutil.which("jq")).as_posix(),
        "PYTHONDONTWRITEBYTECODE": "1",
    })
    return env, calls_file


def run_bash_step(step, env, cwd):
    if step.get("shell") != "bash" or "run" not in step or "uses" in step:
        raise ValueError("The fixture harness requires inline Bash steps")
    prelude = 'gh() { "$FIXTURE_PYTHON" "$FIXTURE_SCRIPT" --fake-gh "$@"; }\n'
    if os.name == "nt":
        # Native jq otherwise emits CRLF between results; match the Ubuntu runner's LF.
        prelude += 'jq() { "$FIXTURE_JQ" --binary "$@"; }\n'
    result = subprocess.run(
        [shutil.which("bash"), "--noprofile", "--norc", "-eo", "pipefail", "-s"],
        input=(prelude + step["run"]).encode("utf-8"), capture_output=True, cwd=cwd,
        env=env, timeout=30,
    )
    return result.returncode, result.stdout.decode("utf-8") + result.stderr.decode("utf-8")


def run_fixture(action, fixture):
    api = {
        "pr": pull_request(),
        "shared": [[]],
        "reviews": {"1": [[]]},
        **fixture.api,
    }
    inputs = {"pr": str(api["pr"]["number"]), **fixture.inputs}
    with tempfile.TemporaryDirectory(prefix=fixture.name + "-", dir=SCRATCH) as directory:
        work = Path(directory)
        env, calls_file = fixture_environment(work, api)
        output = ""
        exit_code = 0
        for step in action["runs"]["steps"]:
            exit_code, step_output = run_bash_step(
                step, {**env, **action_environment(action, step, inputs)}, SCRATCH
            )
            output += step_output
            if exit_code:
                break
        calls = [json.loads(line) for line in calls_file.read_text(encoding="utf-8").splitlines()]
        (SCRATCH / (fixture.name + ".log")).write_text(
            output + "\nAPI calls:\n" + json.dumps(calls, indent=2), encoding="utf-8"
        )
        return exit_code, output, calls


class ReviewerGateFixtures(unittest.TestCase):
    def test_action_fixtures(self):
        for tool in ("bash", "jq"):
            self.assertIsNotNone(shutil.which(tool), f"{tool} must be on PATH")
        text = ACTION.read_text(encoding="utf-8")
        action = yaml.safe_load(text)
        self.assertIn(CONTRACT, text.splitlines())
        self.assertEqual("composite", action["runs"]["using"])
        for name in SNAPSHOT:
            self.assertFalse(action["inputs"][name]["required"])
        cases = fixtures()
        SCRATCH.mkdir(parents=True, exist_ok=True)
        for fixture in cases:
            with self.subTest(fixture=fixture.name):
                exit_code, output, calls = run_fixture(action, fixture)
                self.assertEqual(fixture.exit_code, exit_code, output)
                self.assertEqual(fixture.calls, tuple(call["kind"] for call in calls), output)
                self.assertIn(fixture.message, output)
                posts = [call for call in calls if call["kind"] == "status"]
                if fixture.state is None:
                    self.assertEqual([], posts, output)
                else:
                    self.assertEqual(1, len(posts), output)
                    self.assertEqual(f"repos/{REPO}/statuses/{fixture.api.get('pr', pull_request())['head']['sha']}",
                                     posts[0]["endpoint"])
                    self.assertEqual({
                        "state": fixture.state,
                        "context": "mrbot/two-human-reviewers",
                        "description": fixture.description,
                        "target_url": f"https://github.invalid/{REPO}/actions/runs/123",
                    }, posts[0]["fields"])
                for call in calls:
                    if call["kind"] == "shared" or call["kind"].startswith("reviews:"):
                        self.assertTrue(call["paginate"], call)
        print(f"Executed {len(cases)} action fixtures; logs: {SCRATCH.relative_to(ROOT)}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--fake-gh"]:
        sys.stdout.reconfigure(newline="\n")
        sys.exit(fake_gh(sys.argv[2:]))
    else:
        unittest.main(verbosity=2)
