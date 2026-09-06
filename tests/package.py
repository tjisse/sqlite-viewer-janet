"""Inspect package headers without installing or changing the host RPM database."""
from pathlib import Path
import subprocess
import tempfile
import sys

package = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as db:
    args = ['rpm', '--dbpath', db]
    subprocess.run(['rpmkeys', '--dbpath', db, '--checksig', '--nosignature', str(package)], check=True)
    listing = subprocess.check_output([*args, '-qp', '--qf',
        '[%{FILENAMES}\t%{FILEMODES:octal}\t%{FILEUSERNAME}\n]', str(package)], text=True)
    files = {}
    for line in listing.splitlines():
        path, mode, owner = line.split('\t')
        assert int(mode, 8) & 0o022 == 0, f'Group/world-writable package file: {path}'
        if not path.startswith('/var/lib/sqlite-viewer'):
            assert owner == 'root', f'Unexpected owner for {path}: {owner}'
        files[path] = int(mode, 8) & 0o777
    assert files['/usr/bin/sqlite-viewer'] == 0o755
    assert files['/etc/sqlite-viewer/viewer.env'] == 0o640
    assert '/usr/lib/systemd/system/sqlite-viewer.service' in files
    assert '/usr/lib/sqlite-viewer/modules/sqlite3.so' in files
    assert '/usr/lib/sqlite-viewer/modules/jwt.so' in files
    assert not any(p.endswith(('.pem', '.key', '.sqlite')) for p in files)
    print(f'Passed package digest, ownership, permission and layout checks ({len(files)} entries)')
