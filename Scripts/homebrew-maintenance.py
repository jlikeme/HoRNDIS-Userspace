#!/usr/bin/env python3
"""One-time adapter for older Homebrew uninstall metadata (no network writes)."""
from pathlib import Path
import json
import os
import stat
import tempfile
import uuid


def atomic_write(path, data, mode=0o600):
    descriptor, name = tempfile.mkstemp(prefix='.horndis-maintenance-', dir=str(path.parent))
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class InstalledCaskMigration:
    def __init__(self, caskroom, uninstaller, backup_directory):
        self.caskroom = Path(caskroom)
        self.uninstaller = Path(uninstaller)
        self.backup_directory = Path(backup_directory)
        self.originals = {}
        self.replacement = None
        self.replacement_bytes = None
        self.writes = {}
        self.removed = []
        self.record = {'needed': False}

    def prepare(self):
        if self.caskroom.is_symlink() or (self.caskroom/'.metadata').is_symlink():
            raise RuntimeError('Refusing symbolic-link Caskroom metadata')
        versions = [p for p in (self.caskroom/'.metadata').glob('*/*')
                    if p.is_dir() and not p.is_symlink()]
        if not versions:
            return self.record
        timestamp = max(versions, key=lambda p: p.name)
        directory = timestamp/'Casks'
        if timestamp.parent.is_symlink() or directory.is_symlink():
            raise RuntimeError('Refusing symbolic-link installed-cask ancestors')
        candidates = [directory/('horndis.' + extension) for extension in ['json', 'internal.json', 'rb']]
        existing = [p for p in candidates if p.exists() or p.is_symlink()]
        if not existing:
            raise RuntimeError('Installed HoRNDIS cask metadata is missing')
        for path in existing:
            if path.is_symlink() or not path.is_file():
                raise RuntimeError('Refusing non-regular installed-cask metadata')
        # The new constant --homebrew hook selects the operation when it runs.
        # Older JSON (including receipts with recovered artifacts) needs one
        # explicit preserve flag, before the new app has been installed.
        first = existing[0]
        receipt = self.caskroom/'.metadata/INSTALL_RECEIPT.json'
        if not receipt.is_file() or receipt.is_symlink():
            raise RuntimeError('A regular HoRNDIS installation receipt is required')
        receipt_value = json.loads(receipt.read_text())
        if first.suffix == '.json':
            value = json.loads(first.read_text())
            # Modern Homebrew gives the durable receipt priority over a JSON
            # caskfile. Both records must agree during the first transition.
            artifacts = receipt_value.get('uninstall_artifacts', value.get('artifacts', []))
            for artifact in artifacts:
                for directive in artifact.get('uninstall', []):
                    script = directive.get('script', {})
                    if (script.get('args') == ['--homebrew'] and
                            script.get('executable') == '/Applications/HoRNDIS Status.app/Contents/Resources/horndis-uninstall'):
                        return self.record
        if not self.uninstaller.is_file() or not os.access(self.uninstaller, os.X_OK):
            raise RuntimeError('The reviewed compatibility uninstaller is unavailable')
        for path in existing + [receipt]:
            metadata = path.stat()
            self.originals[path] = (path.read_bytes(), stat.S_IMODE(metadata.st_mode),
                                    metadata.st_atime_ns, metadata.st_mtime_ns)
        self.replacement = directory/'horndis.json'
        definition = {'version': timestamp.parent.name, 'artifacts': [{'uninstall': [{
            'script': {'executable': str(self.uninstaller), 'args': ['--keep-network-service'], 'sudo': True},
            'pkgutil': 'io.github.noahhhi.horndis.pkg',
        }]}]}
        self.replacement_bytes = (json.dumps(definition, indent=2) + '\n').encode()
        receipt_value['uninstall_artifacts'] = definition['artifacts']
        receipt_value['uninstall_flight_blocks'] = False
        receipt_bytes = (json.dumps(receipt_value, indent=2) + '\n').encode()
        self.backup_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        backup = self.backup_directory/('installed-cask-' + uuid.uuid4().hex)
        backup.mkdir(mode=0o700)
        for path, original in self.originals.items():
            atomic_write(backup/path.name, original[0])
        self.record.update(needed=True, backup=str(backup), installed_cask=str(self.replacement))
        atomic_write(backup/'migration.json', (json.dumps(self.record, indent=2) + '\n').encode())
        for path, original in self.originals.items():
            if path.read_bytes() != original[0]:
                raise RuntimeError('Installed-cask metadata changed concurrently')
        atomic_write(self.replacement, self.replacement_bytes)
        self.writes[self.replacement] = self.replacement_bytes
        atomic_write(receipt, receipt_bytes, self.originals[receipt][1])
        self.writes[receipt] = receipt_bytes
        for path in existing:
            if path != self.replacement:
                path.unlink()
                self.removed.append(path)
        return self.record

    def restore_if_unused(self):
        # A successful replacement creates new timestamped metadata. Restore
        # only our exact old definition after a failed/skipped install.
        if not self.writes:
            return False
        if any(not p.exists() or p.read_bytes() != data for p, data in self.writes.items()):
            return False
        if any(p.exists() for p in self.removed):
            return False
        for path, original in self.originals.items():
            data, mode, accessed, modified = original
            atomic_write(path, data, mode)
            os.utime(path, ns=(accessed, modified))
        if self.replacement not in self.originals:
            self.replacement.unlink()
        return True
