#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'release_signing', Path(__file__).resolve().parent.parent / 'Scripts/verify-release-signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class ReleaseSigningTests(unittest.TestCase):
    def run_check(self, *, adhoc=False, identifier=None, mixed_team=False, invalid_chain=False):
        calls = []

        def codesign(command, **kwargs):
            calls.append(command)
            path = Path(command[-1])
            if '--display' in command:
                expected = 'io.github.noahhhi.horndis.status' if path.name.endswith('.app') else path.name
                team = 'OTHERT1234' if mixed_team and path.name == 'horndis-surge-agent' else 'TEAM123456'
                metadata = f'Identifier={identifier or expected}\nTeamIdentifier={team}\n'
                metadata += 'Signature=adhoc\n' if adhoc else 'Signature size=4814\n'
                return subprocess.CompletedProcess(command, 0, '', metadata)
            self.assertIn('--all-architectures', command)
            requirement = next(value for value in command if value.startswith('-R='))
            self.assertIn('anchor apple generic and identifier "', requirement)
            self.assertIn('certificate leaf[subject.OU]', requirement)
            if invalid_chain:
                raise subprocess.CalledProcessError(1, command, stderr='code failed to satisfy specified code requirement(s)')
            return subprocess.CompletedProcess(command, 0, '', '')

        with patch.object(signing.subprocess, 'run', side_effect=codesign):
            team = signing.verify(Path('/isolated-build'))
        return team, calls

    def test_apple_signed_app_and_all_helpers_pass(self):
        team, calls = self.run_check()
        self.assertEqual(team, 'TEAM123456')
        self.assertEqual(sum('--verify' in call for call in calls), 4)

    def test_ad_hoc_release_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'ad-hoc signing'):
            self.run_check(adhoc=True)

    def test_generated_identifier_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'signing identifier'):
            self.run_check(identifier='horndis-55554944-random-build-id')

    def test_mixed_signing_teams_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'same Apple signing team'):
            self.run_check(mixed_team=True)

    def test_non_apple_certificate_cannot_pass_with_a_team_string(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_check(invalid_chain=True)


if __name__ == '__main__':
    unittest.main()
