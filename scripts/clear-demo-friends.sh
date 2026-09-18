#!/usr/bin/env python3
"""Drop demo seed friendships for @vagdev on the local Convex deployment."""
import json, os, sys, urllib.error, urllib.request
from pathlib import Path

def load_dotenv(path):
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key, val = key.strip(), val.strip().strip("\"'")
        if key and key not in os.environ:
            os.environ[key] = val

root = Path(__file__).resolve().parents[1]
load_dotenv(root / ".env")
load_dotenv(root / ".env.local")
load_dotenv(root / ".env.secrets")

U = os.environ.get("CONVEX_URL", "http://127.0.0.1:3210")
SECRET = os.environ.get("DOORBELL_JOIN_SECRET", "doorbell")
DEMO = ["priya", "arjun"]


def call(kind, path, args, token=None):
    req = urllib.request.Request(
        f"{U}/api/{kind}",
        data=json.dumps({"path": path, "format": "json", "args": args}).encode(),
        headers={
            "content-type": "application/json",
            **({"Authorization": f"Bearer {token}"} if token else {}),
        },
    )
    with urllib.request.urlopen(req) as r:
        body = json.load(r)
    if "errorMessage" in body or body.get("status") == "error":
        raise RuntimeError(body.get("errorMessage") or body)
    return body.get("value")


def sign(handle):
    email = f"{handle}@doorbell.local"
    for flow in ("signIn", "signUp"):
        try:
            return call(
                "action",
                "auth:signIn",
                {"provider": "password", "params": {"email": email, "password": SECRET, "flow": flow}},
            )["tokens"]["token"]
        except Exception:
            continue
    raise RuntimeError(f"could not sign in {handle}")


def main():
    tok = sign("vagdev")
    for handle in DEMO:
        rows = call("query", "profiles:search", {"q": handle}, tok)
        match = next((r for r in rows if r["handle"] == handle), None)
        if not match:
            print(f"  skip @{handle} — not found")
            continue
        try:
            call("mutation", "graph:unfollow", {"profileId": match["id"]}, tok)
            print(f"  removed @{handle}")
        except Exception as e:
            print(f"  @{handle}: {e}")
    print("ok")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.URLError as e:
        print(f"Convex not reachable at {U}: {e}", file=sys.stderr)
        raise SystemExit(1)
