#!/usr/bin/env python3
"""Report incoming V+ and Moonlight commits without merging or rewriting history."""

import argparse
from pathlib import Path
import re
import subprocess
import sys

UPSTREAMS = {
    "upstream": "https://github.com/qiin2333/moonlight-qt.git",
    "moonlight": "https://github.com/moonlight-stream/moonlight-qt.git",
}


def git(repo, *args):
    return subprocess.check_output(
        ["git", *args], cwd=repo, text=True, encoding="utf-8"
    ).strip()


def canonical_url(url):
    return re.sub(r"^(https://|git@)", "", url).replace(":", "/").removesuffix(".git").rstrip("/")


def configure_remotes(repo):
    existing = git(repo, "remote").splitlines()
    # Validate existing names before modifying or fetching any remote.
    for name, url in UPSTREAMS.items():
        if name in existing and canonical_url(git(repo, "remote", "get-url", name)) != canonical_url(url):
            raise ValueError(f"Remote {name} points elsewhere. Rename it before configuring both upstreams.")
    for name, url in UPSTREAMS.items():
        if name not in existing:
            git(repo, "remote", "add", name, url)
        git(repo, "remote", "set-url", "--push", name, "DISABLED")


def skip_reasons(path):
    if not path.exists():
        return {}
    return dict(
        line.split(maxsplit=1)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    )


def collect(repo, base, skipped):
    git(repo, "rev-parse", "--verify", base + "^{commit}")
    applied = set(re.findall(
        r"cherry picked from commit ([0-9a-f]{40})",
        git(repo, "log", base, "--format=%B"),
    ))
    refs = git(repo, "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes/origin").splitlines()
    inflight = set(re.findall(
        r"cherry picked from commit ([0-9a-f]{40})",
        git(repo, "log", *refs, "--not", base, "--format=%B") if refs else "",
    ))
    reports = []
    for remote in UPSTREAMS:
        target = f"refs/remotes/{remote}/master"
        git(repo, "rev-parse", "--verify", target + "^{commit}")
        ahead, behind = map(int, git(repo, "rev-list", "--left-right", "--count", f"{base}...{target}").split())
        commits = []
        for line in git(repo, "log", "--no-merges", "--format=%H %s", f"{base}..{target}").splitlines():
            sha, subject = line.split(" ", 1)
            reason = next((text for prefix, text in skipped.items() if sha.startswith(prefix)), None)
            status = "applied" if sha in applied else "in progress" if sha in inflight else "reviewed" if reason else "pending"
            commits.append({"sha": sha, "subject": subject, "status": status, "reason": reason})
        reports.append({"remote": remote, "ahead": ahead, "behind": behind, "commits": commits})
    return reports


def render(reports):
    lines = ["# Upstream status", "", "Both upstreams are checked independently. No changes are merged automatically.", ""]
    pending = set()
    for report in reports:
        name = report["remote"]
        lines.extend([
            f"## {name}/master",
            "",
            f"Source: {UPSTREAMS[name]}",
            f"Graph comparison: {report['ahead']} local-only commits, {report['behind']} upstream-only commits.",
            "",
        ])
        if not report["commits"]:
            lines.append("No incoming non-merge commits.")
        for commit in report["commits"]:
            status = commit["status"]
            if status == "pending":
                pending.add(commit["sha"])
            lines.append(f"- [{status}] {commit['sha'][:12]} {commit['subject']}")
            if commit["reason"]:
                lines.append(f"  Decision: {commit['reason']}")
        lines.append("")
    lines.append(f"Unique pending commits across both upstreams: {len(pending)}.")
    lines.append("See docs/upstream-sync.md for review and integration instructions.")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-fetch", action="store_true", help="Use existing remote refs without network requests or configuration changes")
    parser.add_argument("--base", default="HEAD", help="Local comparison ref (default: HEAD)")
    parser.add_argument("--output", type=Path, help="Also save the Markdown report")
    args = parser.parse_args()
    repo = Path(git(Path.cwd(), "rev-parse", "--show-toplevel"))
    if not args.no_fetch:
        configure_remotes(repo)
        for remote in UPSTREAMS:
            git(repo, "fetch", "--quiet", remote, "+refs/heads/master:refs/remotes/" + remote + "/master")
    report = render(collect(repo, args.base, skip_reasons(repo / "scripts/upstream-skip.txt")))
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    print(report, end="")


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Upstream check failed: {error}", file=sys.stderr)
        sys.exit(1)
