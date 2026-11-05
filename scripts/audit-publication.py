#!/usr/bin/env python3
"""Scan staged files and optional unpacked installers. Never print credential values."""
import argparse
import json
import pathlib
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--credentials', type=pathlib.Path, action='append', default=[])
parser.add_argument('--unpacked', type=pathlib.Path, action='append', default=[])
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
secret_keys = {'baiduAKey', 'baiduSKey', 'storePassword', 'keyPassword', 'password', 'access_token', 'refresh_token'}
secrets = set()

def collect(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in secret_keys and isinstance(item, str) and len(item) >= 6:
                secrets.add(item.encode())
            else:
                collect(item)
    elif isinstance(value, list):
        for item in value:
            collect(item)

for path in args.credentials:
    if path.is_file():
        collect(json.loads(path.read_text()))

forbidden_names = {'settings.json', 'credentials.json', 'pending-bangcle-task.json', '.DS_Store', '.env'}
forbidden_suffixes = {'.apk', '.jks', '.keystore', '.p12', '.pfx', '.pem', '.key', '.log', '.part'}
patterns = [
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    re.compile(rb'gh[pousr]_[A-Za-z0-9]{30,}'),
    re.compile(rb'github_pat_[A-Za-z0-9_]{30,}'),
    re.compile(rb'/Users/[^/\x00\r\n]{1,80}/(?:Desktop|Downloads|Documents|Library)/'),
]
failures = []
count = 0

def check(name, data):
    global count
    count += 1
    path = pathlib.PurePosixPath(name)
    if (path.name in forbidden_names or path.suffix in forbidden_suffixes or
        path.name.endswith('.signing.json') or '.android-release-tool' in path.parts or '.build' in path.parts):
        failures.append((name, 'private runtime file'))
    if any(secret in data for secret in secrets):
        failures.append((name, 'matches a local credential value'))
    if any(pattern.search(data) for pattern in patterns):
        failures.append((name, 'private key, token, or personal absolute path'))

names = subprocess.check_output(['git', 'ls-files', '--cached', '-z'], cwd=root).decode().split('\0')
for name in filter(None, names):
    data = subprocess.check_output(['git', 'show', ':' + name], cwd=root)
    check(name, data)
for directory in args.unpacked:
    for file in directory.rglob('*'):
        if file.is_file() and not file.is_symlink():
            check(str(file.relative_to(directory)), file.read_bytes())
if failures:
    for name, reason in failures:
        print('BLOCKED:', name, '-', reason)
    raise SystemExit(1)
print(f'PASS: {count} staged/unpacked files audited; no credential values printed or included.')
