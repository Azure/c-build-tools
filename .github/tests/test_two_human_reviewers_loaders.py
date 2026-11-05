#!/usr/bin/env python3
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

"""Exercise the production loaders and downloaded action with fixture-only GitHub transport."""

import copy
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from urllib.parse import quote

import yaml

from test_two_human_reviewers import (
    ACTION, CONTRACT, HEAD, OLD_HEAD, REPO, ROOT, SCRATCH,
    action_environment, fixture_environment, pull_request, review, run_bash_step,
)


BASE = "c" * 40
GATE = "d" * 40
MASTER = "e" * 40
PIN = "f" * 40
UPSTREAM = "Azure/c-build-tools"
ACTION_PATH = ".github/actions/two-human-reviewers/action.yml"
WORKFLOW = ROOT / ".github/workflows/two-human-reviewers.yml"
CALLER = ROOT / ".github/workflow-templates/two-human-reviewers.caller.yml"
EDIT_GUARD = (
    "${{ github.event_name != 'pull_request' || github.event.action != 'edited' || "
    "github.event.changes.base != null }}"
)
READ_ONLY_GUARD = (
    "${{ (github.event_name == 'pull_request' || github.event_name == 'pull_request_review') && "
    "(github.event.pull_request.head.repo.full_name != github.repository || github.actor == 'dependabot[bot]') }}"
)


def workflow_document(path):
    # GitHub uses YAML 1.2; BaseLoader avoids YAML 1.1's conversion of the key 'on' to True.
    return yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def resources(mode, target):
    source = REPO if mode == "self" else UPSTREAM
    result = {
        f"repos/{REPO}/git/ref/heads/{quote(target, safe='')}": {
            "ref": f"refs/heads/{target}", "object": {"type": "commit", "sha": BASE},
        },
        f"repos/{source}/contents/{ACTION_PATH}": ACTION.read_text(encoding="utf-8"),
    }
    if mode == "consumer":
        result.update({
            f"repos/{REPO}/contents/deps/c-build-tools": {"type": "submodule", "sha": GATE},
            f"repos/{UPSTREAM}/git/ref/heads/master": {
                "ref": "refs/heads/master", "object": {"type": "commit", "sha": MASTER},
            },
            f"repos/{UPSTREAM}/compare/{GATE}...{MASTER}": {"status": "ahead"},
        })
    return result


