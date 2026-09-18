#!/usr/bin/env python3
"""Emit public app configuration for the bundle. Local builds may use Convex or Supabase."""
import argparse, base64, ipaddress, json, pathlib, urllib.parse

def validate_url(url, local):
    parsed = urllib.parse.urlparse(url)
    if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('', '/'):
        raise ValueError('Invalid backend URL')
    _ = parsed.port  # Invalid ports must fail, not be mistaken for a hostname.
    try:
        private = not ipaddress.ip_address(parsed.hostname).is_global
    except ValueError:
        private = parsed.hostname == 'localhost' or parsed.hostname.endswith(('.local', '.localhost')) or '.' not in parsed.hostname
    if local:
        if parsed.scheme not in ('http', 'https'): raise ValueError('Backend requires HTTP or HTTPS')
    elif parsed.scheme != 'https' or private:
        raise ValueError('Distribution requires a public HTTPS backend URL')
    return parsed

def client_config(text, local=False):
    values = {}
    for line in text.splitlines():
        line=line.strip()
        if not line or line.startswith('#') or '=' not in line: continue
        key,value=line.split('=',1)
        values[key.strip()]=value.strip().strip('\"\'')
    backend = values.get('DOORBELL_BACKEND', '')
    if local and backend not in ('supabase', 'convex'):
        return ''
    if backend == 'convex':
        url = values.get('CONVEX_URL', '')
        validate_url(url, local)
        return f'DOORBELL_BACKEND=convex\nCONVEX_URL={url}\n'
    if backend != 'supabase':
        raise ValueError('Set DOORBELL_BACKEND to convex or supabase')
    url=values.get('SUPABASE_URL',''); key=values.get('SUPABASE_ANON_KEY','')
    validate_url(url, local)
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
