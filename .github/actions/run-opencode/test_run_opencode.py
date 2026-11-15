#!/usr/bin/env python3
"""Tests for run_opencode.py. Run with: python3 -m unittest discover -s .github/actions/run-opencode"""

import fnmatch
import json
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import run_opencode

WORKFLOWS = Path(__file__).resolve().parents[2] / "workflows"


def make_event(name: str, payload: dict) -> run_opencode.Event:
    folder = Path(tempfile.mkdtemp())
    path = folder / "event.json"
    path.write_text(json.dumps({"repository": {"default_branch": "main"}, **payload}))
    env = {
        "GITHUB_EVENT_NAME": name,
        "GITHUB_EVENT_PATH": str(path),
        "GITHUB_REPOSITORY": "octo/repo",
        "GITHUB_ACTOR": "octocat",
        "GITHUB_RUN_ID": "42",
    }
    with mock.patch.dict(os.environ, env):
        return run_opencode.Event()


def comment_event(body: str, pr: bool = False) -> run_opencode.Event:
    issue = {"number": 7, **({"pull_request": {}} if pr else {})}
    return make_event("issue_comment", {"issue": issue, "comment": {"id": 99, "body": body}})


class UserPromptTest(unittest.TestCase):
    def prompt(self, event: run_opencode.Event, custom: str = "") -> str:
        with mock.patch.dict(os.environ, {"PROMPT": custom}):
            return run_opencode.user_prompt(event)

    def test_custom_prompt_wins(self):
        self.assertEqual(self.prompt(comment_event("/oc hi"), custom="Do the task"), "Do the task")

    def test_bare_mention_summarizes(self):
        self.assertEqual(self.prompt(comment_event("/oc")), "Summarize this thread")
        self.assertEqual(self.prompt(comment_event("/OpenCode")), "Summarize this thread")

    def test_mention_with_request_passes_the_comment(self):
        self.assertEqual(self.prompt(comment_event("please /oc fix it")), "please /oc fix it")

    def test_comment_without_mention_fails(self):
        with self.assertRaises(RuntimeError):
            self.prompt(comment_event("/occasionally"))

    def test_issues_event_needs_a_prompt(self):
        event = make_event("issues", {"issue": {"number": 3}})
        with self.assertRaises(RuntimeError):
            self.prompt(event)

    def test_pull_request_defaults_to_review(self):
        event = make_event("pull_request", {"pull_request": {"number": 5}})
        self.assertTrue(event.is_pr)
        self.assertEqual(self.prompt(event), "Review this pull request")

    def test_review_comment_includes_the_diff_hunk(self):
        event = make_event("pull_request_review_comment", {
            "pull_request": {"number": 5},
            "comment": {"id": 1, "body": "/oc why?", "path": "a.py", "line": 3, "diff_hunk": "@@ -1 +1 @@"},
        })
        prompt = self.prompt(event)
        self.assertIn('file "a.py" at line 3', prompt)
        self.assertIn("@@ -1 +1 @@", prompt)


class EventTest(unittest.TestCase):
    def test_issue_comment_on_a_pull_request_is_a_pr(self):
        self.assertTrue(comment_event("/oc", pr=True).is_pr)
        self.assertFalse(comment_event("/oc").is_pr)

    def test_unsupported_event_fails(self):
        with self.assertRaises(RuntimeError):
            make_event("push", {})


class ContextTest(unittest.TestCase):
    def test_issue_context_skips_the_triggering_comment(self):
        issue = {
            "title": "T", "body": "B", "createdAt": "now", "state": "OPEN", "author": {"login": "a"},
            "comments": {"nodes": [
                {"databaseId": 99, "body": "/oc do it", "createdAt": "now", "author": {"login": "a"}},
                {"databaseId": 100, "body": "earlier note", "createdAt": "now", "author": {"login": "b"}},
            ]},
        }
        context = run_opencode.issue_context(issue, skip_comment=99)
        self.assertIn("earlier note", context)
        self.assertNotIn("/oc do it", context)


