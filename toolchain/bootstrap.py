#!/usr/bin/env python3
"""Materialize pinned sources without changing an existing unmanaged/dirty tree."""
import argparse
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import sys
import urllib.request
import zipfile

from common import (DEFAULT_MANIFEST, DEFAULT_SOURCE, ROOT, command, file_hash, git,
                    patch_inputs, source_identity, source_inputs, verify_icu, verify_source)

GN_DOWNLOAD_TIMEOUT_SECONDS = 120


@dataclass(frozen=True)
class Host:
    """A supported build host; `name` keys the GN pin table."""
    os: str
    cpu: str

    @property
    def name(self):
        return f'{self.os}-{self.cpu}'

    @property
    def is_windows(self):
        return self.os == 'windows'

    @property
    def gclient(self):
        return 'gclient.bat' if self.is_windows else 'gclient'

    @property
    def gn(self):
        return 'gn.exe' if self.is_windows else 'gn'


def current_host(manifest, system=None, machine=None):
    system = system or platform.system()
    machine = (machine or platform.machine()).lower()
    host = Host({'Windows': 'windows', 'Darwin': 'macos', 'Linux': 'linux'}.get(system),
                {'amd64': 'x64', 'x86_64': 'x64', 'arm64': 'arm64', 'aarch64': 'arm64'}.get(machine))
    if host.name not in manifest['dependencies']['gn']['hosts']:
        raise RuntimeError(f'unsupported host: {system}/{machine}')
    return host


def gn_pin(manifest, host):
    """The pinned GN package for `host`, with the table's shared revision."""
    pins = manifest['dependencies']['gn']
    return {'revision': pins['revision'], **pins['hosts'][host.name]}


def materialize(source, manifest, patches):
    source = Path(source).resolve()
    if source.exists():
        return verify_source(source, manifest)
    source.mkdir(parents=True)
    # Failure leaves the new directory for inspection. Never reset/clean caller state.
    git(source, 'init', '--quiet')
    git(source, 'remote', 'add', 'origin', manifest['dart']['repository'])
    git(source, 'fetch', '--quiet', '--depth=1', 'origin', manifest['dart']['revision'])
    git(source, 'checkout', '--quiet', '--detach', manifest['dart']['revision'])
    return apply_patches(source, manifest, patches)


def apply_patches(source, manifest, patches):
    env = os.environ.copy()
    env.update({'GIT_AUTHOR_NAME': 'CTR SDK patches', 'GIT_AUTHOR_EMAIL': 'ctr-sdk@example.invalid',
                'GIT_COMMITTER_NAME': 'CTR SDK patches', 'GIT_COMMITTER_EMAIL': 'ctr-sdk@example.invalid',
                'GIT_AUTHOR_DATE': '2000-01-01T00:00:00Z', 'GIT_COMMITTER_DATE': '2000-01-01T00:00:00Z'})
    for path, patch in patches:
        git(source, 'apply', '--check', path)
        git(source, 'apply', '--index', path)
        git(source, '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--no-verify',
            '-m', f"Apply CTR patch {patch['path']}\n\nSHA256: {patch['sha256']}", env=env)
    state = {'inputs': source_identity(manifest), 'head': git(source, 'rev-parse', 'HEAD'),
             'upstream_revision': manifest['dart']['revision'], 'patches': manifest['patches']}
    (source / '.git' / 'ctr-source.json').write_text(json.dumps(state, indent=2) + '\n')
    return verify_source(source, manifest)


def icu_inputs(source, pin):
    return Path(source) / 'third_party' / 'icu', {'dart': pin, 'patches': pin['patches']}


def icu_needs_patches(source, pin):
    """False for an already patched ICU; True for a clean checkout at the pin; else raises."""
    dependency, inputs = icu_inputs(source, pin)
    if git(dependency, 'status', '--porcelain', '--untracked-files=all'):
        raise RuntimeError(f'dirty ICU checkout: {dependency}; preserve/export edits before retrying')
    if git(dependency, 'rev-parse', 'HEAD') != pin['revision']:
        verify_source(dependency, inputs)
        return False
    return True


def patch_icu(source, manifest, manifest_path):
    pin = manifest.get('dependencies', {}).get('icu')
    if not pin:
        return
    dependency, inputs = icu_inputs(source, pin)
    patches = patch_inputs(manifest_path, pin['patches'])
    if not icu_needs_patches(source, pin):
        return verify_source(dependency, inputs)
    return apply_patches(dependency, inputs, patches)


