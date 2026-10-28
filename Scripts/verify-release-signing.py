#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reject release builds whose local-network privacy identity is unstable."""
import argparse
from pathlib import Path
import re
import subprocess


def verify(build):
    build = Path(build)
    app = build / 'HoRNDISStatus.app'
    components = [
        (build / 'horndis', 'horndis'),
        (app, 'io.github.noahhhi.horndis.status'),
        (app / 'Contents/Helpers/horndis-surge-agent', 'horndis-surge-agent'),
        (app / 'Contents/Resources/horndis', 'horndis'),
    ]
    teams = set()
    for path, expected_identifier in components:
        metadata = subprocess.run(
            ['/usr/bin/codesign', '--display', '--verbose=4', str(path)],
            capture_output=True, text=True, check=True).stderr
        fields = dict(line.split('=', 1) for line in metadata.splitlines() if '=' in line)
        team = fields.get('TeamIdentifier', '')
        if fields.get('Signature') == 'adhoc' or not re.fullmatch(r'[A-Z0-9]{10}', team):
            raise ValueError(f'{path}: an Apple-issued SIGNING_IDENTITY is required; '
                             'ad-hoc signing cannot reliably preserve local-network permission.')
        if fields.get('Identifier') != expected_identifier:
            raise ValueError(f'{path}: signing identifier must remain {expected_identifier}.')
        # A team-like string alone is not proof of an Apple-issued signature.
        # Check every architecture against the same identifier and certificate
        # team, including slices not selected by codesign's metadata display.
        requirement = (f'anchor apple generic and identifier "{expected_identifier}" '
                       f'and certificate leaf[subject.OU] = "{team}"')
        subprocess.run(
            ['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures',
             '-R=' + requirement, str(path)],
            capture_output=True, text=True, check=True)
        teams.add(team)
    if len(teams) != 1:
        raise ValueError('The application and helpers must use the same Apple signing team.')
    return teams.pop()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build', type=Path)
    args = parser.parse_args()
    try:
        team = verify(args.build)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release signing check failed: {error}\n')
    print(f'Release signing verified: stable identifiers, Apple certificates, team {team}.')
