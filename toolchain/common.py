"""Shared identity and checked subprocess operations for the CTR SDK tools."""
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
DEFAULT_MANIFEST = HERE / 'versions.json'
DEFAULT_SOURCE = ROOT / 'third_party' / 'dart-sdk'


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def file_hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command(args, cwd=None, env=None, capture=True):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(map(str, args))}\n"
                           f"{result.stderr or ''}")
    return result.stdout.strip() if capture else ''


def git(source, *args, env=None):
    return command(['git', '-c', 'core.autocrlf=false', '-c', 'core.safecrlf=false',
                    '-c', 'core.hooksPath=', '-C', source, *args], env=env)


def patch_inputs(manifest_path, entries):
    manifest_path = Path(manifest_path).resolve()
    patches = []
    for patch in entries:
        path = (manifest_path.parent / patch['path']).resolve()
        actual = file_hash(path)
        if actual != patch['sha256']:
            raise RuntimeError(f"patch hash mismatch: {path}; expected {patch['sha256']}, got {actual}")
        patches.append((path, patch))
    return patches


def source_inputs(manifest_path):
    manifest = read_json(manifest_path)
    patches = patch_inputs(manifest_path, manifest['patches'])
    if 'icu' in manifest.get('dependencies', {}):
        patch_inputs(manifest_path, manifest['dependencies']['icu']['patches'])
    return manifest, patches


def verify_icu(source, manifest):
    pin = manifest.get('dependencies', {}).get('icu')
    if pin:
        return verify_source(Path(source) / 'third_party' / 'icu',
                             {'dart': pin, 'patches': pin['patches']})


def source_identity(manifest):
    return {'repository': manifest['dart']['repository'],
            'upstream_revision': manifest['dart']['revision'],
            'patches': manifest['patches']}


def verify_source(source, manifest):
    source = Path(source)
    state_path = source / '.git' / 'ctr-source.json'
    if not state_path.is_file():
        raise RuntimeError(f"unmanaged source directory: {source}; choose an absent directory")
    if git(source, 'status', '--porcelain', '--untracked-files=all'):
        raise RuntimeError(f"dirty source checkout: {source}; preserve/export edits before retrying")
    state = read_json(state_path)
    if state['inputs'] != source_identity(manifest) or git(source, 'rev-parse', 'HEAD') != state['head']:
        raise RuntimeError(f"source checkout mismatch: {source}; choose a new source directory")
    return state
