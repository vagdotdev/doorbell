#!/usr/bin/env python3
"""Prepare and audit Focus provisioning. Ad-hoc builds must not claim restricted grants.

Developer ID releases require DOORBELL_PROVISION_PROFILE. Gatekeeper/notarization
remain independent release gates; decoding a profile alone is not release approval.
Apple reference: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
"""
import argparse
import datetime as dt
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_ID = "dev.vag.doorbell"
FOCUS = "com.apple.developer.usernotifications.communication"
MARKER = "DoorbellFocusStatusEnabled"
TEAM = "com.apple.developer.team-identifier"
APPLICATION = "com.apple.application-identifier"


def validate_profile(profile, now=None):
    """Validate the granted capability and distribution scope before signing."""
    now = now or dt.datetime.now(dt.timezone.utc)
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime):
        raise ValueError("Provisioning profile has no valid expiry date.")
    if expiry.replace(tzinfo=expiry.tzinfo or dt.timezone.utc) <= now:
        raise ValueError("Provisioning profile has expired; download a renewed Developer ID profile.")
    created = profile.get("CreationDate")
    if isinstance(created, dt.datetime) and created.replace(tzinfo=created.tzinfo or dt.timezone.utc) > now:
        raise ValueError("Provisioning profile is not valid yet.")
    if "OSX" not in profile.get("Platform", []):
        raise ValueError("Focus needs a macOS provisioning profile.")
    if profile.get("ProvisionsAllDevices") is not True or profile.get("ProvisionedDevices"):
        raise ValueError("Use a Developer ID distribution profile, not a development or App Store profile.")
    grants = profile.get("Entitlements", {})
    if grants.get(FOCUS) is not True:
        raise ValueError("The provisioning profile must enable Communication Notifications for Focus status.")
    if grants.get("get-task-allow") or grants.get("com.apple.security.get-task-allow"):
        raise ValueError("Development debugging entitlements cannot ship in a release.")
    team = grants.get(TEAM)
    if not isinstance(team, str) or not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Provisioning profile has an invalid Team ID.")
    if profile.get("TeamIdentifier") != [team]:
        raise ValueError("Provisioning profile Team ID is inconsistent.")
    app = grants.get(APPLICATION)
    # Restricted capabilities require this explicit app, never a wildcard grant.
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if not any(app == f"{prefix}.{APP_ID}" for prefix in prefixes):
        raise ValueError("Provisioning profile must name the exact dev.vag.doorbell App ID.")
    certificates = profile.get("DeveloperCertificates", [])
    if not certificates or not all(isinstance(cert, bytes) and cert for cert in certificates):
        raise ValueError("Provisioning profile does not contain a signing certificate.")
    return {APPLICATION: app, TEAM: team, FOCUS: True}


def decode_profile(path):
    result = subprocess.run(["/usr/bin/security", "cms", "-D", "-i", str(path)], capture_output=True)
    if result.returncode:
        raise ValueError("Cannot decode provisioning profile; use the original Apple .provisionprofile download.")
    try:
        return plistlib.loads(result.stdout)
    except Exception as error:
        raise ValueError("Provisioning profile payload is not a valid plist.") from error


def prepare(output, signed=False, profile_path=None):
    if signed and not profile_path:
        raise ValueError("Signed builds require DOORBELL_PROVISION_PROFILE: a Developer ID distribution profile for dev.vag.doorbell with Communication Notifications enabled.")
    if not signed and profile_path:
        raise ValueError("A provisioning profile requires DOORBELL_SIGN_IDENTITY; ad-hoc builds cannot enable Focus status.")
    entitlements = plistlib.loads((ROOT / "scripts/Doorbell.entitlements").read_bytes())
    if any(key.startswith("com.apple.developer.") or key == APPLICATION for key in entitlements):
        raise ValueError("Base entitlements contain a restricted grant; ad-hoc builds would fail to launch.")
    if signed:
        entitlements.update(validate_profile(decode_profile(profile_path)))
    output.mkdir(parents=True, exist_ok=True)
    (output / "app.entitlements").write_bytes(plistlib.dumps(entitlements))
    embedded = output / "embedded.provisionprofile"
    if signed:
        shutil.copyfile(profile_path, embedded)
    else:
        embedded.unlink(missing_ok=True)


def verify_app(app):
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    entitlement_data = subprocess.check_output(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL)
    grants = plistlib.loads(entitlement_data)
    if info.get(MARKER) is False:
        if grants.get(FOCUS) or (contents / "embedded.provisionprofile").exists():
            raise ValueError("Focus-disabled builds must not contain restricted Focus grants or a profile.")
        if any(key.startswith("com.apple.developer.") or key == APPLICATION for key in grants):
            raise ValueError("Ad-hoc build contains restricted entitlements.")
        return
    if info.get(MARKER) is not True:
        raise ValueError("App is missing its explicit Focus capability marker.")
    profile_path = contents / "embedded.provisionprofile"
    if not profile_path.is_file():
        raise ValueError("Focus-enabled app is missing its embedded provisioning profile.")
    profile = decode_profile(profile_path)
    expected = validate_profile(profile)
    if any(grants.get(key) != value for key, value in expected.items()):
        raise ValueError("App entitlements do not match the embedded profile.")
    requirement = f'anchor apple generic and identifier "{APP_ID}" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "-R", requirement, str(app)], check=True)
    with tempfile.TemporaryDirectory(prefix="doorbell-signing-certificate-") as tmp:
        prefix = pathlib.Path(tmp) / "cert"
        subprocess.run(["/usr/bin/codesign", "-d", "--extract-certificates", str(prefix), str(app)], check=True, capture_output=True)
        leaf = pathlib.Path(str(prefix) + "0").read_bytes()
        if leaf not in profile["DeveloperCertificates"]:
            raise ValueError("Signing identity is not authorized by the embedded provisioning profile.")
    details = subprocess.check_output(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], stderr=subprocess.STDOUT, text=True)
    if f"TeamIdentifier={expected[TEAM]}" not in details.splitlines():
        raise ValueError("Signing identity Team ID does not match the embedded provisioning profile.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("output", type=pathlib.Path)
    prep.add_argument("--signed", action="store_true")
    prep.add_argument("--profile", type=pathlib.Path)
    audit = commands.add_parser("verify-app")
    audit.add_argument("app", type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(args.output, args.signed, args.profile)
        else:
            verify_app(args.app)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Signing configuration: {error}\n")


if __name__ == "__main__":
    main()
