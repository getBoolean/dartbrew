#!/usr/bin/env python3
"""Link a supplied CTR AOT assembly or JIT kernel with the locked native runner."""
import argparse
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

from common import (DEFAULT_MANIFEST, DEFAULT_PROFILE, ROOT, build_identity,
                    digest, file_hash, git, read_json, source_inputs,
                    verify_icu, verify_source)
from native_linux import check
from soft_math import prepare as prepare_soft_math


def compiler_command(source, build, mode):
    kind = 'aotruntime' if mode == 'aot' else 'jit'
    target = f'obj/runtime/vm/libdart_vm_{kind}.os_thread_ctr.o'
    commands = subprocess.check_output([
        str(source / 'buildtools/ninja/ninja'), '-C', str(build), '-t', 'commands', target], text=True)
    command = shlex.split(commands.strip().splitlines()[-1])
    for flag in ('-MF', '-o', '-c'):
        index = command.index(flag)
        del command[index:index + 2]
    command = [arg for arg in command if arg != '-MMD']
    if not any(arg.startswith('-I') and (build / arg[2:]).resolve() == source / 'runtime'
               for arg in command):
        raise RuntimeError('runtime GN graph includes a different SDK source directory')
    # Retain GN's relative paths and execute from the same build directory.
    return command


def package(source, build, mode, payload, fixture, output,
            manifest_path=DEFAULT_MANIFEST, profile_path=DEFAULT_PROFILE):
    if mode not in ('aot', 'jit') or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', fixture):
        raise ValueError('expected mode aot/jit and a fixture token of 1–64 letters, digits, _ or -')
    source, build, payload, output = (Path(p).resolve() for p in (source, build, payload, output))
    if output.exists():
        raise RuntimeError(f'output already exists; preserve it and select a new path: {output}')
    if output.is_relative_to(source) or output.is_relative_to(build):
        raise RuntimeError('package output must be outside the SDK and runtime build directories')
    manifest, _ = source_inputs(manifest_path)
    state = verify_source(source, manifest)
    verify_icu(source, manifest)
    identity = build_identity(manifest_path, profile_path, 'target', mode)
    if read_json(build / 'compatibility.json') != identity:
        raise RuntimeError('runtime build identity differs from the locked target/mode')
    archive = build / 'obj/runtime' / ('libdart_aotruntime.a' if mode == 'aot' else 'libdart_jit.a')
    if not archive.is_file():
        raise RuntimeError(f'missing runtime archive: {archive}')
    # The launcher calls the SDK's dart:io layer for CTR, which calls the VM.
    io_archive = build / 'obj/runtime/bin/ctr/libdart_io.a'
    if not io_archive.is_file():
        raise RuntimeError(f'missing dart:io archive: {io_archive}')
    if not payload.is_file():
        raise RuntimeError(f'missing supplied payload: {payload}')
    if mode == 'jit':
        with payload.open('rb') as stream:
            if stream.read(4) != bytes.fromhex('90abcdef'):
                raise RuntimeError('JIT payload does not have the Dart kernel magic')
    toolchain = check(manifest_path, profile_path)
    profile = read_json(profile_path)
    compiler = profile['compiler_prefix'] + 'g++'
    command = compiler_command(source, build, mode)
    if command[0] != compiler:
        raise RuntimeError('runtime GN graph does not use the locked compiler')
    if ('-DDART_PRECOMPILED_RUNTIME' in command) != (mode == 'aot'):
        raise RuntimeError('runtime GN compiler profile differs from the requested mode')
    converter = Path(profile['libctru']).parent / 'tools/bin/3dsxtool'
    if not converter.is_file():
        raise RuntimeError(f'missing 3DSX converter: {converter}')
    runtime = ROOT / 'runtime/ctr'
    sources = sorted((runtime / 'source').glob('*.cc'))
    source_hashes = {str(path.relative_to(ROOT)): file_hash(path)
                     for path in sorted((runtime / 'source').iterdir()) if path.is_file()}
    for name in ('soft_math.py', 'soft_math_bridge.cc', 'native_linux.py'):
        source_hashes['toolchain/' + name] = file_hash(ROOT / 'toolchain' / name)
    payload_hash, archive_hash = file_hash(payload), file_hash(archive)
    packager_hash = file_hash(__file__)
    # Reserve a fresh output. Build products remain under work until a complete
    # package directory can be published with a single rename.
    output.mkdir(parents=True, exist_ok=False)
    work = output / 'work'
    work.mkdir()
    commands_run = []

    def run(args, cwd=work, capture=False):
        args = list(map(str, args))
        commands_run.append({'argv': args, 'cwd': str(cwd)})
        (work / 'commands.json').write_text(json.dumps(commands_run, indent=2) + '\n')
        result = subprocess.run(args, cwd=cwd, check=True,
                                stdout=subprocess.PIPE if capture else None, text=True)
        return result.stdout if capture else None

    math_component, math_record = prepare_soft_math(
        work / 'soft-math', profile, toolchain['providers']['soft_libm.a']['path'], run=run)
    build_id = digest({'compatibility': identity['cache_key'], 'fixture': fixture,
                       'runtime_sources': source_hashes, 'payload': payload_hash,
                       'archive': archive_hash, 'packager': packager_hash,
                       'providers': toolchain['providers'], 'software_math': math_record})

    if mode == 'jit':
        shutil.copyfile(payload, work / 'application.dill')
        assembly = work / 'payload.S'
        assembly.write_text('.section .rodata\n.balign 16\n.global ctr_kernel\nctr_kernel:\n'
                            '.incbin "application.dill"\n.section .note.GNU-stack,"",%progbits\n')
        declaration = 'extern "C" const uint8_t ctr_kernel[];'
        fields = f'nullptr, nullptr, ctr_kernel, {payload.stat().st_size}'
    else:
        assembly = work / 'payload.S'
        shutil.copyfile(payload, assembly)
        declaration = 'extern "C" const uint8_t _kDartSnapshotData[], _kDartSnapshotText[];'
        fields = '_kDartSnapshotData, _kDartSnapshotText, nullptr, 0'
    copied = work / ('application.dill' if mode == 'jit' else 'payload.S')
    if file_hash(copied) != payload_hash:
        raise RuntimeError('payload changed while being copied')
    program = work / 'program.cc'
    values = ', '.join(json.dumps(v) for v in (fixture, mode, identity['cache_key'], build_id))
    program.write_text('#include "embedder.h"\n' + declaration +
                       '\nextern const ctr::Program ctr_program = {' + fields + ', {' + values + '}};\n')
    flags = [*command, '-I' + str(runtime / 'source'), '-I' + str(source / 'runtime/include')]
    objects = []
    for path in [*sources, program]:
        obj = work / (path.stem + '.o')
        run([*flags, '-c', path, '-o', obj], cwd=build)
        objects.append(obj)
    obj = work / 'payload.o'
    run([compiler, *profile['cflags'], '-c', assembly, '-o', obj])
    objects.append(obj)
    symbols = run([profile['compiler_prefix'] + 'nm', '--defined-only', obj], capture=True)
    names = {line.split()[-1] for line in symbols.splitlines() if line.split()}
    required = {'_kDartSnapshotData', '_kDartSnapshotText'} if mode == 'aot' else {'ctr_kernel'}
    if not required.issubset(names):
        raise RuntimeError('assembled payload lacks the required snapshot/kernel symbols')
    specs = [(Path(profile_path).resolve().parent / path).resolve() for path in profile['link_specs']]
    elf = work / 'application.elf'
    run([compiler, *profile['cflags'], *['-specs=' + str(path) for path in specs],
         '-Wl,--gc-sections', '-Wl,-Map=' + str(work / 'link.map'), *objects, math_component,
         io_archive, archive, '-L' + profile['libctru'] + '/lib', '-lctru', '-lm', '-o', elf])
    artifact = work / 'application.3dsx'
    run([converter, elf, artifact])
    # Detect input changes during compilation before attributing the package.
    if (file_hash(payload) != payload_hash or file_hash(archive) != archive_hash or
            file_hash(__file__) != packager_hash or
            file_hash(math_component) != math_record['object_sha256'] or
            build_identity(manifest_path, profile_path, 'target', mode) != identity or
            any(file_hash(Path(provider['path'])) != provider['sha256']
                for provider in toolchain['providers'].values()) or
            any(file_hash(ROOT / path) != sha for path, sha in source_hashes.items())):
        raise RuntimeError('a packaging input changed during compilation')
    verify_source(source, manifest)
    record = {'schema': 1, 'scope': 'compile-link-package-only', 'fixture': fixture,
              'mode': mode, 'compatibility': identity['cache_key'], 'build_id': build_id,
              'payload_sha256': payload_hash, 'archive_sha256': archive_hash,
              'artifact_sha256': file_hash(artifact), 'elf_sha256': file_hash(elf),
              'runtime_sources': source_hashes, 'sdk_head': state['head'],
              'packager_sha256': packager_hash,
              'software_math': math_record,
              'sdk_tree': git(source, 'rev-parse', 'HEAD^{tree}'),
              'payload_kind': 'caller-supplied-' + ('aot-assembly' if mode == 'aot' else 'jit-kernel')}
    publish = work / 'publish'
    publish.mkdir()
    shutil.copyfile(artifact, publish / 'application.3dsx')
    (publish / 'artifact.json').write_text(json.dumps(record, indent=2) + '\n')
    (publish / 'toolchain.json').write_text(json.dumps(toolchain, indent=2) + '\n')
    (publish / 'compatibility.json').write_text(json.dumps(identity, indent=2) + '\n')
    publish.rename(output / 'package')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--runtime-build', type=Path, required=True)
    parser.add_argument('--mode', choices=('aot', 'jit'), required=True)
    parser.add_argument('--payload', type=Path, required=True)
    parser.add_argument('--fixture', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(package(args.source, args.runtime_build, args.mode,
                             args.payload, args.fixture, args.output)))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
