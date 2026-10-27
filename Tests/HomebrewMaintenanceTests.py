#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
from pathlib import Path
import importlib.util
import json
import tempfile
import unittest

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('maintenance', root/'Scripts/homebrew-maintenance.py')
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='horndis-cask-test-')
        self.addCleanup(self.work.cleanup)
        self.base = Path(self.work.name)
        self.caskroom = self.base/'horndis'
        self.metadata = self.caskroom/'.metadata/0.3.9/20261001000000/Casks'
        self.metadata.mkdir(parents=True)
        self.receipt = self.caskroom/'.metadata/INSTALL_RECEIPT.json'
        self.receipt.write_text(json.dumps({'uninstall_artifacts': [{'uninstall': [{
            'script': {'executable':'/Applications/HoRNDIS Status.app/Contents/Resources/horndis-uninstall', 'sudo':True},
            'pkgutil':'io.github.noahhhi.horndis.pkg'}]}]}))
        self.script = self.base/'horndis-uninstall'
        self.script.write_text('#!/bin/zsh\nexit 0\n')
        self.script.chmod(0o700)
        self.migration = maintenance.InstalledCaskMigration(
            self.caskroom, self.script, self.base/'backups')

    def test_legacy_json_becomes_runtime_cleanup_and_keeps_old_version(self):
        old = self.metadata/'horndis.json'
        old.write_bytes(b'{}')
        self.migration.prepare()
        source = json.loads(old.read_text())
        self.assertEqual(source['version'], '0.3.9')
        self.assertEqual(source['artifacts'][0]['uninstall'][0]['script']['executable'], str(self.script))
        self.assertEqual(source['artifacts'][0]['uninstall'][0]['script']['args'], ['--keep-network-service'])
        self.assertEqual(json.loads(self.receipt.read_text())['uninstall_artifacts'], source['artifacts'])
        self.assertEqual((Path(self.migration.record['backup'])/'horndis.json').read_bytes(), b'{}')

    def test_failed_or_skipped_install_restores_original_bytes_and_timestamp(self):
        old = self.metadata/'horndis.json'
        old.write_bytes(b'{"artifacts": []}')
        before = old.stat()
        receipt_before = self.receipt.read_bytes()
        self.migration.prepare()
        self.assertTrue(self.migration.restore_if_unused())
        self.assertEqual(old.read_bytes(), b'{"artifacts": []}')
        self.assertEqual(old.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(self.receipt.read_bytes(), receipt_before)
        self.assertFalse((self.metadata/'horndis.rb').exists())

    def test_legacy_ruby_can_be_restored(self):
        old = self.metadata/'horndis.rb'
        old.write_text('cask "horndis" do\nend\n')
        self.migration.prepare()
        self.assertTrue(self.migration.restore_if_unused())
        self.assertEqual(old.read_text(), 'cask "horndis" do\nend\n')

    def test_modern_installed_cleanup_is_untouched(self):
        old = self.metadata/'horndis.json'
        original = json.dumps({'artifacts':[{'uninstall':[{'script':{
            'executable':'/Applications/HoRNDIS Status.app/Contents/Resources/horndis-uninstall',
            'args':['--homebrew']}}]}]}).encode()
        old.write_bytes(original)
        self.receipt.write_bytes(json.dumps({'uninstall_artifacts':json.loads(original)['artifacts']}).encode())
        self.assertFalse(self.migration.prepare()['needed'])
        self.assertEqual(old.read_bytes(), original)

    def test_concurrent_installed_metadata_is_not_overwritten(self):
        (self.metadata/'horndis.json').write_bytes(b'{}')
        self.migration.prepare()
        replacement = self.metadata/'horndis.json'
        replacement.write_text('new installation')
        self.assertFalse(self.migration.restore_if_unused())
        self.assertEqual(replacement.read_text(), 'new installation')

    def test_completed_reinstall_is_not_rolled_back(self):
        (self.metadata/'horndis.json').write_bytes(b'{}')
        self.migration.prepare()
        (self.metadata/'horndis.json').unlink()
        self.assertFalse(self.migration.restore_if_unused())

    def test_concurrent_receipt_edit_is_not_overwritten(self):
        (self.metadata/'horndis.json').write_bytes(b'{}')
        self.migration.prepare()
        self.receipt.write_bytes(b'{"concurrent":true}')
        self.assertFalse(self.migration.restore_if_unused())
        self.assertEqual(self.receipt.read_bytes(), b'{"concurrent":true}')

    def test_symbolic_link_metadata_is_rejected(self):
        other = self.base/'keep.json'
        other.write_bytes(b'keep')
        (self.metadata/'horndis.json').symlink_to(other)
        with self.assertRaises(RuntimeError):
            self.migration.prepare()
        self.assertEqual(other.read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
