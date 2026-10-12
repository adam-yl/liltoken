"""Validate deliberate build outputs before creating any directories."""
from pathlib import Path
import os
root = Path(__file__).absolute().parent.parent
assert root == root.resolve(), 'Project path must not contain symlinks'
app = '.build/Lil Token.app'
directories = ['.build', '.build/tmp', '.build/cache', '.build/module-cache', '.build/clang-cache', '.build/test-work', '.runtime']
directories.extend([app, app+'/Contents', app+'/Contents/MacOS', app+'/Contents/Resources'])
for relative in directories:
    path = root / relative
    assert path == path.resolve() and path.resolve().is_relative_to(root), f'Unsafe output: {relative}'
    if path.exists():
        assert path.is_dir(), f'Not a directory: {relative}'
    else:
        path.mkdir(parents=True, mode=0o700)
for path in (root/app).rglob('*'):
    assert not path.is_symlink() and path.resolve().is_relative_to(root), 'Unsafe app destination'
    if path.is_file():
        assert path.stat().st_nlink == 1, 'Multiply linked app destination'
