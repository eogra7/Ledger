#!/usr/bin/env python3
"""Versioning for Ledger, from Conventional Commits.

  release.py alpha            next alpha after a merge to main, if anything releasable changed
  release.py promote [TAG]    turn an alpha (default: the newest) into a release
  release.py preview          changelog only (test builds)

Writes CHANGELOG.md and, on GitHub Actions, the outputs `release` (true/false) and `tag`.

Versions follow SemVer from the commits since the last release (vX.Y.Z):
  a breaking change (`feat!:` or a `BREAKING CHANGE:` footer) bumps major,
  `feat` bumps minor, `fix` and `perf` bump patch. Other types (docs, ci, test,
  refactor, style, build, chore) don't make a release on their own.
Alphas are vX.Y.Z-alpha.N with N counting up for the same X.Y.Z.
"""
import os
import re
import subprocess
import sys

TYPES = ["feat", "fix", "perf", "docs", "ci", "test", "refactor", "style", "build", "chore", "revert"]
HEADER = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?(?P<bang>!)?: (?P<desc>.+)$")
STABLE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
ALPHA = re.compile(r"^v(\d+)\.(\d+)\.(\d+)-alpha\.(\d+)$")
SECTIONS = [("breaking", "Breaking changes"), ("feat", "Features"), ("fix", "Bug fixes"), ("perf", "Performance"),
            ("other", "Other changes")]


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def tags(pattern):
    out = []
    for t in git("tag", "--list", "v*").splitlines():
        m = pattern.match(t)
        if m:
            out.append((tuple(int(x) for x in m.groups()), t))
    return sorted(out)


def last_stable():
    s = tags(STABLE)
    return s[-1] if s else ((0, 0, 0), None)


def commits(since, until="HEAD"):
    """[(sha, subject, body)] after `since` up to `until`, oldest first."""
    rng = f"{since}..{until}" if since else until
    raw = git("log", "--reverse", "--format=%H%x1f%s%x1f%b%x1e", rng)
    out = []
    for rec in raw.split("\x1e"):
        rec = rec.strip()
        if rec:
            sha, subject, body = (rec.split("\x1f") + ["", ""])[:3]
            out.append((sha, subject, body))
    return out


def parse(subject, body):
    m = HEADER.match(subject)
    if not m or m["type"] not in TYPES:
        return None
    breaking = bool(m["bang"]) or "BREAKING CHANGE:" in body or "BREAKING-CHANGE:" in body
    return {"type": m["type"], "scope": m["scope"], "desc": m["desc"], "breaking": breaking}


def bump_level(cs):
    level = 0  # 0 none, 1 patch, 2 minor, 3 major
    for _, s, b in cs:
        c = parse(s, b)
        if not c:
            continue
        if c["breaking"]:
            level = max(level, 3)
        elif c["type"] == "feat":
            level = max(level, 2)
        elif c["type"] in ("fix", "perf"):
            level = max(level, 1)
    return level


def bump(v, level):
    major, minor, patch = v
    if level == 3:
        return (major + 1, 0, 0)
    if level == 2:
        return (major, minor + 1, 0)
    return (major, minor, patch + 1)


def changelog(title, cs):
    groups = {k: [] for k, _ in SECTIONS}
    for sha, s, b in cs:
        c = parse(s, b)
        if not c:
            groups["other"].append(f"{s} ({sha[:7]})")
            continue
        line = (f"**{c['scope']}:** " if c["scope"] else "") + c["desc"] + f" ({sha[:7]})"
        if c["breaking"]:
            groups["breaking"].append(line)
        if c["type"] in groups:
            groups[c["type"]].append(line)
        elif not c["breaking"]:
            groups["other"].append(f"{c['type']}: {line}")
    out = [f"# {title}", ""]
    for key, name in SECTIONS:
        if groups[key]:
            out += [f"## {name}", ""] + [f"- {x}" for x in groups[key]] + [""]
    if len(out) == 2:
        out += ["No changes.", ""]
    return "\n".join(out)


def output(**kw):
    path = os.environ.get("GITHUB_OUTPUT")
    for k, v in kw.items():
        print(f"{k}={v}")
        if path:
            with open(path, "a") as f:
                f.write(f"{k}={v}\n")


def write_changelog(text):
    with open("CHANGELOG.md", "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def cmd_alpha():
    stable_v, stable_tag = last_stable()
    since_stable = commits(stable_tag)
    level = bump_level(since_stable)
    if level == 0:
        write_changelog(changelog("Unreleased", since_stable))
        return output(release="false", tag="")
    target = bump(stable_v, level)
    alphas = [(v, t) for v, t in tags(ALPHA) if v[:3] == target]
    # only cut a new alpha if something releasable landed since the previous one
    if alphas and bump_level(commits(alphas[-1][1])) == 0:
        write_changelog(changelog("Unreleased", since_stable))
        return output(release="false", tag="")
    n = alphas[-1][0][3] + 1 if alphas else 1
    tag = "v%d.%d.%d-alpha.%d" % (target + (n,))
    write_changelog(changelog(f"Ledger {tag} (alpha)", since_stable))
    output(release="true", tag=tag)


def cmd_promote(alpha_tag=None):
    alphas = tags(ALPHA)
    if alpha_tag:
        m = ALPHA.match(alpha_tag)
        if not m or alpha_tag not in [t for _, t in alphas]:
            sys.exit(f"{alpha_tag} is not an alpha tag of this repo")
    elif alphas:
        alpha_tag = alphas[-1][1]
    else:
        sys.exit("no alpha to promote")
    tag = alpha_tag.split("-alpha.")[0]
    if tag in git("tag", "--list", tag).splitlines():
        sys.exit(f"{tag} is already released")
    _, stable_tag = last_stable()
    write_changelog(changelog(f"Ledger {tag}", commits(stable_tag, alpha_tag)))
    output(release="true", tag=tag, sha=git("rev-list", "-n", "1", alpha_tag))


def cmd_preview():
    _, stable_tag = last_stable()
    write_changelog(changelog("Unreleased", commits(stable_tag)))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "alpha":
        cmd_alpha()
    elif cmd == "promote":
        cmd_promote(sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None)
    elif cmd == "preview":
        cmd_preview()
    else:
        sys.exit(__doc__)