def run_loader(mode, name, api_overrides=None, inputs=None, readonly=False, workflow_sha=PIN):
    document = workflow_document(CALLER if mode == "consumer" else WORKFLOW)
    job = document["jobs"]["two-human-reviewers"]
    api = {
        "pr": pull_request(),
        "shared": [[]],
        "reviews": {"1": [[]]},
        **(api_overrides or {}),
    }
    api["resources"] = {**resources(mode, api["pr"]["base"]["ref"]), **api.get("resources", {})}
    supplied_inputs = {"pr": str(api["pr"]["number"]), **(inputs or {})}
    definitions = yaml.safe_load(ACTION.read_text(encoding="utf-8"))
    with tempfile.TemporaryDirectory(prefix=f"loader-{mode}-{name}-", dir=SCRATCH) as directory:
        work = Path(directory)
        env, calls_file = fixture_environment(work, api)
        output_file = work / "outputs"
        output_file.write_text("", encoding="utf-8")
        env.update({
            "REPO": REPO, "PR": str(supplied_inputs["pr"]),
            "STATUS_CONTEXT": "mrbot/two-human-reviewers",
            "RUN_URL": f"https://github.invalid/{REPO}/actions/runs/123",
            "READ_ONLY": str(readonly).lower(),
            "GITHUB_OUTPUT": output_file.as_posix(),
        })
        context = {
            "job.workflow_repository": REPO if mode == "self" else UPSTREAM,
            "job.workflow_sha": workflow_sha,
        }
        captured = {}
        output = ""
        failed = False
        for step in job["steps"]:
            is_reporter = step["name"] == "Report gate failure"
            if is_reporter:
                if not failed or not captured.get("head"):
                    continue
            elif failed:
                continue
            step_env = {
                **env,
                **action_environment(definitions, step, supplied_inputs, context),
            }
            if step.get("uses") == "./.gate":
                try:
                    action = yaml.safe_load((work / ".gate/action.yml").read_text(encoding="utf-8"))
                except yaml.YAMLError as error:
                    output += f"Invalid downloaded action: {error}\n"
                    failed = True
                    continue
                if not isinstance(action, dict) or not isinstance(action.get("runs"), dict):
                    output += "Invalid downloaded action metadata\n"
                    failed = True
                    continue
                action_inputs = action_environment(
                    definitions, {"env": step["with"]}, supplied_inputs, context
                )
                for action_step in action["runs"]["steps"]:
                    code, text = run_bash_step(
                        action_step,
                        {**step_env, **action_environment(action, action_step, action_inputs)},
                        work,
                    )
                    output += text
                    if code:
                        failed = True
                        break
            else:
                code, text = run_bash_step(step, step_env, work)
                output += text
                failed = failed or code != 0
            if step.get("id") == "capture":
                captured = dict(
                    line.split("=", 1) for line in output_file.read_text(encoding="utf-8").splitlines()
                )
                context.update({f"steps.capture.outputs.{key}": value for key, value in captured.items()})

        calls = [json.loads(line) for line in calls_file.read_text(encoding="utf-8").splitlines()]
        (SCRATCH / f"loader-{mode}-{name}.log").write_text(
            output + "\nAPI calls:\n" + json.dumps(calls, indent=2), encoding="utf-8"
        )
        return failed, output, calls


