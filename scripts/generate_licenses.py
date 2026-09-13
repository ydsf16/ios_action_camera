#!/usr/bin/env python3
"""Collect notices for the locked iOS dependency graph, without inventing notices."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
metadata = json.loads(subprocess.check_output([
    str(Path.home() / '.cargo/bin/cargo'), 'metadata', '--manifest-path',
    str(ROOT / 'Engine/Cargo.toml'), '--format-version', '1', '--locked',
    '--offline', '--filter-platform', 'aarch64-apple-ios']))
texts = {}
inventory = []

def add_text(label, value):
    digest = hashlib.sha256(value.encode()).hexdigest()[:16]
    texts.setdefault(digest, {'text': value, 'labels': []})['labels'].append(label)
    return digest

for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
    if package['name'] == 'roamshot-gyroflow':
        continue
    name = f"{package['name']} {package['version']}"
    directory = Path(package['manifest_path']).parent
    license_files = []
    for parent in (directory, *directory.parents):
        if parent in (Path.home(), Path('/')):
            break
        if parent == directory or (parent / '.git').exists():
            license_files = sorted(f for f in parent.iterdir() if f.is_file()
                and f.name.upper().startswith(('LICENSE', 'LICENCE', 'COPYING', 'NOTICE')))
        if license_files:
            break
    references = []
    provenance = ROOT / 'docs/licenses' / f"{package['name']}-{package['version']}" / 'provenance.json'
    if license_files:
        for file in license_files:
            references.append(add_text(f'{name}: {file.name}', file.read_text()))
        origin = 'Notices included in the locked source distribution or its repository root.'
    elif provenance.exists():
        upstream = json.loads(provenance.read_text())
        for file in upstream['files']:
            references.append(add_text(f'{name}: {file["name"]}',
                (provenance.parent / file['name']).read_text()))
        origin = 'Upstream notice files: ' + ', '.join(file['url'] for file in upstream['files'])
    else:
        declared = package['license']
        chosen = 'Apache-2.0' if declared and 'Apache-2.0' in declared else declared
        standard = ROOT / 'docs/licenses' / f'{chosen}.txt'
        if not standard.is_file():
            raise RuntimeError(f'Missing notice or standard license: {name}, {declared}')
        references.append(add_text(f'{name}: standard {chosen} text', standard.read_text()))
        origin = (f'The published source declares {declared} and supplies no separate notice file. '
                  f'Standard {chosen} text is reproduced; author metadata below is from Cargo.toml. '
                  'Placeholder copyright fields in standard license templates are not assertions of authorship.')
    inventory.append('\n'.join([
        name, f"Source: {package.get('repository') or package.get('homepage') or package['source']}",
        f"Declared license: {package['license'] or 'See supplied notice'}",
        'Authors: ' + (', '.join(package['authors']) or 'Not specified in package metadata'),
        origin, 'License text references: ' + ', '.join(references)]))

output = ['RoamShot third-party dependency notices',
    'Generated from Engine/Cargo.lock for aarch64-apple-ios. The inventory includes build dependencies. '
    'Identical texts are printed once and referenced by content digest. '
    'Application and Gyroflow integration details are in THIRD_PARTY_NOTICES.md.\n',
    '\n\n'.join(inventory), '\n\nFULL LICENSE AND NOTICE TEXTS\n']
for digest, entry in sorted(texts.items()):
    output.append('\n'.join(['=' * 72, digest, *entry['labels'], '-' * 72, entry['text']]))
(ROOT / 'THIRD_PARTY_LICENSES.txt').write_text('\n\n'.join(output))
print(f'Collected {len(inventory)} dependency entries, {len(texts)} distinct notice texts')
