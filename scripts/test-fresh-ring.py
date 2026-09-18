#!/usr/bin/env python3
"""Smoke-test Fresh Ring: GitHub release feed, checksum asset, bundled installer scripts."""
import json, re, sys, urllib.error, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = "vagdotdev/doorbell"


def fetch(url):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def ok(msg):
    print(f"  ok  {msg}")


def fail(msg):
    print(f"FAIL  {msg}", file=sys.stderr)
    return 1


def main():
    code = 0
    print("→ Fresh Ring release feed")
    try:
        release = fetch(f"https://api.github.com/repos/{REPO}/releases/latest")
    except urllib.error.URLError as e:
        return fail(f"GitHub releases/latest: {e}")
    tag = release.get("tag_name", "")
    if not tag:
        code = fail("missing tag_name")
    else:
        ok(f"latest tag {tag}")
    names = {a["name"] for a in release.get("assets", [])}
    for need in ("Doorbell.dmg", "Doorbell.dmg.sha256"):
        if need not in names:
            code = fail(f"missing asset {need}")
        else:
            ok(f"asset {need}")

    sha_url = f"https://github.com/{REPO}/releases/latest/download/Doorbell.dmg.sha256"
    try:
        with urllib.request.urlopen(sha_url, timeout=20) as r:
            digest = r.read().decode().split()[0]
    except urllib.error.URLError as e:
        code = fail(f"checksum download: {e}")
        digest = ""
    if digest and not re.fullmatch(r"[a-fA-F0-9]{64}", digest):
        code = fail(f"bad checksum format: {digest[:16]}…")
    elif digest:
        ok(f"checksum {digest[:12]}…")

    print("→ bundled Fresh Ring installer")
    for app in (ROOT / "build" / "Doorbell.app", Path("/Applications/Doorbell.app")):
        if not app.is_dir():
            continue
        scripts = app / "Contents/Resources/scripts"
        for name in ("install-dmg.sh", "apply-update.sh"):
            path = scripts / name
            if not path.is_file():
                code = fail(f"missing {app.name} Resources/scripts/{name}")
            elif not (path.stat().st_mode & 0o111):
                code = fail(f"{name} not executable in {app}")
            else:
                ok(f"{app.name} has scripts/{name}")
        version = app / "Contents/Info.plist"
        break
    else:
        print("  skip  no Doorbell.app in build/ or /Applications (build first to verify bundle)")

    print("→ version ordering")
    if not releaseIsNewer("v2026.09.19-1200-abc", "v2026.09.18-2213-def"):
        code = fail("releaseIsNewer ordering")
    else:
        ok("newer tags sort after older ones")

    return code


def releaseIsNewer(remote, local):
    r = remote[1:] if remote.startswith("v") else remote
    l = local[1:] if local.startswith("v") else local
    return r > l  # same date-prefix format as Swift numeric compare for these tags


if __name__ == "__main__":
    raise SystemExit(main())
