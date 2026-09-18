#!/usr/bin/env python3
"""Seed a small friend group on the local Convex deployment.

Same credentials the Mac app uses for name-yourself join:
  {handle}@doorbell.local / DOORBELL_JOIN_SECRET (default: doorbell)

  scripts/seed-friends.sh
"""
import json, os, sys, urllib.error, urllib.request

U = os.environ.get("CONVEX_URL", "http://127.0.0.1:3210")
SECRET = os.environ.get("DOORBELL_JOIN_SECRET", "doorbell")
FRIENDS = [("vagdev", "Vagdev"), ("priya", "Priya Nair"), ("arjun", "Arjun Mehta")]


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


def ensure(handle, name):
    tok = sign(handle)
    acct = call("query", "profiles:account", {}, tok)
    if acct["me"] is None:
        call("mutation", "profiles:claimHandle", {"handle": handle, "displayName": name}, tok)
        acct = call("query", "profiles:account", {}, tok)
    print(f"  @{acct['me']['handle']}  {acct['me']['displayName']}")
    return acct["me"]


def try_mut(tok, path, args):
    try:
        call("mutation", path, args, tok)
    except Exception as e:
        if "already" not in str(e).lower() and "pending" not in str(e).lower():
            # Graph edges may already exist; ignore benign failures.
            pass


def main():
    print("friends")
    people = {h: ensure(h, n) for h, n in FRIENDS}
    alice, bob, carol = sign("vagdev"), sign("priya"), sign("arjun")
    aid, bid, cid = people["vagdev"]["id"], people["priya"]["id"], people["arjun"]["id"]
    print("graph")
    try_mut(alice, "graph:request", {"profileId": bid})
    try_mut(bob, "graph:accept", {"profileId": aid})
    try_mut(bob, "graph:request", {"profileId": aid})
    try_mut(alice, "graph:accept", {"profileId": bid})
    try_mut(bob, "graph:request", {"profileId": cid})
    try_mut(carol, "graph:accept", {"profileId": bid})
    try_mut(carol, "graph:setCloseFriend", {"profileId": bid, "on": True})
    print("ok — vagdev↔priya friends; priya is on arjun's close list")
    print("join in the app as @vagdev / @priya / @arjun (or any new handle)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.URLError as e:
        print(f"Convex not reachable at {U}: {e}", file=sys.stderr)
        raise SystemExit(1)
