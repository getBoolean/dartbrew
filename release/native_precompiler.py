#!/usr/bin/env python3
"""Producer-only native CTR gen_snapshot build; never shipped as an SDK launcher."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from contextlib import contextmanager

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'toolchain'))
from bootstrap import current_host, fetch_gn, materialize, sync_dependencies
from common import DEFAULT_MANIFEST, command, file_hash, source_inputs, verify_icu, verify_source

ROOT_TARGET = '//runtime/bin:gen_snapshot'
REQUIRED_DEFINES = {'DART_TARGET_OS_CTR', 'TARGET_ARCH_ARM', 'DART_TARGET_ARMV6K'}


@contextmanager
def producer_overlay(source):
    source = Path(source)
    graph = source / 'runtime/bin/BUILD.gn'
    os_source = source / 'runtime/vm/os_macos.cc'
    helper = source / 'runtime/bin/ctr_stable_sort.c'
    if helper.exists():
        raise RuntimeError('producer helper already exists; preserve the checkout')
    original = {path: path.read_bytes() for path in (graph, os_source)}
    graph_anchor = b'      "gen_snapshot.cc",\n'
    os_anchor = b'intptr_t OS::ActivationFrameAlignment() {\n'
    os_end = b'#endif  // DART_HOST_OS_IOS\n}\n\nuintptr_t OS::CurrentRSS() {'
    if (original[graph].count(graph_anchor) != 1 or original[os_source].count(os_anchor) != 1
            or original[os_source].count(os_end) != 1):
        raise RuntimeError('producer overlay source anchors differ from the pinned SDK')
    changed = {
        graph: original[graph].replace(graph_anchor, graph_anchor + b'      "ctr_stable_sort.c",\n'),
        os_source: original[os_source].replace(os_anchor, os_anchor +
            b'#if defined(DART_TARGET_OS_CTR)\n  return 8;\n#else\n').replace(
                os_end, b'#endif  // DART_HOST_OS_IOS\n#endif  // DART_TARGET_OS_CTR\n}\n\nuintptr_t OS::CurrentRSS() {'),
        helper: Path(__file__).with_name('native_stable_sort.c').read_bytes(),
    }
    receipt = dict(kind='native-sort-and-target-alignment-v1',
                   files={path.relative_to(source).as_posix(): dict(
                       base_sha256=hashlib.sha256(original[path]).hexdigest() if path in original else None,
                       compiler_sha256=hashlib.sha256(content).hexdigest())
                       for path, content in changed.items()})
    try:
        for path, content in changed.items():
            if path == helper:
                with path.open('xb') as stream:
                    stream.write(content)
            else:
                path.write_bytes(content)
        yield receipt
    finally:
        if any(not path.is_file() or path.read_bytes() != content for path, content in changed.items()):
            raise RuntimeError('producer overlay files changed; preserved all sources for inspection')
        for path, content in original.items():
            path.write_bytes(content)
        helper.unlink()


def gn_arguments(host):
    current_os = {'windows': 'win', 'macos': 'mac', 'linux': 'linux'}[host.os]
    arguments = dict(target_os='ctr', target_cpu=host.cpu, current_os=current_os, current_cpu=host.cpu,
                dart_target_arch='arm', dart_armv6k=True, dart_use_compressed_pointers=False,
                dart_use_crashpad=False, dart_support_perfetto=False, is_clang=True,
                is_debug=False, is_release=True)
    if host.os == 'macos':
        # The SDK's relative-sysroot helper assumes an in-source output folder.
        # Producer graphs are out of tree; select the actual Xcode SDK instead.
        arguments['mac_enable_relative_sdk_path'] = False
    return arguments


def generated_identity(text, source_head):
    result = {}
    for name, field, length in [('snapshot_hash_', 'snapshot_hash', 32),
                                ('git_short_hash_', 'git_short_hash', 10)]:
        values = re.findall(r'Version::' + name + r'\s*=\s*"([0-9a-f]+)";', text)
        if len(values) != 1 or len(values[0]) != length:
            raise RuntimeError(f'missing or ambiguous generated {field}')
        result[field] = values[0]
    if result['git_short_hash'] != source_head[:10]:
        raise RuntimeError('generated SDK hash does not match patched source HEAD')
    return result


def verify_definitions(text):
    definitions = set(text.split())
    missing = REQUIRED_DEFINES - definitions
    if missing:
        raise RuntimeError(f'gen_snapshot missing CTR compiler definitions: {sorted(missing)}')
    return sorted(REQUIRED_DEFINES)


def build(work, output, manifest_path, jobs):
    # Output was byte-identical from -j2 through -j16; the bound only rejects typos.
    if not 1 <= jobs <= 8:
        raise RuntimeError('producer jobs must be between 1 and 8')
    if output.exists():
        raise RuntimeError(f'output already exists: {output}; choose an absent directory')
    manifest, patches = source_inputs(manifest_path)
    host = current_host(manifest)
    source, depot = work / 'sdk', work / 'depot_tools'
    state = materialize(source, manifest, patches)
    env = sync_dependencies(source, manifest, depot, manifest_path, host)
    gn, gn_pin = fetch_gn(work / 'native-gn', manifest, host)
    build_dir = work / 'native-build'
    args = gn_arguments(host)
    args_text = '\n'.join(f'{key} = {json.dumps(value)}' for key, value in sorted(args.items())) + '\n'
    build_dir.mkdir(parents=True, exist_ok=True)
    args_path = build_dir / 'args.gn'
    if args_path.exists() and args_path.read_text(encoding='utf-8') != args_text:
        raise RuntimeError('existing native build arguments differ; choose a fresh work directory')
    args_path.write_text(args_text, encoding='utf-8')
    suffix = '.exe' if host.is_windows else ''
    ninja = source / 'buildtools' / 'ninja' / ('ninja' + suffix)
    compiler_os = {'windows': 'win', 'macos': 'mac', 'linux': 'linux'}[host.os]
    compiler_name = 'clang-cl.exe' if host.is_windows else 'clang'
    clang = source / 'buildtools' / f'{compiler_os}-{host.cpu}' / 'clang' / 'bin' / compiler_name
    compiler_version = command([clang, '--version'], env=env)
    ninja_version = command([ninja, '--version'], env=env)
    with producer_overlay(source) as overlay:
        command([gn, 'gen', build_dir, '--fail-on-unused-args', '--root-target=' + ROOT_TARGET],
                cwd=source, env=env, capture=False)
        defines = verify_definitions(command([gn, 'desc', build_dir, ROOT_TARGET, 'defines'],
                                             cwd=source, env=env))
        command([ninja, '-C', build_dir, '-j', jobs, 'gen_snapshot'],
                cwd=source, env=env, capture=False)
    versions = list(build_dir.rglob('gen/runtime/version.cc'))
    if len(versions) != 1:
        raise RuntimeError(f'expected one generated version.cc, found {len(versions)}')
    identity = generated_identity(versions[0].read_text(encoding='utf-8'), state['head'])
    executable = build_dir / ('gen_snapshot' + suffix)
    probe = subprocess.run([str(executable), '--version'], env=env, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if probe.returncode:
        raise RuntimeError(f'native gen_snapshot --version failed ({probe.returncode}): {probe.stderr}')
    verify_source(source, manifest)
    icu_state = verify_icu(source, manifest)
    receipt = dict(schema_version=1, component='native-ctr-gen-snapshot', host=host.name,
                   target='ctr-armv6k', source=state, icu=icu_state, manifest=manifest,
                   producer_overlay=overlay,
                   gn_args=args, root_target=ROOT_TARGET, compiler_defines=defines,
                   generated=identity, gn=gn_pin,
                   compiler=dict(pin=manifest['dependencies']['clang'], sha256=file_hash(clang),
                                 version=compiler_version),
                   ninja=dict(pin=manifest['dependencies']['ninja'], sha256=file_hash(ninja),
                              version=ninja_version),
                   executable=dict(path=executable.name, sha256=file_hash(executable),
                                   version=(probe.stdout + probe.stderr).strip()),
                   qualification='native --version only; target snapshot execution requires SDK integration')
    output.mkdir(parents=True)
    shutil.copy2(executable, output / executable.name)
    kernel_compiler = output / ('ctr-kernel' + suffix)
    dart = source / 'tools/sdks/dart-sdk/bin' / ('dart.exe' if suffix else 'dart')
    driver = Path(__file__).resolve().parents[1] / 'toolchain/native_kernel.dart'
    command([dart, 'compile', 'exe', '--packages=' + str(source / '.dart_tool/package_config.json'),
             driver, '-o', kernel_compiler], cwd=source, env=env, capture=False)
    receipt['kernel_compiler'] = dict(path=kernel_compiler.name, sha256=file_hash(kernel_compiler),
                                      driver_sha256=file_hash(driver), host_dart_sha256=file_hash(dart))
    host_sdk = dart.parent.parent
    shutil.copytree(host_sdk, output / 'host-dart')
    receipt['host_dart'] = {
        str(path.relative_to(host_sdk)).replace('\\', '/'): {
            'sha256': file_hash(path), 'executable': bool(path.stat().st_mode & 0o111)}
        for path in sorted(host_sdk.rglob('*')) if path.is_file()
    }
    (output / 'native-precompiler.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=2)
    args = parser.parse_args()
    try:
        receipt = build(args.work_dir.resolve(), args.output_dir.resolve(), args.manifest.resolve(), args.jobs)
        print(json.dumps(receipt['generated']))
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
