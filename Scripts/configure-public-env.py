#!/usr/bin/env python3
"""Write the iPad's public account configuration (the plist is ignored by Git).

Only the publishable key is copied from the desktop project's .env.local; no session
or service-role key is read. Requests go to the custom auth domain. The token issuer
is read from that domain's OIDC discovery, because the custom domain keeps issuing
tokens with the project's supabase.co issuer.
"""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import subprocess
from urllib.parse import urlparse

parser = argparse.ArgumentParser()
parser.add_argument('--desktop', type=Path, default=Path('../bandal'))
parser.add_argument('--auth-url', default='https://auth.bandal.io')
args = parser.parse_args()
key = ''
for line in (args.desktop / '.env.local').read_text().splitlines():
    if '=' in line and line.split('=', 1)[0].strip() == 'MAIN_VITE_SUPABASE_PUBLISHABLE_KEY':
        key = line.split('=', 1)[1].strip().strip('\"\'')
url = args.auth_url.rstrip('/')
assert urlparse(url).scheme == 'https' and urlparse(url).hostname, 'A valid HTTPS auth URL is required'
if not key.startswith('sb_publishable_'):
    claims = json.loads(base64.urlsafe_b64decode(key.split('.')[1] + '==='))
    assert claims.get('role') == 'anon', 'Only a publishable or anon key is allowed'
# curl uses the macOS trust store; python.org builds may ship without root certificates.
discovery = subprocess.run(['curl', '-fsS', '--max-time', '15', url + '/auth/v1/.well-known/openid-configuration'],
                           check=True, capture_output=True, text=True).stdout
issuer = json.loads(discovery)['issuer']
assert urlparse(issuer).scheme == 'https' and issuer.endswith('/auth/v1'), f'Unexpected issuer: {issuer}'
target = Path(__file__).resolve().parent.parent / 'App/Resources/Configuration.plist'
with target.open('wb') as stream:
    plistlib.dump({'sync.url': url, 'sync.issuer': issuer, 'sync.publishableKey': key}, stream)
print(f'Public configuration prepared: {url}, issuer {issuer}. No credentials copied.')
