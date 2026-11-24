#!/usr/bin/env python3
"""Validate the branch-based, owner-only release request. Never run request-branch code."""
import base64
import json
import os
import re
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

REPO = "allen-bot-ctl/EasyLens"
OWNER_ID = 352863755
BRANCH = "release-requests"
SIGNAL = ".github/workflows/release-request-signal.yml"
REQUEST = ".github/release-request.json"
VERSION = re.compile(r"v(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})")
SHA = re.compile(r"[a-f0-9]{40}")


def need(ok, msg):
    if not ok:
        raise ValueError(msg)


def parse(raw):
    def unique(pairs):
        obj = dict(pairs)
        need(len(pairs) == len(obj), "duplicate request keys")
        return obj
    need(len(raw) <= 512, "request exceeds length bound")
    data = json.loads(raw, object_pairs_hook=unique)
    need(type(data) is dict and set(data) == {"mode", "tag", "commit"}, "invalid request fields")
    mode, tag, commit = (data[k] for k in ("mode", "tag", "commit"))
    need(mode in ("dry-run", "publish"), "invalid request mode")
    need(type(tag) is str and VERSION.fullmatch(tag), "invalid stable tag")
    need(type(commit) is str and SHA.fullmatch(commit), "invalid candidate SHA")
    return mode, tag, commit


class API:
    def __call__(self, path, payload=None, *, missing=False):
        req = Request("https://api.github.com/repos/" + REPO + "/" + path,
                      json.dumps(payload).encode() if payload is not None else None,
                      {"Authorization": "Bearer " + os.environ["GH_TOKEN"],
                       "Accept": "application/vnd.github+json",
                       "Content-Type": "application/json",
                       "X-GitHub-Api-Version": "2022-11-28"})
        try:
            with urlopen(req, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else None
        except HTTPError as e:
            if missing and e.code == 404:
                return None
            raise ValueError(f"GitHub {req.method} {path.partition('?')[0]} returned HTTP {e.code}") from None


def version(tag):
    return tuple(int(p) for p in VERSION.fullmatch(tag).groups())


def process(event, api, *, publish_step=False):
    need(event["repository"]["full_name"] == REPO, "unexpected repository")
    default = event["repository"]["default_branch"]
    need(default == "master", "unexpected default branch")
    run = event["workflow_run"]
    need(run["head_repository"]["full_name"] == REPO and run["head_branch"] == BRANCH
         and run["event"] == "push" and run["conclusion"] == "success"
         and run["actor"]["id"] == OWNER_ID and run["triggering_actor"]["id"] == OWNER_ID,
         "signal not from an authorized request push")
    signal = api("actions/workflows/release-request-signal.yml")
    need(signal["path"] == SIGNAL and signal["id"] == run["workflow_id"],
         "unexpected signal workflow identity")
    sha = run["head_sha"]
    need(type(sha) is str and SHA.fullmatch(sha), "invalid request SHA")
    need(api(f"git/ref/heads/{BRANCH}")["object"]["sha"] == sha, "request is no longer branch tip")
    commit_info = api(f"commits/{sha}?per_page=100")
    need(len(commit_info["parents"]) == 1 and
         [(f["filename"], f["status"]) for f in commit_info["files"]] == [(REQUEST, "modified")],
         "request commit must modify only the pre-existing request file")
    entry = api(f"contents/{REQUEST}?ref={sha}")
    need(entry["type"] == "file" and entry["encoding"] == "base64" and entry["size"] <= 512,
         "invalid request file")
    mode, tag, candidate = parse(base64.b64decode(entry["content"]))
    master = api(f"git/ref/heads/{default}")["object"]["sha"]
    need(candidate == master, "candidate must still be the current master tip")
    ci = api("actions/workflows/verify.yml")
    need(ci["path"] == ".github/workflows/verify.yml", "unexpected CI workflow path")
    query = urlencode({"head_sha":candidate,"branch":default,"status":"success","per_page":100})
    ok = [r for r in api(f"actions/workflows/{ci['id']}/runs?{query}")["workflow_runs"]
          if r["head_sha"] == candidate and r["head_branch"] == default
          and r["head_repository"]["full_name"] == REPO and r["conclusion"] == "success"
          and r["event"] in ("push", "workflow_dispatch")]
    need(ok, "no successful exact-SHA CI run on master")
    latest = api("releases/latest")
    need(VERSION.fullmatch(latest["tag_name"]) and version(tag) > version(latest["tag_name"]),
         "candidate version must be above latest stable")
    for ref in api("git/matching-refs/tags/v"):
        other = ref["ref"].removeprefix("refs/tags/")
        if VERSION.fullmatch(other):
            need(version(other) <= version(latest["tag_name"]),
                 "a newer stable tag is already awaiting publication")
    need(api(f"git/ref/tags/{tag}", missing=True) is None, "tag already exists; refusing to overwrite")
    need(api(f"releases/tags/{tag}", missing=True) is None, "release already exists")
    detail = f"{mode}: {tag}, {candidate}, CI run {ok[0]['id']}"
    if publish_step:
        need(mode == "publish", "dry-run cannot enter publish step")
        api("git/refs", {"ref": f"refs/tags/{tag}", "sha": candidate})
        try:
            dispatch = api("actions/workflows/release.yml/dispatches",
                           {"ref": default, "inputs": {"tag": tag, "commit": candidate}})
        except ValueError:
            raise ValueError(f"{tag} created at {candidate}; dispatch response failed. Check existing Release runs before manual recovery; do not move the tag.") from None
        detail += f"; tag created, Release dispatch accepted; verify completion separately: {dispatch or 'no run ID returned'}"
    return mode, detail


def main():
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as f:
        try:
            mode, detail = process(json.load(f), API(), publish_step="--publish" in sys.argv[1:])
        except (ValueError, KeyError, TypeError) as e:
            sys.exit(f"Release request rejected: {e}")
    print(detail)
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
            print(f"mode={mode}", file=f)


if __name__ == "__main__":
    main()
