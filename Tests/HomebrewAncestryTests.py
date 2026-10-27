#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise the kernel argv reader through harmless real interpreter processes."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

helper = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path('build/horndis').resolve()


@unittest.skipUnless(Path('/usr/bin/ruby').is_file(), 'macOS system Ruby is unavailable')
class AncestryTests(unittest.TestCase):
    def test_live_kernel_arguments_and_intervening_process(self):
        with tempfile.TemporaryDirectory(prefix='horndis-ancestry-') as directory:
            root = Path(directory)
            # No real Homebrew commands run. The Ruby fixture only launches a
            # read-only helper through another process, just like sudo/launchctl.
            brew = root/'Library/Homebrew/brew.rb'
            brew.parent.mkdir(parents=True)
            middle = root/'middle.py'
            middle.write_text('import subprocess,sys\nsys.exit(subprocess.call([sys.argv[1], "maintenance-mode"]))\n')
            brew.write_text('exit(system("/usr/bin/python3", ARGV.fetch(2), ARGV.fetch(1)) ? 0 : 1)\n')
            for operation in ['install', 'reinstall', 'upgrade', 'bundle', 'uninstall', 'remove', 'rm', 'unknown']:
                with self.subTest(operation=operation):
                    result = subprocess.run(['/usr/bin/ruby', str(brew), operation, str(helper), str(middle)],
                                            capture_output=True, text=True, check=True, timeout=8)
                    self.assertEqual(result.stdout.strip(), 'remove' if operation in ['uninstall','remove','rm'] else 'keep')
            other = root/'other.rb'
            other.write_text(brew.read_text())
            result = subprocess.run(['/usr/bin/ruby', str(other), 'uninstall', str(helper), str(middle)],
                                    capture_output=True, text=True, check=True, timeout=8)
            self.assertEqual(result.stdout.strip(), 'keep')


if __name__ == '__main__':
    unittest.main()
