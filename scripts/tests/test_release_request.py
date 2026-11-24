import base64
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_request as rr

REQUEST_SHA = "a" * 40
MASTER_SHA = "b" * 40
TAG = "v0.1.18"


class ContractTests(unittest.TestCase):
    def setup_case(self, mode="dry-run"):
        self.writes = []
        repo = {"full_name": rr.REPO}
        identity = {"id": rr.OWNER_ID}
        self.event = {"repository": {**repo, "default_branch": "master"}, "workflow_run": {
            "conclusion": "success", "head_repository": repo, "head_branch": rr.BRANCH,
            "event": "push", "actor": identity.copy(), "triggering_actor": identity.copy(),
            "workflow_id": 20, "head_sha": REQUEST_SHA,
        }}
        request = json.dumps({"mode": mode, "tag": TAG, "commit": MASTER_SHA}).encode()
        self.ci_run = {"head_sha": MASTER_SHA, "head_branch": "master", "head_repository": repo,
                       "conclusion": "success", "event": "push", "id": 42}
        self.responses = {
            "actions/workflows/release-request-signal.yml": {"path": rr.SIGNAL, "id": 20},
            f"git/ref/heads/{rr.BRANCH}": {"object": {"sha": REQUEST_SHA}},
            f"commits/{REQUEST_SHA}": {"parents": [{}], "files": [{"filename": rr.REQUEST, "status": "modified"}]},
            f"contents/{rr.REQUEST}": {"type": "file", "encoding": "base64", "size": len(request),
                                       "content": base64.b64encode(request).decode()},
            "git/ref/heads/master": {"object": {"sha": MASTER_SHA}},
            "actions/workflows/verify.yml": {"path": ".github/workflows/verify.yml", "id": 21},
            "actions/workflows/21/runs": {"workflow_runs": [self.ci_run]},
            "releases/latest": {"tag_name": "v0.1.17"},
            "git/matching-refs/tags/v": [{"ref": "refs/tags/v0.1.17"}],
            f"git/ref/tags/{TAG}": None,
            f"releases/tags/{TAG}": None,
        }

    def api(self, path, payload=None, *, missing=False):
        if payload is not None:
            self.writes.append((path, payload))
            return None
        return self.responses[path.split("?")[0]]

    def reject(self, pattern, *, publish=False):
        with self.assertRaisesRegex(ValueError, pattern):
            rr.process(self.event, self.api, publish_step=publish)
        self.assertEqual(self.writes, [])

    def test_dry_run_reads_only_and_cannot_enter_publisher(self):
        self.setup_case()
        self.assertEqual(rr.process(self.event, self.api), ("dry-run", f"dry-run: {TAG}, {MASTER_SHA}, CI run 42"))
        self.assertEqual(self.writes, [])
        self.reject("dry-run cannot", publish=True)

    def test_publish_connects_tag_to_exact_sha_before_dispatch(self):
        self.setup_case("publish")
        self.assertEqual(rr.process(self.event, self.api)[0], "publish")
        self.assertEqual(self.writes, [])
        rr.process(self.event, self.api, publish_step=True)
        self.assertEqual(self.writes, [
            ("git/refs", {"ref": f"refs/tags/{TAG}", "sha": MASTER_SHA}),
            ("actions/workflows/release.yml/dispatches", {"ref": "master", "inputs": {"tag": TAG, "commit": MASTER_SHA}}),
        ])

    def test_fork_wrong_actor_and_wrong_workflow_fail_closed(self):
        for key, value in (("actor", {"id": 1}), ("triggering_actor", {"id": 1}),
                           ("workflow_id", 1), ("head_repository", {"full_name": "fork/lan-kuang"})):
            with self.subTest(key=key):
                self.setup_case("publish")
                self.event["workflow_run"][key] = value
                self.reject("unexpected|not from an authorized", publish=True)

    def test_extra_file_and_superseded_request_fail(self):
        self.setup_case("publish")
        self.responses[f"commits/{REQUEST_SHA}"]["files"].append({"filename": "App/main.swift", "status": "modified"})
        self.reject("modify only", publish=True)
        self.setup_case("publish")
        self.responses[f"git/ref/heads/{rr.BRANCH}"]["object"]["sha"] = "c" * 40
        self.reject("no longer branch tip", publish=True)

    def test_wrong_or_cancelled_ci_and_stale_master_fail(self):
        for key, value in (("head_sha", "c" * 40), ("conclusion", "cancelled"), ("event", "pull_request")):
            with self.subTest(key=key):
                self.setup_case("publish")
                self.ci_run[key] = value
                self.reject("no successful", publish=True)
        self.setup_case("publish")
        self.responses["git/ref/heads/master"]["object"]["sha"] = "c" * 40
        self.reject("current master tip", publish=True)

    def test_duplicate_release_and_pending_newer_tag_fail(self):
        self.setup_case("publish")
        self.responses[f"releases/tags/{TAG}"] = {}
        self.reject("release already exists", publish=True)
        self.setup_case("publish")
        self.responses["git/matching-refs/tags/v"].append({"ref": "refs/tags/v0.1.20"})
        self.reject("awaiting publication", publish=True)
        self.setup_case("publish")
        self.responses[f"git/ref/tags/{TAG}"] = {"ref": f"refs/tags/{TAG}"}
        self.reject("tag already exists", publish=True)

    def test_malformed_request_fails_closed(self):
        for invalid in (b"[]", b'{"mode":"dry-run","mode":"publish"}',
                        b'{"mode":"publish","tag":"v01.2.3","commit":"bad"}',
                        b'{"mode":"publish","tag":"v1.2.3","commit":"bad"}',
                        b'{"mode":"publish; echo fail","tag":"v1.2.3","commit":"bad"}', b" " * 513):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    rr.parse(invalid)


if __name__ == "__main__":
    unittest.main()