def depot_tools_environment(depot):
    env = os.environ.copy()
    env.update(PATH=str(depot) + os.pathsep + env.get('PATH', ''),
               DEPOT_TOOLS_UPDATE='0', DEPOT_TOOLS_METRICS='0', DEPOT_TOOLS_WIN_TOOLCHAIN='0')
    count = int(env.get('GIT_CONFIG_COUNT', '0'))
    env.update(GIT_CONFIG_COUNT=str(count + 1),
               **{f'GIT_CONFIG_KEY_{count}': 'core.autocrlf', f'GIT_CONFIG_VALUE_{count}': 'false'})
    return env


def gclient_config(source, manifest):
    return 'solutions = ' + repr([dict(
        name=source.name, url=manifest['dart']['repository'], managed=False, custom_deps={},
        custom_vars={**manifest['dependencies']['gclient_variables'], 'dart_root': source.name})]) + '\n'


def write_gclient_config(source, manifest):
    path = source.parent / '.gclient'
    expected = gclient_config(source, manifest)
    if path.exists() and path.read_text(encoding='utf-8') != expected:
        raise RuntimeError(f'unmanaged or mismatched gclient configuration: {path}')
    path.write_text(expected, encoding='utf-8')


def sync_dependencies(source, manifest, depot, manifest_path, host):
    """Run gclient sync and hooks for `host`; returns the depot_tools environment."""
    pin = manifest['dependencies']['dart_deps']
    actual = file_hash(source / pin['path'])
    if actual != pin['sha256']:
        raise RuntimeError(f"DEPS hash mismatch: expected {pin['sha256']}, got {actual}")
    # Check ICU before gclient can change its checkout. Never reset dirty state.
    icu = manifest['dependencies'].get('icu')
    if icu and icu_inputs(source, icu)[0].exists():
        icu_needs_patches(source, icu)
    write_gclient_config(source, manifest)
    materialize(depot, {'dart': manifest['dependencies']['depot_tools'], 'patches': []}, [])
    env = depot_tools_environment(depot)
    gclient = depot / host.gclient
    command([gclient, 'sync', '--no-history', '--shallow', '--nohooks'],
            cwd=source.parent, env=env, capture=False)
    command([gclient, 'runhooks'], cwd=source.parent, env=env, capture=False)
    patch_icu(source, manifest, manifest_path)
    verify_icu(source, manifest)
    verify_source(source, manifest)
    return env


def checked_gn_bytes(archive, pin, filename):
    if hashlib.sha256(archive).hexdigest() != pin['archive_sha256']:
        raise RuntimeError('GN archive hash mismatch')
    with zipfile.ZipFile(io.BytesIO(archive)) as package:
        data = package.read(filename)
    if hashlib.sha256(data).hexdigest() != pin['binary_sha256']:
        raise RuntimeError('GN binary hash mismatch')
    return data


def fetch_gn(directory, manifest, host):
    """Install `host`'s pinned GN into `directory`; returns its path and pin."""
    pin = gn_pin(manifest, host)
    destination = directory / host.gn
    if destination.exists():
        if file_hash(destination) != pin['binary_sha256']:
            raise RuntimeError(f'existing GN hash mismatch: {destination}')
        return destination, pin
    url = 'https://chrome-infra-packages.appspot.com/dl/' + pin['package'] + '/+/' + pin['revision']
    with urllib.request.urlopen(url, timeout=GN_DOWNLOAD_TIMEOUT_SECONDS) as response:
        data = checked_gn_bytes(response.read(), pin, host.gn)
    directory.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    destination.chmod(0o755)
    return destination, pin


def verify(source, manifest_path):
    """Check a checkout against the pins without changing it; returns its source state."""
    manifest, _ = source_inputs(manifest_path)
    state = verify_source(source, manifest)
    verify_icu(source, manifest)
    return state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--sync-deps', action='store_true')
    parser.add_argument('--fetch-gn', action='store_true',
                        help="fetch this host's pinned GN into the checkout's buildtools")
    parser.add_argument('--depot-tools', type=Path, default=ROOT / 'third_party' / 'depot_tools')
    actions = parser.add_subparsers(dest='action')
    verify_parser = actions.add_parser(
        'verify', help='exit non-zero unless the checkout, patches and ICU match the pins')
    # Suppressed defaults keep options given before the subcommand.
    verify_parser.add_argument('--manifest', type=Path, default=argparse.SUPPRESS)
    verify_parser.add_argument('--source', type=Path, default=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.action == 'verify':
        print(json.dumps(verify(args.source.resolve(), args.manifest), sort_keys=True))
        return
    manifest, patches = source_inputs(args.manifest)
    state = materialize(args.source, manifest, patches)
    if args.fetch_gn:
        fetch_gn(args.source.resolve() / 'buildtools', manifest, current_host(manifest))
    if args.sync_deps:
        sync_dependencies(args.source.resolve(), manifest, args.depot_tools.resolve(), args.manifest,
                          current_host(manifest))
    print(json.dumps(state, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
