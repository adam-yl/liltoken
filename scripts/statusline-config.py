"""Print a checkout-specific Claude statusline entry; never edit settings."""
import json
from pathlib import Path
import shlex

root = Path(__file__).absolute().parent.parent
assert root.resolve() == root, 'Checkout path must not contain symlinks'
program = root / '.build/Lil Token.app/Contents/MacOS/LilToken'
command = shlex.join([str(program), '--claude-statusline', '--project-root', str(root)])
print(json.dumps({'statusLine': {'type': 'command', 'command': command}}, indent=2))
