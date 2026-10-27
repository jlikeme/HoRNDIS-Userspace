#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate a cask bound to the exact package, including maintenance cleanup."""
from pathlib import Path
import argparse
import hashlib
import re


def ruby_string(value):
    if '\n' in value or '\r' in value:
        raise ValueError('Cask values cannot contain line breaks')
    return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"


def generate(version, package, url=None):
    if not re.fullmatch(r'[0-9][0-9A-Za-z.+,_-]*', version):
        raise ValueError('Invalid package version')
    package = Path(package).resolve()
    source = (Path(__file__).resolve().parent.parent/'Packaging/horndis.rb.in').read_text()
    values = {'VERSION': version, 'SHA256': hashlib.sha256(package.read_bytes()).hexdigest(),
              'URL': url or package.as_uri(), 'PACKAGE': package.name}
    for key, value in values.items():
        source = source.replace('@' + key + '@', ruby_string(value))
    return source


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--package', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--url')
    options = parser.parse_args()
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(generate(options.version, options.package, options.url))