class ForkTest(unittest.TestCase):
    def test_fork_pull_requests_are_refused_before_checkout(self):
        pr = {"headRepository": {"nameWithOwner": "fork/repo"}, "baseRepository": {"nameWithOwner": "octo/repo"}}
        graphql = json.dumps({"data": {"repository": {"pullRequest": pr}}})
        calls = []

        def fake_run(*args, check=True):
            calls.append(args)
            return graphql

        with mock.patch.object(run_opencode, "run", fake_run), mock.patch.object(run_opencode, "chat") as chat:
            response = run_opencode.handle_pr(comment_event("/oc fix", pr=True), "fix", [], 99)
        self.assertIn("forks", response)
        chat.assert_not_called()
        self.assertEqual([c[:3] for c in calls], [("gh", "api", "graphql")])


class FakeOpencodeTest(unittest.TestCase):
    """Runs opencode() against a stand-in executable that prints a JSON event stream."""

    def run_with(self, events: list[dict], exit_code: int = 0, message: str = "hello") -> tuple[str, str]:
        folder = Path(tempfile.mkdtemp())
        script = folder / "opencode"
        lines = "\n".join(json.dumps(e) for e in events)
        read_stdin = "cat > /dev/null\n" if exit_code == 0 else ""
        script.write_text(f"#!/bin/sh\n{read_stdin}cat <<'EOF'\n{lines}\nEOF\nexit {exit_code}\n")
        script.chmod(script.stat().st_mode | stat.S_IEXEC)
        env = {"PATH": f"{folder}{os.pathsep}{os.environ['PATH']}", "MODEL": "opencode/test"}
        with mock.patch.dict(os.environ, env):
            return run_opencode.opencode(message)

    def test_agent_sees_neither_the_push_credential_nor_github_tokens(self):
        repo = Path(tempfile.mkdtemp())
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "config", "--local", run_opencode.CREDENTIAL, "secret"], check=True)
        folder = Path(tempfile.mkdtemp())
        script = folder / "opencode"
        script.write_text(
            "#!/bin/sh\ncat > /dev/null\n"
            f"cred=$(git config --local --get {run_opencode.CREDENTIAL})\n"
            'printf \'{"type": "text", "part": {"text": "cred=%s token=%s"}}\\n\' "$cred" "${GH_TOKEN:-none}"\n'
        )
        script.chmod(script.stat().st_mode | stat.S_IEXEC)
        env = {"PATH": f"{folder}{os.pathsep}{os.environ['PATH']}", "MODEL": "opencode/test", "GH_TOKEN": "ghs_x"}
        cwd = os.getcwd()
        try:
            os.chdir(repo)
            with mock.patch.dict(os.environ, env):
                _, reply = run_opencode.opencode("hello")
            restored = run_opencode.run("git", "config", "--local", "--get", run_opencode.CREDENTIAL)
        finally:
            os.chdir(cwd)
        self.assertEqual(reply, "cred= token=none")
        self.assertEqual(restored, "secret")

    def test_returns_the_final_text(self):
        session, reply = self.run_with([
            {"type": "tool_use", "sessionID": "s1", "part": {"tool": "read", "state": {"status": "completed"}}},
            {"type": "text", "sessionID": "s1", "part": {"text": "All done."}},
        ])
        self.assertEqual((session, reply), ("s1", "All done."))

    def test_events_without_a_type_are_ignored(self):
        _, reply = self.run_with([{"sessionID": "s1"}, {"type": "text", "part": {"text": "ok"}}])
        self.assertEqual(reply, "ok")

    def test_reply_is_empty_when_a_tool_call_comes_last(self):
        _, reply = self.run_with([
            {"type": "text", "sessionID": "s1", "part": {"text": "Working on it"}},
            {"type": "tool_use", "sessionID": "s1", "part": {"tool": "edit", "state": {"status": "completed"}}},
        ])
        self.assertEqual(reply, "")

    def test_error_event_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Model unavailable"):
            self.run_with([{"type": "error", "error": {"message": "Model unavailable: x"}}], exit_code=1)

    def test_exit_before_reading_the_message_is_reported(self):
        with self.assertRaisesRegex(RuntimeError, "exit code 2"):
            self.run_with([], exit_code=2, message="x" * 2_000_000)

    def test_nonzero_exit_fails(self):
        with self.assertRaisesRegex(RuntimeError, "exit code 3"):
            self.run_with([], exit_code=3)


