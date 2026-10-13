#!/usr/bin/env python3
"""Copy only the existing desktop project's public Supabase configuration.

The generated plist is ignored by Git. No session or service-role key is read.
"""
import argparse
import base64
import json
from pathlib import Path
import plistlib
from urllib.parse import urlparse

parser = argparse.ArgumentParser()
parser.add_argument('--desktop', type=Path, default=Path('../bandal'))
args = parser.parse_args()
allowed = {'MAIN_VITE_SUPABASE_URL', 'MAIN_VITE_SUPABASE_PUBLISHABLE_KEY'}
values = {}
for line in (args.desktop / '.env.local').read_text().splitlines():
    if '=' in line:
        key, value = line.split('=', 1)
        if key.strip() in allowed:
            values[key.strip()] = value.strip().strip('\"\'')
url = values.get('MAIN_VITE_SUPABASE_URL', '')
key = values.get('MAIN_VITE_SUPABASE_PUBLISHABLE_KEY', '')
assert urlparse(url).scheme == 'https' and urlparse(url).hostname, 'A valid HTTPS Supabase URL is required'
if not key.startswith('sb_publishable_'):
    claims = json.loads(base64.urlsafe_b64decode(key.split('.')[1] + '==='))
    assert claims.get('role') == 'anon', 'Only a publishable or anon key is allowed'
target = Path(__file__).resolve().parent.parent / 'App/Resources/Configuration.plist'
with target.open('wb') as stream:
    plistlib.dump({'sync.url': url, 'sync.publishableKey': key}, stream)
print('Public configuration prepared. No credentials copied.')
