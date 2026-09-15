#!/usr/bin/env python3
"""Emit only public app configuration. Refuse mock/local/secret configuration for distribution."""
import argparse, base64, json, pathlib, urllib.parse

def client_config(text, local=False):
    values = {}
    for line in text.splitlines():
        line=line.strip()
        if not line or line.startswith('#') or '=' not in line: continue
        key,value=line.split('=',1)
        values[key.strip()]=value.strip().strip('\"\'')
    if local and values.get('DOORBELL_BACKEND') != 'supabase': return ''
    if values.get('DOORBELL_BACKEND') != 'supabase': raise ValueError('Distribution requires DOORBELL_BACKEND=supabase')
    url=values.get('SUPABASE_URL',''); key=values.get('SUPABASE_ANON_KEY','')
    parsed=urllib.parse.urlparse(url)
    if not parsed.hostname or parsed.username or parsed.password: raise ValueError('Invalid Supabase URL')
    if not local and (parsed.scheme != 'https' or parsed.hostname in ('localhost','127.0.0.1','::1') or parsed.hostname.endswith('.local')):
        raise ValueError('Distribution requires a public HTTPS Supabase URL')
    if not key or key.startswith('sb_secret_'): raise ValueError('A public Supabase key is required')
    if not key.startswith('sb_publishable_'):
        try:
            payload=key.split('.')[1]; claims=json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
        except Exception as e: raise ValueError('Expected Supabase publishable key or anon JWT') from e
        if claims.get('role') != 'anon': raise ValueError('Only an anon key may be bundled')
    return f'DOORBELL_BACKEND=supabase\nSUPABASE_URL={url}\nSUPABASE_ANON_KEY={key}\n'

if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('source'); parser.add_argument('output'); parser.add_argument('--local',action='store_true')
    args=parser.parse_args(); source=pathlib.Path(args.source)
    try: output=client_config(source.read_text() if source.exists() else '',args.local)
    except ValueError as e: parser.exit(1,str(e)+'\n')
    pathlib.Path(args.output).write_text(output)
