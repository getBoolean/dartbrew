#!/usr/bin/env python3
"""Configure compatible Linux generators and CTR runtime graphs separately."""
import argparse
import json
from pathlib import Path
import sys

from common import (DEFAULT_MANIFEST, DEFAULT_PROFILE, DEFAULT_SOURCE, ROOT,
                    build_identity, command, file_hash, read_json, verify_icu, verify_source)


def gn_value(value):
    return json.dumps(value, separators=(',', ':'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['identity', 'configure', 'build'])
    parser.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument('--profile', type=Path, default=DEFAULT_PROFILE)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--component', choices=['host', 'precompiler', 'target', 'probe'], required=True)
    parser.add_argument('--mode', choices=['aot', 'jit'], required=True)
    parser.add_argument('--output-root', type=Path)
    parser.add_argument('--target', action='append', help='explicit Ninja target; repeatable')
    parser.add_argument('--jobs', type=int, default=2, help='maximum concurrent Ninja jobs (default: 2)')
    parser.add_argument('--check-includes', action='store_true',
                        help='also run upstream GN include ownership checks')
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    identity = build_identity(args.manifest, args.profile, args.component, args.mode)
    if args.action == 'identity':
        print(json.dumps(identity, sort_keys=True))
        return
    if sys.platform != 'linux':
        raise RuntimeError('SDK configuration/build requires native Linux x64 or Ubuntu WSL')
    source = args.source.resolve()
    verify_source(source, read_json(args.manifest))
    verify_icu(source, read_json(args.manifest))
    gn = source / 'buildtools' / 'gn'
    if not gn.is_file():
        raise RuntimeError(f'pinned GN unavailable: {gn}; bootstrap with --sync-deps first')
    manifest = read_json(args.manifest)
    if file_hash(gn) != manifest['dependencies']['gn']['hosts']['linux-x64']['binary_sha256']:
        raise RuntimeError(f'GN hash mismatch: {gn}; restore the pinned dependency')
    output_root = args.output_root.resolve() if args.output_root else source / 'out' / 'ctr'
    out = output_root / f"{args.component}-{args.mode}-{identity['cache_key'][:16]}"
    out.mkdir(parents=True, exist_ok=True)
    gn_args = '\n'.join(f'{key} = {gn_value(value)}' for key, value in sorted(identity['gn_args'].items()))
    if args.component != 'host':
        profile = read_json(args.profile)
        paths = [(args.profile.resolve().parent / path).resolve() for path in profile['link_specs']]
        if len(paths) != 1:
            raise RuntimeError('CTR GN configuration requires one composed specs file')
        config = {'ctr_compiler_prefix': profile['compiler_prefix'],
                  'ctr_libctru': profile['libctru'], 'ctr_cflags': profile['cflags'],
                  'ctr_specs_file': str(paths[0])}
        gn_args += '\n' + '\n'.join(f'{key} = {gn_value(value)}' for key, value in config.items())
    (out / 'args.gn').write_text(gn_args + '\n')
    (out / 'compatibility.json').write_text(json.dumps(identity, indent=2, sort_keys=True) + '\n')
    checks = ['--check'] if args.component == 'probe' or args.check_includes else []
    command([gn, 'gen', out, *checks, '--fail-on-unused-args',
             '--root-target=' + identity['root_target']], cwd=source, capture=False)
    if args.action == 'build':
        targets = args.target or [identity['root_target'].removeprefix('//').removeprefix(':')]
        ninja = source / 'buildtools' / 'ninja' / 'ninja'
        if not ninja.is_file():
            raise RuntimeError(f'pinned Ninja unavailable: {ninja}; bootstrap with --sync-deps first')
        command([ninja, '-j', str(args.jobs), '-C', out, *targets], cwd=source, capture=False)
    print(json.dumps({'output': str(out), **identity}, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
