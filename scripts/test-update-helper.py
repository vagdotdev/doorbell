#!/usr/bin/env python3
"""Run the actual update helper with disposable commands; never touch /Applications."""
import hashlib
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class UpdateHelperTests(unittest.TestCase):
    def run_case(self, fault="", app="/Applications/Doorbell.app"):
        with tempfile.TemporaryDirectory(prefix="doorbell-update-helper-") as temp:
            root = Path(temp); scripts = root / "scripts"; scripts.mkdir(); bins = root / "bin"; bins.mkdir()
            shutil.copy(ROOT / "scripts/lib/apply-update.sh", scripts / "apply-update.sh")
            (scripts / "install-dmg.sh").write_text('''
doorbell_require_hardware() { return 0; }
doorbell_signature_kind() { if [[ "$FAULT" == signed ]]; then echo signed:ABCD123456; else echo adhoc; fi; }
doorbell_validate_app() {
  [[ "$FAULT" != signature ]] || return 1
  if [[ "$FAULT" == signed ]]; then [[ "${DOORBELL_ALLOW_UNSIGNED:-}" == 0 ]]; else [[ "${DOORBELL_ALLOW_UNSIGNED:-}" == 1 ]]; fi
}
doorbell_validate_update() { [[ "$FAULT" != identity ]]; }
doorbell_install_bundle() {
  [[ "${DOORBELL_AUTOMATIC_UPDATE:-}" == 1 && -f "$READY_TEST" ]] || return 1
  touch "$TEST_ROOT/install-attempt"
  [[ "$FAULT" != install ]] || return 1
  touch "$TEST_ROOT/installed"
}
doorbell_launch_app() {
  [[ -f "$TEST_ROOT/Doorbell.failed.json" ]] || return 1
  touch "$TEST_ROOT/rollback-relaunch"
}
''')
            commands = {
                "ps": '''#!/bin/zsh
if [[ "$1" == -ax ]]; then
 echo '321 /Applications/Doorbell.app/Contents/MacOS/Doorbell'
 if [[ "$FAULT" == duplicate ]]; then echo '654 /Applications/Doorbell.app/Contents/MacOS/Doorbell'; fi
 exit 0
fi
count=$(cat "$TEST_ROOT/ps-count" 2>/dev/null || echo 0)
count=$((count+1)); echo "$count" > "$TEST_ROOT/ps-count"
if (( count == 1 )) || [[ "$FAULT" == stays ]]; then echo /Applications/Doorbell.app/Contents/MacOS/Doorbell; fi
''',
                "hdiutil": '''#!/bin/zsh
if [[ "$1" == attach ]]; then
 touch "$TEST_ROOT/mounted"
 [[ "$FAULT" != mount ]] || exit 1
 for ((i=1; i<=$#; i++)); do
   if [[ "${argv[$i]}" == -mountpoint ]]; then
     mkdir -p "${argv[$((i+1))]}/Doorbell.app/Contents"
     cp "$TEST_ROOT/Info.plist" "${argv[$((i+1))]}/Doorbell.app/Contents/Info.plist"
   fi
 done
else touch "$TEST_ROOT/detached"; fi
''',
                "sleep": "#!/bin/zsh\nexit 0\n",
                "killall": '#!/bin/zsh\ntouch "$TEST_ROOT/forbidden-kill"\nexit 1\n',
            }
            for name, text in commands.items():
                path = bins / name; path.write_text(text); path.chmod(0o755)
            dmg = root / "update.dmg"; dmg.write_bytes(b"test package")
            digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
            if fault == "checksum": digest = "0" * 64
            ready = root / "ready"
            tag = "v2026.09.19-1200-abc"
            version = "v2026.09.18-0000-abc" if fault == "version" else tag
            (root / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.0", "DoorbellReleaseTag": version}))
            env = {**os.environ, "PATH": str(bins) + os.pathsep + os.environ["PATH"],
                   "TEST_ROOT": str(root), "READY_TEST": str(ready), "FAULT": fault,
                   "TMPDIR": str(root), "DOORBELL_ALLOW_UNSIGNED": "1"}
            result = subprocess.run(["zsh", str(scripts / "apply-update.sh"), str(dmg), "321", app, digest, str(ready), tag],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertFalse((root / "forbidden-kill").exists())
            self.assertFalse(ready.exists(), "preflight marker leaked")
            self.assertFalse(list(root.glob("doorbell-update.*")), "temporary mount directory leaked")
            return result, {p.name for p in root.iterdir()}

    def test_verified_preflight_then_exact_caller_exit_installs(self):
        result, files = self.run_case()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("installed", files); self.assertNotIn("update.dmg", files)
        self.assertIn("detached", files)
        self.assertNotIn("Doorbell.failed.json", files)

    def test_failure_keeps_download_and_never_installs(self):
        for fault in ("signature", "identity", "checksum", "mount", "stays", "duplicate", "version"):
            with self.subTest(fault=fault):
                result, files = self.run_case(fault)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("update.dmg", files); self.assertNotIn("installed", files)
                self.assertNotIn("install-attempt", files)
                self.assertNotIn("Doorbell.failed.json", files)

    def test_preview_path_cannot_replace_installed_app(self):
        result, files = self.run_case(app="/tmp/Doorbell.app")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("mounted", files); self.assertNotIn("installed", files)

    def test_signed_lineage_does_not_receive_beta_override(self):
        result, files = self.run_case("signed")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("installed", files)

    def test_transaction_failure_retains_download(self):
        result, files = self.run_case("install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("install-attempt", files); self.assertIn("update.dmg", files)
        self.assertIn("Doorbell.failed.json", files, "failed candidate must be quarantined before rollback relaunch")
        # The existing installed app on this machine qualifies for relaunch, but
        # doorbell_launch_app is a stub: no user process is opened or closed.
        if Path("/Applications/Doorbell.app").is_dir(): self.assertIn("rollback-relaunch", files)

if __name__ == "__main__": unittest.main()
