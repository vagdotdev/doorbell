#!/usr/bin/env python3
"""Two real Swift clients against disposable, loopback-only Convex + LiveKit.
Requires cached convex-local-backend, livekit-server, Node and Swift. Never reads .env.
"""
import json, os, pathlib, secrets, shutil, socket, subprocess, sys, tempfile, time, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]

def ready(port):
    for _ in range(100):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.2): return
        except OSError: time.sleep(.2)
    raise RuntimeError(f'Local service on {port} did not start')

def run():
    binaries = sorted((pathlib.Path.home()/'.cache/convex/binaries').glob('*/convex-local-backend'))
    if not binaries: raise RuntimeError('Install the local Convex backend first (convex dev --local in a disposable project).')
    binary = binaries[-1]
    for port in [18210,18211,18900,18901]:
        with socket.socket() as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(('127.0.0.1',port))
    with socket.socket(type=socket.SOCK_DGRAM) as s: s.bind(('127.0.0.1',18902))
    (ROOT/'.context').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='convex-live-',dir=ROOT/'.context') as temp:
        work = pathlib.Path(temp)
        shutil.copytree(ROOT/'convex',work/'convex')
        for name in ['package.json','package-lock.json','tsconfig.json','convex.json']: shutil.copy2(ROOT/name,work/name)
        (work/'node_modules').symlink_to(ROOT/'node_modules',target_is_directory=True)
        secret=secrets.token_hex(32); instance='doorbell-local-audit'
        admin=subprocess.check_output([str(binary),'keygen','admin-key','--instance-name',instance,'--instance-secret',secret],text=True).strip()
        env={k:v for k,v in os.environ.items() if not k.startswith(('CONVEX_','DOORBELL_'))}
        env.update(CONVEX_SELF_HOSTED_URL='http://127.0.0.1:18210',CONVEX_SELF_HOSTED_ADMIN_KEY=admin)
        (work/'livekit.yaml').write_text('port: 18900\nrtc:\n  tcp_port: 18901\n  udp_port: 18902\n  use_external_ip: false\n')
        processes=[]
        with open(work/'services.log','w') as log:
            try:
                processes.append(subprocess.Popen([str(binary),'--interface','127.0.0.1','--port','18210','--site-proxy-port','18211','--instance-name',instance,'--instance-secret',secret,'--disable-beacon',str(work/'audit.sqlite3')],cwd=work,stdout=log,stderr=log))
                processes.append(subprocess.Popen(['livekit-server','--dev','--config',str(work/'livekit.yaml'),'--bind','127.0.0.1','--node-ip','127.0.0.1'],stdout=log,stderr=log))
                ready(18210); ready(18900)
                keygen='''import {generateKeyPair, exportPKCS8, exportJWK} from "jose";
const {privateKey, publicKey}=await generateKeyPair("RS256", {extractable:true});
console.log(JSON.stringify({JWT_PRIVATE_KEY:await exportPKCS8(privateKey),JWKS:JSON.stringify({keys:[await exportJWK(publicKey)]})}));'''
                values=json.loads(subprocess.check_output(['node','--input-type=module','-e',keygen],cwd=work,text=True))
                values.update(LIVEKIT_URL='http://127.0.0.1:18900',LIVEKIT_PUBLIC_URL='ws://127.0.0.1:18900',LIVEKIT_API_KEY='devkey',LIVEKIT_API_SECRET='secret',SITE_URL='http://127.0.0.1:18211')
                request=urllib.request.Request('http://127.0.0.1:18210/api/update_environment_variables',data=json.dumps({'changes':[{'name':k,'value':v} for k,v in values.items()]}).encode(),headers={'Authorization':'Convex '+admin,'Content-Type':'application/json'})
                with urllib.request.urlopen(request,timeout=15) as response: response.read()
                subprocess.run([str(ROOT/'node_modules/.bin/convex'),'dev','--once','--typecheck','enable'],cwd=work,env=env,check=True,timeout=150)
                testenv={k:v for k,v in os.environ.items() if not k.startswith(('CONVEX_','DOORBELL_'))}
                testenv['DOORBELL_CONVEX_TEST_URL']='http://127.0.0.1:18210'
                subprocess.run(['node','scripts/test-doorstep-audio.mjs'],cwd=ROOT,env=testenv,check=True,timeout=90)
                if '--node-only' not in sys.argv:
                    subprocess.run(['swift','test','--filter','ConvexLiveIntegrationTests'],cwd=ROOT,env=testenv,check=True,timeout=240)
                    fixture = work/'restart-fixture.json'
                    try:
                        for phase in ['seed', 'restore']:
                            restartenv = dict(testenv, DOORBELL_UPGRADE_TEST_PHASE=phase, DOORBELL_UPGRADE_TEST_FIXTURE=str(fixture))
                            subprocess.run(['swift','test','--skip-build','--filter','separateProcessUpdatePreservesLoginAndFriends'],cwd=ROOT,env=restartenv,check=True,timeout=90)
                        print('Separate OS processes preserved login, account identity, friends and policy without credentials.')
                    finally:
                        # Delete only this fixture's disposable credentials, including
                        # a seed process killed before the restore could sign out.
                        if fixture.exists():
                            profile = json.loads(fixture.read_text())['profile']
                            for suffix in ['', '-friend']:
                                service = f'dev.vag.doorbell.auth.convex-{profile}{suffix}-127.0.0.1'
                                subprocess.run(['security','delete-generic-password','-s',service,'-a','convex-session'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

                print('Local Convex + LiveKit audio' + (' and Swift round trip' if '--node-only' not in sys.argv else '') + ' passed.')
            finally:
                for process in processes: process.terminate()
                for process in processes:
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
if __name__=='__main__': run()
