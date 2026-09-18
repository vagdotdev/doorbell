#!/usr/bin/env python3
"""Validate, install into a temporary folder and boot a fresh, signed-out audit profile.
No existing app is replaced; no real account, camera, microphone or friends are used.
"""
import hashlib, os, pathlib, plistlib, subprocess, sys, tempfile, time, uuid, shutil, re
ROOT=pathlib.Path(__file__).resolve().parents[1]
dmg=pathlib.Path(sys.argv[1]).resolve()
expected=dmg.with_suffix(dmg.suffix+'.sha256').read_text().split()[0]
assert hashlib.sha256(dmg.read_bytes()).hexdigest()==expected, 'DMG checksum mismatch'
with tempfile.TemporaryDirectory(prefix='doorbell-bundle-audit-') as temporary:
    work=pathlib.Path(temporary); mount=work/'mount'; mount.mkdir()
    subprocess.run(['hdiutil','attach',str(dmg),'-readonly','-nobrowse','-mountpoint',str(mount),'-quiet'],check=True)
    try:
        app=mount/'Doorbell.app'; contents=app/'Contents'
        info=plistlib.loads((contents/'Info.plist').read_bytes())
        assert info['CFBundleIdentifier']=='dev.vag.doorbell'
        assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',info['CFBundleShortVersionString'])
        assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}',info['CFBundleVersion'])
        assert info['DoorbellReleaseTag']
        assert info['NSCameraUsageDescription'] and info['NSMicrophoneUsageDescription'] and info['NSFocusStatusUsageDescription']
        assert (contents/'MacOS/DoorbellSwap').is_file()
        assert (contents/'Resources/scripts/apply-update.sh').is_file()
        assert info['LSMinimumSystemVersion']=='15.0'
        assert not (contents/'Resources/.env.local').exists(), 'Local config leaked into bundle'
        keys={line.split('=',1)[0] for line in (contents/'Resources/.env').read_text().splitlines() if '=' in line}
        assert keys <= {'DOORBELL_BACKEND','CONVEX_URL','SUPABASE_URL','SUPABASE_ANON_KEY'}, 'Unexpected config key'
        subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
        entitlements=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(app)],stderr=subprocess.DEVNULL))
        assert entitlements.get('com.apple.security.device.camera') is True
        assert entitlements.get('com.apple.security.device.audio-input') is True
        assert isinstance(info.get('DoorbellFocusStatusEnabled'), bool), 'Focus capability marker missing'
        subprocess.run([sys.executable,str(ROOT/'scripts/signing-config.py'),'verify-app',str(app)],check=True)
        assert (entitlements.get('com.apple.developer.usernotifications.communication') is True) == info['DoorbellFocusStatusEnabled']
        assert 'arm64' in subprocess.check_output(['lipo','-archs',str(contents/'MacOS/Doorbell')],text=True)
        assert (mount/'install-dmg.sh').is_file(), 'DMG installer helper missing'
        dest=work/'Doorbell.app'
        env={k:v for k,v in os.environ.items() if not k.startswith(('DOORBELL_','CONVEX_'))}
        env.update(LIB=str(ROOT/'scripts/lib/install-dmg.sh'),SOURCE=str(app),DOORBELL_APP=str(dest),DOORBELL_ALLOW_UNSIGNED='1',DOORBELL_NO_LAUNCH='1')
        subprocess.run(['zsh','-eu','-c','source "$LIB"; doorbell_install_bundle "$SOURCE"'],env=env,check=True)
        profile='launch-audit-'+str(uuid.uuid4())
        env.update(DOORBELL_PROFILE=profile)
        support=pathlib.Path.home()/'Library/Application Support/Doorbell'/profile
        output=ROOT/'.context/launch-audit/launch.log'; output.parent.mkdir(parents=True,exist_ok=True)
        with output.open('w') as log:
            process=subprocess.Popen([str(dest/'Contents/MacOS/Doorbell')],cwd=work,env=env,stdout=log,stderr=log)
            try:
                for _ in range(40):
                    time.sleep(.2)
                    assert process.poll() is None, 'Fresh app exited during startup'
                print('DMG signature/resources/checksum, isolated installation and 8-second fresh-profile boot passed.')
                print('UI clicks, Gatekeeper approval, camera/mic and oldest-OS compatibility are separate gates.')
            finally:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
                shutil.rmtree(support,ignore_errors=True)
    finally:
        subprocess.run(['hdiutil','detach',str(mount),'-quiet'],check=True)
