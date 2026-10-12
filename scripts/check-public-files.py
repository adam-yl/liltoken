"""Review the Git index, not ignored runtime files or the working tree."""
from pathlib import Path
import os
import re
import subprocess
import sys

root = Path(__file__).absolute().parent.parent
assert root.resolve() == root, 'Checkout path must not contain symlinks'
env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)

def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args], env=env)

allowed_root = {'.gitignore', 'README.md', 'LICENSE', 'Info.plist'}
allowed_scripts = {'build.sh', 'test.sh', 'render-preview.sh', 'check-paths.py',
                   'launch.sh', 'statusline-config.py', 'check-public-files.py'}
checks = {
    'personal home path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'API key': re.compile(r'\bsk-[A-Za-z0-9_-]{20,}'),
    'GitHub token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
    'AWS access key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
}
email = re.compile(r'\b[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b')
failures = []
entries = git('ls-files', '--stage', '-z').split(b'\0')
count = 0
for entry in filter(None, entries):
    metadata, raw_path = entry.split(b'\t', 1)
    mode, object_id, stage = metadata.decode().split()
    path = raw_path.decode('utf-8')
    parts = Path(path).parts
    allowed = path in allowed_root or (
        len(parts) == 2 and (
            (parts[0] in {'Sources', 'Tests'} and parts[1].endswith('.swift')) or
            (parts[0] == 'Tests' and parts[1] == 'statusline-smoke.py') or
            (parts[0] == 'scripts' and parts[1] in allowed_scripts)))
    if not allowed or mode not in {'100644', '100755'} or stage != '0':
        failures.append(f'{path}: unexpected path, symlink, or unresolved entry')
        continue
    data = git('cat-file', 'blob', object_id)
    if len(data) > 250_000 or b'\0' in data:
        failures.append(f'{path}: binary or oversized file')
        continue
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        failures.append(f'{path}: non-UTF-8 file')
        continue
    for label, pattern in checks.items():
        if pattern.search(text):
            failures.append(f'{path}: possible {label}')
    for match in email.finditer(text):
        domain = match.group().split('@', 1)[1].lower()
        if domain not in {'example.com', 'example.invalid', 'users.noreply.github.com'}:
            failures.append(f'{path}: possible private email address')
    count += 1

if not count:
    failures.append('No source files are staged/tracked.')
if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print(f'Public index check passed: {count} text files; no flagged secrets or private paths.')