class ReviewerGateLoaders(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ("bash", "jq", "git", "grep"):
            if shutil.which(tool) is None:
                raise RuntimeError(f"{tool} must be on PATH")
        SCRATCH.mkdir(parents=True, exist_ok=True)
        cls.case_count = 0

    @classmethod
    def tearDownClass(cls):
        print(f"Executed {cls.case_count} loader fixtures; logs: {SCRATCH.relative_to(ROOT)}")

    def check_result(self, result, failed, states):
        type(self).case_count += 1
        actual_failure, output, calls = result
        self.assertEqual(failed, actual_failure, output)
        posts = [call for call in calls if call["kind"] == "status"]
        self.assertEqual(states, [call["fields"]["state"] for call in posts], output)
        for post in posts:
            self.assertEqual(f"repos/{REPO}/statuses/{HEAD}", post["endpoint"])
            self.assertEqual("mrbot/two-human-reviewers", post["fields"]["context"])
            self.assertEqual(f"https://github.invalid/{REPO}/actions/runs/123", post["fields"]["target_url"])
        return calls

    def test_loading_and_execution_failures_invalidate_old_success(self):
        broken_action = copy.deepcopy(yaml.safe_load(ACTION.read_text(encoding="utf-8")))
        broken_action["runs"]["steps"][0]["run"] = 'echo "::error::Fixture evaluator failed"\nexit 17\n'
        scenarios = {
            "download-failed": None,
            "contract-missing": ACTION.read_text(encoding="utf-8").replace(CONTRACT, "# old contract"),
            "action-invalid": CONTRACT + "\nname: broken\nruns: [",
            "evaluator-failed": CONTRACT + "\n" + yaml.safe_dump(broken_action),
        }
        for mode in ("consumer", "self", "called"):
            source = REPO if mode == "self" else UPSTREAM
            endpoint = f"repos/{source}/contents/{ACTION_PATH}"
            for name, response in scenarios.items():
                with self.subTest(mode=mode, failure=name):
                    api = {"fail": f"resource:{endpoint}"} if response is None else {
                        "resources": {endpoint: response},
                    }
                    calls = self.check_result(run_loader(mode, name, api), True, ["pending", "error"])
                    accepted = [call["fields"]["state"] for call in calls
                                if call["kind"] == "status" and not call["failed"]]
                    self.assertEqual(["pending", "error"], accepted)
                    if name in ("download-failed", "contract-missing"):
                        self.assertFalse(any(call["kind"] == "shared" for call in calls))

    def test_ancestry_rejection_and_gitlink_validation(self):
        compare = f"repos/{UPSTREAM}/compare/{GATE}...{MASTER}"
        for status in ("identical", "behind", "diverged", "unknown", None):
            with self.subTest(ancestry=status):
                accepted = status == "identical"
                api = {"resources": {compare: {"status": status}}}
                if accepted:
                    api["resources"].update({
                        f"repos/{REPO}/contents/deps/c-build-tools": {"type": "submodule", "sha": MASTER},
                        f"repos/{UPSTREAM}/compare/{MASTER}...{MASTER}": {"status": "identical"},
                    })
                calls = self.check_result(
                    run_loader("consumer", f"ancestry-{status}", api),
                    not accepted, ["pending", "pending" if accepted else "error"],
                )
                self.assertEqual(accepted, any(call["endpoint"].endswith(ACTION_PATH) for call in calls))
                if accepted:
                    download = next(call for call in calls if call["endpoint"].endswith(ACTION_PATH))
                    self.assertEqual(MASTER, download["fields"]["ref"])
        endpoint = f"repos/{REPO}/contents/deps/c-build-tools"
        for name, gitlink in (
            ("not-a-submodule", {"type": "file", "sha": GATE}),
            ("invalid-pin", {"type": "submodule", "sha": "master"}),
            ("missing-pin", {"type": "submodule"}),
        ):
            with self.subTest(gitlink=name):
                calls = self.check_result(
                    run_loader("consumer", name, {"resources": {endpoint: gitlink}}),
                    True, ["pending", "error"],
                )
                self.assertFalse(any(call["endpoint"].endswith(ACTION_PATH) for call in calls))

    def test_loader_api_failures_and_invalid_refs(self):
        endpoints = (
            f"repos/{REPO}/git/ref/heads/master",
            f"repos/{REPO}/contents/deps/c-build-tools",
            f"repos/{UPSTREAM}/git/ref/heads/master",
            f"repos/{UPSTREAM}/compare/{GATE}...{MASTER}",
        )
        for index, endpoint in enumerate(endpoints):
            with self.subTest(endpoint=endpoint):
                self.check_result(
                    run_loader("consumer", f"api-failure-{index}", {"fail": f"resource:{endpoint}"}),
                    True, ["pending", "error"],
                )
        for mode in ("consumer", "self"):
            with self.subTest(mode=mode):
                api = {"resources": {endpoints[0]: {
                    "ref": "refs/tags/master", "object": {"type": "commit", "sha": BASE},
                }}}
                self.check_result(run_loader(mode, "wrong-ref", api), True, ["pending", "error"])
        self.check_result(
            run_loader("called", "invalid-workflow-sha", workflow_sha="master"),
            True, ["pending", "error"],
        )

    def test_superseded_evaluations_do_not_publish_obsolete_errors(self):
        for mode in ("consumer", "self", "called"):
            for change, changed in (
                ("push", pull_request(head=OLD_HEAD)),
                ("retarget", pull_request(target="release")),
            ):
                for timing, sequence in (
                    ("before-action", [pull_request(), changed]),
                    ("before-verdict", [pull_request(), pull_request(), changed]),
                ):
                    with self.subTest(mode=mode, change=change, timing=timing):
                        result = run_loader(mode, f"{change}-{timing}", {"pr_sequence": sequence})
                        self.check_result(result, True, ["pending"])
                        self.assertIn("no obsolete failure status was published", result[1])
        endpoint = f"repos/{UPSTREAM}/contents/{ACTION_PATH}"
        self.check_result(run_loader("consumer", "retarget-during-failed-download", {
            "fail": f"resource:{endpoint}",
            "pr_sequence": [pull_request(), pull_request(target="release")],
        }), True, ["pending"])

    def test_readonly_and_status_write_failures(self):
        for mode in ("consumer", "self", "called"):
            with self.subTest(mode=mode):
                result = run_loader(mode, "readonly", {"fail": "status"}, readonly=True)
                calls = self.check_result(result, False, ["pending", "pending"])
                self.assertTrue(all(call["failed"] for call in calls if call["kind"] == "status"))
                self.assertIn("status was not reset", result[1])
                self.assertIn("Run workflow", result[1])
        result = run_loader("consumer", "pending-write-failed", {"fail": "status:1"})
        calls = self.check_result(result, True, ["pending", "error"])
        self.assertFalse(any(call["kind"] == "resource" for call in calls))
        self.assertIn("Could not reset the required status", result[1])
        result = run_loader("self", "all-status-writes-failed", {"fail": "status"})
        calls = self.check_result(result, True, ["pending", "error"])
        self.assertTrue(all(call["failed"] for call in calls if call["kind"] == "status"))
        self.assertIn("Could not publish the gate failure", result[1])
        result = run_loader("consumer", "failure-recheck-unavailable", {
            "fail": [f"resource:repos/{UPSTREAM}/contents/{ACTION_PATH}", "pr:2"],
        })
        self.check_result(result, True, ["pending"])
        self.assertIn("Could not recheck the PR", result[1])
        result = run_loader("consumer", "readonly-loader-failure", {
            "fail": ["status", f"resource:repos/{UPSTREAM}/contents/{ACTION_PATH}"],
        }, readonly=True)
        calls = self.check_result(result, True, ["pending", "error"])
        self.assertTrue(all(call["failed"] for call in calls if call["kind"] == "status"))
        self.assertIn("failure status was not published", result[1])
        self.check_result(
            run_loader("called", "action-freshness-read-failure", {"fail": "pr:3"}),
            True, ["pending", "error"],
        )

    def test_defaults_custom_inputs_and_manual_dispatch(self):
        for count, state, description in (
            (0, "pending", "needs 2"),
            (1, "success", "has 1 of 1"),
            (3, "pending", "needs 3"),
        ):
            with self.subTest(count=count):
                result = run_loader(
                    "called", f"approval-count-{count}",
                    {"reviews": {"1": [[review(1, "alice")]]}}, {"required-approvals": count},
                )
                self.check_result(result, False, ["pending", state])
                self.assertIn(description, result[1])
        self.check_result(run_loader(
            "called", "custom-exempt-bot", inputs={"exempt-bots": "automation[bot]"},
        ), False, ["pending", "success"])
        result = run_loader("called", "invalid-approval-count", inputs={"required-approvals": -1})
        self.check_result(result, True, ["pending", "error"])
        self.assertIn("required-approvals must be a positive integer", result[1])
        for mode in ("consumer", "self", "called"):
            with self.subTest(manual=mode):
                result = run_loader(mode, "manual-42", {
                    "pr": pull_request(42), "reviews": {"42": [[]]},
                }, {"pr": "42"})
                calls = self.check_result(result, False, ["pending", "pending"])
                self.assertTrue(all(call["endpoint"] == f"repos/{REPO}/pulls/42"
                                    for call in calls if call["kind"] == "pr"))

    def test_capture_validation_and_initial_api_failure(self):
        for index, value in enumerate(("", "0", "1/../2", "1\n2", "$(exit 0)")):
            with self.subTest(pr=value):
                result = run_loader("consumer", f"invalid-pr-{index}", inputs={"pr": value})
                self.assertEqual([], self.check_result(result, True, []))
                self.assertIn("positive PR number", result[1])
        for name, pr in (
            ("invalid-head", pull_request(head="master")),
            ("invalid-target", pull_request(target="master\nhead=injected")),
        ):
            with self.subTest(metadata=name):
                self.check_result(run_loader("self", name, {"pr": pr}), True, [])
        self.check_result(run_loader("consumer", "pr-read-failed", {"fail": "pr:1"}), True, [])

    def test_live_branch_snapshot_not_recorded_base_sha(self):
        for target in ("master", "release/1"):
            with self.subTest(target=target):
                pr = pull_request(target=target)
                pr["base"]["sha"] = OLD_HEAD
                result = run_loader("consumer", f"target-{target.replace('/', '-')}", {"pr": pr})
                calls = self.check_result(result, False, ["pending", "pending"])
                gitlink = next(call for call in calls if call["endpoint"].endswith("/contents/deps/c-build-tools"))
                self.assertEqual(BASE, gitlink["fields"]["ref"])
                self.assertTrue(any(call["endpoint"] == f"repos/{REPO}/git/ref/heads/{quote(target, safe='')}"
                                    for call in calls))

    def test_trusted_sources_and_pending_before_load(self):
        for mode, expected_sha in (("consumer", GATE), ("self", BASE), ("called", PIN)):
            with self.subTest(mode=mode):
                result = run_loader(mode, "trusted-source")
                calls = self.check_result(result, False, ["pending", "pending"])
                self.assertEqual("status", calls[1]["kind"], result[1])
                self.assertEqual("pr", calls[0]["kind"], result[1])
                downloads = [call for call in calls if call["endpoint"].endswith(ACTION_PATH)]
                self.assertEqual(1, len(downloads))
                self.assertEqual({"ref": expected_sha}, downloads[0]["fields"])
                if mode == "consumer":
                    gitlinks = [call for call in calls if call["endpoint"].endswith("/contents/deps/c-build-tools")]
                    self.assertEqual([{"ref": BASE}], [call["fields"] for call in gitlinks])
                elif mode == "called":
                    self.assertFalse(any("/git/ref/" in call["endpoint"] for call in calls))

    def test_event_and_snapshot_wiring(self):
        caller = workflow_document(CALLER)
        reusable = workflow_document(WORKFLOW)
        for document in (caller, reusable):
            events = document["on"]
            self.assertIn("edited", events["pull_request"]["types"])
            self.assertEqual(["submitted", "dismissed"], events["pull_request_review"]["types"])
            self.assertIn("workflow_dispatch", events)
            job = document["jobs"]["two-human-reviewers"]
            self.assertEqual(EDIT_GUARD, job["if"])
            self.assertEqual(READ_ONLY_GUARD, job["env"]["READ_ONLY"])
            self.assertEqual("${{ github.event.pull_request.number || inputs.pr }}", job["env"]["PR"])
            self.assertEqual("mrbot/two-human-reviewers", job["env"]["STATUS_CONTEXT"])
            self.assertEqual(
                {"contents": "read", "pull-requests": "read", "statuses": "write"}, document["permissions"]
            )
            evaluator = next(step for step in job["steps"] if step.get("id") == "evaluate")
            self.assertEqual("./.gate", evaluator["uses"])
            self.assertEqual("${{ steps.capture.outputs.head }}", evaluator["with"]["expected-head"])
            self.assertEqual("${{ steps.capture.outputs.target }}", evaluator["with"]["expected-target"])
            self.assertEqual("${{ steps.capture.outputs.pr }}", evaluator["with"]["pr"])
            reporter = job["steps"][-1]
            self.assertEqual("${{ failure() && steps.capture.outputs.head != '' }}", reporter["if"])
            self.assertEqual("${{ steps.capture.outputs.head }}", reporter["env"]["HEAD"])
            self.assertFalse(any("checkout" in step.get("uses", "") for step in job["steps"]))
        for index in (0, -1):
            self.assertEqual(
                caller["jobs"]["two-human-reviewers"]["steps"][index],
                reusable["jobs"]["two-human-reviewers"]["steps"][index],
            )
        self.assertIn("workflow_call", reusable["on"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
