#!/usr/bin/env python3
"""Regression tests for the entitlement/profile boundary, without signing credentials."""
import datetime as dt
import importlib.util
import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("signing_config", ROOT / "scripts/signing-config.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
NOW = dt.datetime(2026, 9, 19, tzinfo=dt.timezone.utc)


def profile():
    return {
        "CreationDate": NOW - dt.timedelta(days=1),
        "ExpirationDate": NOW + dt.timedelta(days=365),
        "Platform": ["OSX"], "ProvisionsAllDevices": True,
        "TeamIdentifier": ["A123456789"], "ApplicationIdentifierPrefix": ["A123456789"],
        "DeveloperCertificates": [b"fixture certificate; not a real signing identity"],
        "Entitlements": {
            signing.TEAM: "A123456789", signing.APPLICATION: "A123456789.dev.vag.doorbell",
            signing.FOCUS: True,
        },
    }


class SigningConfigurationTests(unittest.TestCase):
    def test_ad_hoc_entitlements_omit_all_restricted_grants_and_stale_profiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            (output / "embedded.provisionprofile").write_bytes(b"stale")
            signing.prepare(output)
            grants = plistlib.loads((output / "app.entitlements").read_bytes())
            self.assertEqual(grants, {
                "com.apple.security.device.camera": True,
                "com.apple.security.device.audio-input": True,
            })
            self.assertFalse((output / "embedded.provisionprofile").exists())

    def test_signed_build_requires_a_profile_before_compiling(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = {key: value for key, value in os.environ.items() if not key.startswith("DOORBELL_")}
            env.update(DOORBELL_SIGN_IDENTITY="missing signing identity", DOORBELL_BUILD_DIR=tmp)
            result = subprocess.run(["zsh", str(ROOT / "scripts/bundle.sh")], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("DOORBELL_PROVISION_PROFILE", result.stderr)
            self.assertNotIn("Building for", result.stdout + result.stderr)
            self.assertFalse((pathlib.Path(tmp) / "Doorbell.app").exists())

    def test_ad_hoc_cannot_smuggle_a_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "SIGN_IDENTITY"):
                signing.prepare(pathlib.Path(tmp), profile_path=pathlib.Path("untrusted.profile"))

    def test_exact_distribution_grants_are_selected(self):
        value = profile()
        value["Entitlements"]["unrelated.capability"] = True
        self.assertEqual(signing.validate_profile(value, NOW), profile()["Entitlements"])

    def test_expired_and_not_yet_valid_profiles_fail(self):
        for key, value in [("ExpirationDate", NOW), ("CreationDate", NOW + dt.timedelta(days=1))]:
            with self.subTest(key=key):
                data = profile(); data[key] = value
                with self.assertRaises(ValueError): signing.validate_profile(data, NOW)

    def test_wrong_platform_or_distribution_scope_fails(self):
        for key, value in [("Platform", ["iOS"]), ("ProvisionsAllDevices", False), ("ProvisionedDevices", ["test-Mac"])]:
            with self.subTest(key=key):
                data = profile(); data[key] = value
                with self.assertRaises(ValueError): signing.validate_profile(data, NOW)

    def test_missing_focus_debug_and_foreign_or_wildcard_app_fail(self):
        mutations = [
            (signing.FOCUS, False), ("get-task-allow", True),
            ("com.apple.security.get-task-allow", True),
            (signing.APPLICATION, "A123456789.*"),
            (signing.APPLICATION, "A123456789.other.app"),
            (signing.TEAM, "B123456789"),
        ]
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                data = profile(); data["Entitlements"][key] = value
                with self.assertRaises(ValueError): signing.validate_profile(data, NOW)

    def test_missing_or_malformed_certificates_fail(self):
        for certificates in [[], ["not DER data"], [b""]]:
            data = profile(); data["DeveloperCertificates"] = certificates
            with self.assertRaises(ValueError): signing.validate_profile(data, NOW)


if __name__ == "__main__":
    unittest.main()
