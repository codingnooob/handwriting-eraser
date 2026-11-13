#!/usr/bin/env python3
"""Plan releases from conventional commits since the last published tag.

Breaking changes increment the major version; features, fixes, performance
changes, and explicit `release:` commits increment the minor version. All
other commits keep the current version and do not produce a package.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass

SEMVER = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SUBJECT = re.compile(r"^(?P<kind>[a-z][a-z0-9-]*)(?:\([^()\n]+\))?(?P<breaking>!)?:", re.IGNORECASE)
BREAKING_FOOTER = re.compile(r"^\s*BREAKING(?:[ -]CHANGE):\s*\S", re.IGNORECASE | re.MULTILINE)
MINOR_KINDS = {"feat", "fix", "perf", "release"}
PRIORITY = {"none": 0, "minor": 1, "major": 2}


@dataclass(frozen=True)
class ReleasePlan:
    tag: str
    change: str
    should_release: bool

    @property
    def version(self) -> str:
        return self.tag[1:]


def classify_commit(message: str) -> str:
    """Classify one complete commit message, including breaking-change footers."""
    if BREAKING_FOOTER.search(message):
        return "major"
    first_line = message.strip().split("\n", 1)[0]
    match = SUBJECT.match(first_line)
    if not match:
        return "none"
    if match.group("breaking"):
        return "major"
    return "minor" if match.group("kind").lower() in MINOR_KINDS else "none"


def plan_release(previous_tag: str | None, messages: list[str]) -> ReleasePlan:
    if not previous_tag:
        return ReleasePlan("v1.0.0", "initial", True)
    match = SEMVER.fullmatch(previous_tag)
    if not match:
        raise ValueError(f"Latest published release tag is not a numeric semantic version: {previous_tag!r}")
    major, minor, _patch = map(int, match.groups())
    change = max((classify_commit(message) for message in messages), key=PRIORITY.get, default="none")
    if change == "major":
        return ReleasePlan(f"v{major + 1}.0.0", change, True)
    if change == "minor":
        return ReleasePlan(f"v{major}.{minor + 1}.0", change, True)
    return ReleasePlan(previous_tag, change, False)


def commits_since(previous_tag: str, head: str) -> list[str]:
    result = subprocess.run(["git", "merge-base", "--is-ancestor", previous_tag, head], check=False)
    if result.returncode != 0:
        raise ValueError(f"The latest release {previous_tag} is not an ancestor of {head}; refusing a stale release.")
    data = subprocess.check_output(["git", "log", "--format=%B%x00", f"{previous_tag}..{head}"])
    return [part.decode("utf-8", "replace").strip() for part in data.split(b"\x00") if part.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--last-tag", default="", help="Latest published stable release tag, or empty for the first release")
    parser.add_argument("--head", default="HEAD", help="Commit being evaluated")
    parser.add_argument("--github-output", help="Append step outputs to this GitHub Actions output file")
    args = parser.parse_args()
    try:
        if args.last_tag and not SEMVER.fullmatch(args.last_tag):
            raise ValueError(f"Latest published release tag is not a numeric semantic version: {args.last_tag!r}")
        messages = commits_since(args.last_tag, args.head) if args.last_tag else []
        plan = plan_release(args.last_tag or None, messages)
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Cannot plan release: {error}", file=sys.stderr)
        return 1

    result = {"tag": plan.tag, "version": plan.version, "change": plan.change, "should_release": plan.should_release}
    print(json.dumps(result, sort_keys=True))
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as output:
            for key, value in result.items():
                if isinstance(value, bool):
                    value = str(value).lower()
                output.write(f"{key}={value}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
