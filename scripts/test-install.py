#!/usr/bin/env python3
"""Fault-injection tests for the installer; all destinations are disposable folders."""
import os, pathlib, subprocess, tempfile, unittest, shutil, time, plistlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT / 'scripts/lib/install-dmg.sh'
class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(prefix='doorbell-swap-fixture-')
        cls.swap = pathlib.Path(cls.tools.name) / 'DoorbellSwap'
        subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror',str(ROOT/'Sources/DoorbellSwap/main.c'),'-o',str(cls.swap)],check=True)
    @classmethod
    def tearDownClass(cls): cls.tools.cleanup()
    def run_install(self, fault='', existing=True):
        with tempfile.TemporaryDirectory(prefix='doorbell-install-test-') as temp:
            root=pathlib.Path(temp); source=root/'incoming.app'; source.mkdir()
            (source/'version').write_text('new')
            (source/'Contents/MacOS').mkdir(parents=True)
            shutil.copy2(self.swap,source/'Contents/MacOS/DoorbellSwap')
            account=root/'Application Support/Doorbell/profile'; account.mkdir(parents=True)
            saved={'session.json':'saved refresh fixture','preferences.json':'quiet:true','friends.json':'friend-id-unchanged'}
            for name,value in saved.items(): (account/name).write_text(value)
            dest=root/'Doorbell.app'
            if existing: dest.mkdir(); (dest/'version').write_text('old')
            script='''source "$LIB"
doorbell_require_hardware() { return 0; }
doorbell_validate_app() { [[ "$FAULT" != validate ]]; }
doorbell_validate_update() { return 0; }
doorbell_signature_kind() { echo adhoc; }
pgrep() { return 1; }
xattr() { return 0; }
doorbell_launch_app() { [[ "$FAULT" != launch ]]; }
doorbell_swap_bundles() {
  [[ "$1" == "${2:h}/DoorbellSwap" ]] || return 1
  "$1" "$2" "$3"
}
if [[ "$FAULT" == copy ]]; then ditto() { mkdir -p "$2"; return 1; }; fi
if [[ "$FAULT" == move ]]; then
  doorbell_swap_bundles() { return 1; }
  mv() { if [[ "$1" == */.doorbell-install.*/Doorbell.app ]]; then return 1; fi; /bin/mv "$@"; }
fi
doorbell_install_bundle "$SOURCE"
'''
            r=subprocess.run(['zsh','-eu','-c',script],env={**os.environ,'LIB':str(LIB),'SOURCE':str(source),'DOORBELL_APP':str(dest),'DOORBELL_ALLOW_UNSIGNED':'1','DOORBELL_NO_LAUNCH':'0','FAULT':fault},capture_output=True,text=True)
            self.assertEqual(r.returncode == 0, not fault, r.stdout+r.stderr)
            if not fault: self.assertEqual((dest/'version').read_text(),'new')
            elif existing: self.assertEqual((dest/'version').read_text(),'old')
            else: self.assertFalse(dest.exists())
            self.assertFalse(list(root.glob('.doorbell-install.*')))
            for name,value in saved.items(): self.assertEqual((account/name).read_text(),value)
            # The persistent lock inode is intentional; its kernel lock must be released.
            lock=root/'.Doorbell.app.install-lock'
            unlocked=subprocess.run(['zsh','-c','zmodload zsh/system; zsystem flock -t 0 "$1"','--',str(lock)],capture_output=True)
            self.assertEqual(unlocked.returncode,0,unlocked.stderr)
    def test_replace_succeeds(self): self.run_install()
    def test_first_install_succeeds(self): self.run_install(existing=False)
    def test_failed_copy_preserves_previous(self): self.run_install('copy')
    def test_invalid_bundle_preserves_previous(self): self.run_install('validate')
    def test_failed_move_restores_previous(self): self.run_install('move')
    def test_failed_launch_restores_previous(self): self.run_install('launch')
    def test_failed_first_launch_removes_broken_install(self): self.run_install('launch',existing=False)
    def test_launch_does_not_accept_an_unrelated_process(self):
        script='''source "$LIB"
sleep() { return 0; }
open() { return 0; }
ps() { echo /unrelated/Doorbell.app/Contents/MacOS/Doorbell; }
doorbell_launch_app /expected/Doorbell.app
'''
        r=subprocess.run(['zsh','-eu','-c',script],env={**os.environ,'LIB':str(LIB)},capture_output=True)
        self.assertNotEqual(r.returncode,0)
    def test_killed_swap_never_removes_app_and_releases_lock(self):
        with tempfile.TemporaryDirectory(prefix='doorbell-kill-test-') as temp:
            root=pathlib.Path(temp); source=root/'incoming.app'; dest=root/'Doorbell.app'
            (source/'Contents/MacOS').mkdir(parents=True); dest.mkdir()
            shutil.copy2(self.swap,source/'Contents/MacOS/DoorbellSwap')
            (source/'version').write_text('new'); (dest/'version').write_text('old')
            reached=root/'swapped'
            script='''source "$LIB"
doorbell_require_hardware() { return 0; }
doorbell_validate_app() { return 0; }
doorbell_validate_update() { return 0; }
doorbell_signature_kind() { echo adhoc; }
xattr() { return 0; }
doorbell_is_running() { return 1; }
doorbell_swap_bundles() { "$1" "$2" "$3"; touch "$REACHED"; kill -KILL "$sysparams[pid]"; }
doorbell_install_bundle "$SOURCE"
'''
            result=subprocess.run(['zsh','-eu','-c',script],env={**os.environ,'LIB':str(LIB),'SOURCE':str(source),'DOORBELL_APP':str(dest),'DOORBELL_ALLOW_UNSIGNED':'1','REACHED':str(reached)},capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertTrue(reached.exists())
            self.assertEqual((dest/'version').read_text(),'new')
            old=list(root.glob('.doorbell-install.*/Doorbell.app/version'))
            self.assertEqual([f.read_text() for f in old],['old'])
            lock=root/'.Doorbell.app.install-lock'
            unlocked=subprocess.run(['zsh','-c','zmodload zsh/system; zsystem flock -t 0 "$1"','--',str(lock)],capture_output=True)
            self.assertEqual(unlocked.returncode,0,unlocked.stderr)

    def validate_update(self, fault='', different_backend=False, slash=False, current_kind='signed', incoming_kind='signed', beta=True, success=True):
        with tempfile.TemporaryDirectory(prefix='doorbell-trust-test-') as temp:
            root=pathlib.Path(temp); current=root/'current.app'; incoming=root/'incoming.app'
            for app in [current,incoming]:
                (app/'Contents/Resources').mkdir(parents=True)
                (app/'Contents/MacOS').mkdir(parents=True)
                binary=app/'Contents/MacOS/Doorbell'; binary.write_text('fixture'); binary.chmod(0o755)
                (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'dev.vag.doorbell'}))
            (current/'Contents/Resources/.env').write_text('DOORBELL_BACKEND=convex\nCONVEX_URL=https://same.convex.cloud'+('/' if slash else '')+'\n')
            (incoming/'Contents/Resources/.env').write_text('DOORBELL_BACKEND=convex\nCONVEX_URL=https://'+('different' if different_backend else 'same')+'.convex.cloud\n')
            script='''source "$LIB"
codesign() {
  local kind="$INCOMING_KIND"
  [[ "${argv[-1]}" != "$CURRENT" ]] || kind="$CURRENT_KIND"
  if [[ "$1" == -dv ]]; then
    if [[ "$kind" == adhoc ]]; then echo Signature=adhoc; echo 'TeamIdentifier=not set'
    elif [[ "$kind" == signed ]]; then echo TeamIdentifier=ABCD123456
    elif [[ "$kind" == other ]]; then echo TeamIdentifier=DIFF123456
    else return 1; fi
  elif [[ " $* " == *" -R "* ]]; then
    [[ "$kind" == signed && "$FAULT" != publisher ]]
  else [[ "$FAULT" != corrupt ]]; fi
}
spctl() { [[ "$FAULT" != gatekeeper && "$INCOMING_KIND" != adhoc ]]; }
doorbell_validate_update "$CURRENT" "$INCOMING"
'''
            result=subprocess.run(['zsh','-eu','-c',script],env={**os.environ,'LIB':str(LIB),'CURRENT':str(current),'INCOMING':str(incoming),'FAULT':fault,
                'CURRENT_KIND':current_kind,'INCOMING_KIND':incoming_kind,'DOORBELL_ALLOW_UNSIGNED':'1' if beta else '0'},capture_output=True,text=True)
            self.assertEqual(result.returncode==0,success,result.stdout+result.stderr)
    def test_update_preserves_backend(self): self.validate_update()
    def test_update_accepts_trailing_slash_equivalence(self): self.validate_update(slash=True)
    def test_update_rejects_account_database_change(self): self.validate_update(different_backend=True,success=False)
    def test_beta_update_accepts_verified_adhoc_lineage(self): self.validate_update(current_kind='adhoc',incoming_kind='adhoc')
    def test_beta_update_requires_explicit_distribution_policy(self): self.validate_update(current_kind='adhoc',incoming_kind='adhoc',beta=False,success=False)
    def test_signed_install_cannot_downgrade_to_beta(self): self.validate_update(incoming_kind='adhoc',success=False)
    def test_update_rejects_corrupted_adhoc(self): self.validate_update(current_kind='adhoc',incoming_kind='adhoc',fault='corrupt',success=False)
    def test_beta_can_adopt_a_valid_signed_release(self): self.validate_update(current_kind='adhoc')
    def test_update_rejects_different_publisher(self): self.validate_update(incoming_kind='other',success=False)
    def test_signed_update_never_inherits_unsigned_override(self): self.validate_update(fault='gatekeeper',success=False)
    def test_beta_rejects_account_database_change(self): self.validate_update(current_kind='adhoc',incoming_kind='adhoc',different_backend=True,success=False)
    def test_only_official_release_urls_implicitly_allow_beta(self):
        official='https://github.com/vagdotdev/doorbell/releases/latest/download/Doorbell.dmg'
        urls=[(official,True),('https://github.com/vagdotdev/doorbell/releases/download/v2026.09.19-1200-abcdef0/Doorbell.dmg',True),
              (official.replace('https:','http:'),False),(official.replace('vagdotdev','someone'),False),
              (official+'?mirror=1',False),(official.replace('github.com','github.com.evil.test'),False)]
        for url,allowed in urls:
            r=subprocess.run(['zsh','-c','source "$LIB"; doorbell_is_official_release_url "$1"','--',url],env={**os.environ,'LIB':str(LIB)},capture_output=True)
            self.assertEqual(r.returncode==0,allowed,url)

    def test_generated_web_installer_matches(self):
        subprocess.run(['python3',str(ROOT/'scripts/generate-installer.py'),'--check'],check=True)
    def check_publish(self, dirty=False, distribution='private-beta', signature='adhoc', valid=True, gatekeeper=False, success=False, drift=False):
        # Execute the actual publish branch with external commands replaced.
        publish=(ROOT/'scripts/release.sh').read_text().rsplit('if [[ "${1:-}" == "--publish" ]]; then',1)[1]
        with tempfile.TemporaryDirectory(prefix='doorbell-publish-test-') as temp:
            marker=pathlib.Path(temp)/'published'
            script='''set -- --publish
git() {
  if [[ "$1" == status ]]; then
    if [[ "$DIRTY" == 1 ]]; then echo ' M source.swift'; fi
  else echo "$CURRENT_COMMIT"; fi
}
spctl() { [[ "$GATEKEEPER" == 1 ]]; }
codesign() { if [[ "$1" == -dv ]]; then echo "Signature=$SIGNATURE"; else [[ "$VALID" == 1 ]]; fi; }
gh() {
  if [[ "$1 $2" == "release create" ]]; then
    [[ " $* " == *" --target $release_commit "* ]] || return 1
    touch "$MARKER"
  fi
}
release_commit=abcdef0
staging=/unused
OUT=/unused
tag=v2026.09.19-1200-abcdef0
if [[ "${1:-}" == "--publish" ]]; then
'''+publish
            r=subprocess.run(['zsh','-eu','-c',script],env={**os.environ,'DOORBELL_ALLOW_UNSIGNED':'1','DIRTY':str(int(dirty)),
                'DOORBELL_DISTRIBUTION':distribution,'SIGNATURE':signature,'VALID':str(int(valid)),
                'GATEKEEPER':str(int(gatekeeper)),'MARKER':str(marker),'CURRENT_COMMIT':'changed' if drift else 'abcdef0'},capture_output=True,text=True)
            self.assertEqual(r.returncode==0,success,r.stdout+r.stderr)
            self.assertEqual(marker.exists(),success)
    def test_publish_refuses_source_commit_drift(self): self.check_publish(drift=True)
    def test_beta_publish_refuses_dirty_tree(self): self.check_publish(dirty=True)
    def test_beta_publish_accepts_integrity_checked_adhoc_release(self): self.check_publish(success=True)
    def test_beta_publish_rejects_broken_signature(self): self.check_publish(valid=False)
    def test_signed_publish_requires_gatekeeper_even_with_beta_override(self): self.check_publish(distribution='signed',signature='Developer ID')
    def test_signed_publish_accepts_gatekeeper(self): self.check_publish(distribution='signed',signature='Developer ID',gatekeeper=True,success=True)
if __name__=='__main__': unittest.main()