class MainTest(unittest.TestCase):
    def test_unexpected_errors_are_reported_on_github(self):
        event = comment_event("/oc fix")
        with mock.patch.object(run_opencode, "Event", return_value=event), \
                mock.patch.object(run_opencode, "assert_permission", side_effect=KeyError("type")), \
                mock.patch.object(run_opencode, "comment") as comment:
            self.assertEqual(run_opencode.main(), 1)
        comment.assert_called_once()
        self.assertIn("type", comment.call_args.args[1])


class CommentTest(unittest.TestCase):
    def test_long_bodies_are_truncated_to_the_github_limit(self):
        event = comment_event("/oc")
        with mock.patch.object(run_opencode.subprocess, "run") as gh:
            gh.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")
            run_opencode.comment(event, "x" * 100_000)
        body = json.loads(gh.call_args.kwargs["input"])["body"]
        self.assertLessEqual(len(body), run_opencode.COMMENT_LIMIT)
        self.assertIn("(truncated)", body)
        self.assertTrue(body.endswith(event.footer()))


def workflow_rules(name: str) -> list[dict]:
    """Read the folded OPENCODE_CONFIG_CONTENT block from a workflow without a YAML parser."""
    text = (WORKFLOWS / name).read_text()
    block = re.search(r"OPENCODE_CONFIG_CONTENT: >-\n((?: {8}.*\n)+)", text).group(1)
    return json.loads(" ".join(line.strip() for line in block.splitlines()))["permissions"]


def effect(rules: list[dict], action: str, resource: str) -> str:
    """OpenCode's rule order: the base policy allows everything, the last matching rule wins,
    and a pattern ending in " *" also matches the command without arguments."""
    result = "allow"
    for rule in rules:
        patterns = [rule["resource"]]
        if rule["resource"].endswith(" *"):
            patterns.append(rule["resource"][:-2])
        if fnmatch.fnmatchcase(action, rule["action"]) and any(fnmatch.fnmatchcase(resource, p) for p in patterns):
            result = rule["effect"]
    return result


class WorkflowPermissionTest(unittest.TestCase):
    AGENT = ("opencode.yml", "agent-task.yml")

    def test_every_workflow_denies_escape_hatches(self):
        for name in (*self.AGENT, "opencode-review.yml"):
            rules = workflow_rules(name)
            for action in ("webfetch", "websearch", "subagent", "execute", "question", "external_directory"):
                self.assertEqual(effect(rules, action, "anything"), "deny", f"{name}: {action}")
            self.assertEqual(effect(rules, "shell", "curl https://example.com"), "deny", name)
            self.assertEqual(effect(rules, "shell", "git diff origin/main...HEAD"), "allow", name)
            self.assertEqual(effect(rules, "shell", "git diff --no-index .git/config /dev/null"), "deny", name)
            self.assertEqual(effect(rules, "shell", "git log --output=/tmp/x"), "deny", name)
            self.assertEqual(effect(rules, "shell", "git push origin HEAD"), "deny", name)
            self.assertEqual(effect(rules, "shell", "git log -1 > \"$GITHUB_ENV\""), "deny", name)

    def test_agents_may_run_the_project_checks(self):
        for name in self.AGENT:
            rules = workflow_rules(name)
            for command in ("make lint", "make test", "make build", "make check", "git status"):
                self.assertEqual(effect(rules, "shell", command), "allow", f"{name}: {command}")
            self.assertEqual(effect(rules, "edit", "src/main.py"), "allow", name)

    def test_review_is_read_only(self):
        rules = workflow_rules("opencode-review.yml")
        self.assertEqual(effect(rules, "edit", "src/main.py"), "deny")
        self.assertEqual(effect(rules, "shell", "make test"), "deny")

    def test_read_only_config_denies_changes(self):
        rules = json.loads(run_opencode.READ_ONLY)["permissions"]
        for action in ("edit", "shell", "execute", "external_directory"):
            self.assertEqual(effect(rules, action, "anything"), "deny", action)


if __name__ == "__main__":
    unittest.main()
