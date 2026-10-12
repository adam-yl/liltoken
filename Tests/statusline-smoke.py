"""Exercise the compiled non-GUI entry point using synthetic, split stdin."""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

root = Path(__file__).absolute().parent.parent
assert root.resolve() == root
fixture = root / '.build/test-work' / ('app-cli-' + str(uuid.uuid4()))
assert fixture.resolve().is_relative_to(root)
fixture.mkdir(parents=True)
program = root / '.build/Lil Token.app/Contents/MacOS/LilToken'
env = os.environ.copy()
env['TMPDIR'] = str(root / '.build/tmp') + '/'
env['XDG_CACHE_HOME'] = str(root / '.build/cache')
payload = json.dumps({'rate_limits': {'five_hour': {'used_percentage': 19, 'resets_at': time.time()+3600}, 'seven_day': {'used_percentage': 83, 'resets_at': time.time()+86400}}, 'transcript_path': 'IGNORED_TEST_METADATA'})
p = subprocess.Popen([str(program), '--claude-statusline', '--project-root', str(fixture)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
try:
    for chunk in (payload[:30], payload[30:]):
        p.stdin.write(chunk.encode())
        p.stdin.flush()
        time.sleep(.05)
    p.stdin.close()
    p.stdin = None
    out, err = p.communicate(timeout=5)
except BaseException:
    p.kill()
    p.communicate()
    raise
assert p.returncode == 0 and not err, (p.returncode, err)
assert out.decode().strip() == 'Claude · 5h 19% used · week 83% used', out
saved=(fixture/'.runtime/claude-usage.json').read_text()
assert 'IGNORED_TEST_METADATA' not in saved and 'transcript' not in saved
assert len(json.loads(saved)['windows']) == 2
print('Compiled statusline entry point: split-input smoke check passed; no GUI or real AI process started.')
