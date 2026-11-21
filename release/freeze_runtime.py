"""Producer-only export of precompiled CTR assets; SDK users run no build scripts."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'toolchain'))
from common import (DEFAULT_MANIFEST, DEFAULT_PROFILE, build_identity, file_hash,
                    read_json, source_inputs, verify_icu, verify_source)
from native_linux import check
from package_runtime import compiler_command
from soft_math import prepare
from native_precompiler import generated_identity


def freeze_runtime(source, build_root, output):
    source, build_root, output = map(Path, (source, build_root, output))
    if output.exists():
        raise RuntimeError('runtime export output already exists; choose a new directory')
    manifest, _ = source_inputs(DEFAULT_MANIFEST)
    state = verify_source(source, manifest)
    verify_icu(source, manifest)
    provider = check(DEFAULT_MANIFEST, DEFAULT_PROFILE)
    profile = read_json(DEFAULT_PROFILE)
    compiler = profile['compiler_prefix'] + 'g++'
    strip = profile['compiler_prefix'] + 'strip'
    output.mkdir(parents=True)
    work = output / 'producer-work'
    work.mkdir()
    commands = []

    def run(argv, cwd=work, capture=False):
        argv = list(map(str, argv))
        commands.append(dict(argv=argv, cwd=str(cwd)))
        (work / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        result = subprocess.run(argv, cwd=cwd, check=True, text=True,
                                stdout=subprocess.PIPE if capture else None)
        return result.stdout.strip() if capture else None

    original_hashes = {}

    def copy(path, relative, strip_debug=False):
        path = Path(path)
        if not path.is_file():
            raise RuntimeError(f'missing native asset: {path}')
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        original_hashes[relative] = file_hash(path)
        shutil.copyfile(path, destination)
        if strip_debug:
            run([strip, '--strip-debug', destination])
        return relative

    layout = copy(run([compiler, *profile['cflags'], '-print-file-name=3dsx.ld'], capture=True),
                  'lib/shared/3dsx.ld')
    shared = {}
    for filename in ['3dsx_crt0.o', 'crti.o', 'crtbegin.o', 'crtend.o', 'crtn.o',
                     'libstdc++.a', 'libm.a', 'libgcc.a', 'libc.a', 'libsysbase.a']:
        path = run([compiler, *profile['cflags'], '-print-file-name=' + filename], capture=True)
        shared[filename] = copy(path, 'lib/shared/' + filename, True)
    shared['libctru.a'] = copy(Path(profile['libctru']) / 'lib/libctru.a',
                              'lib/shared/libctru.a', True)
    math_object, math_record = prepare(work / 'soft-math', profile,
                                      provider['providers']['soft_libm.a']['path'])
    math_relative = copy(math_object, 'lib/shared/soft-math.o', True)
    modes = {}
    snapshot_hashes = set()
    source_files = sorted((ROOT / 'runtime/ctr/source').glob('*.cc'))
    for mode in ('aot', 'jit'):
        identity = build_identity(DEFAULT_MANIFEST, DEFAULT_PROFILE, 'target', mode)
        build = build_root / f'target-{mode}-{identity["cache_key"][:16]}'
        if read_json(build / 'compatibility.json') != identity:
            raise RuntimeError('native runtime identity mismatch')
        version = generated_identity((build / 'gen/runtime/version.cc').read_text(), state['head'])
        snapshot_hashes.add(version['snapshot_hash'])
        flags = [*compiler_command(source, build, mode),
                 '-I' + str(ROOT / 'runtime/ctr/source'), '-I' + str(source / 'runtime/include')]
        objects = []
        for path in source_files:
            relative = f'lib/{mode}/{path.stem}.o'
            obj = output / relative
            obj.parent.mkdir(parents=True, exist_ok=True)
            run([*flags, '-c', path, '-o', obj], cwd=build)
            run([strip, '--strip-debug', obj])
            objects.append(relative)
        assertion = work / f'program-layout-{mode}.cc'
        assertion.write_text('''#include <cstddef>
#include "embedder.h"
static_assert(sizeof(ctr::Program) == 32);
static_assert(offsetof(ctr::Program, isolate_data) == 0);
static_assert(offsetof(ctr::Program, isolate_instructions) == 4);
static_assert(offsetof(ctr::Program, kernel) == 8);
static_assert(offsetof(ctr::Program, kernel_size) == 12);
static_assert(offsetof(ctr::Program, build) == 16);
static_assert(sizeof(ctr::BuildIdentity) == 16);
static_assert(offsetof(ctr::BuildIdentity, fixture) == 0);
static_assert(offsetof(ctr::BuildIdentity, mode) == 4);
static_assert(offsetof(ctr::BuildIdentity, compatibility) == 8);
static_assert(offsetof(ctr::BuildIdentity, build_id) == 12);
''')
        run([*flags, '-c', assertion, '-o', work / f'program-layout-{mode}.o'], cwd=build)
        archive_name = 'libdart_aotruntime.a' if mode == 'aot' else 'libdart_jit.a'
        archive = copy(build / 'obj/runtime' / archive_name, f'lib/{mode}/runtime.a', True)
        # The SDK's dart:io implementation (runtime/bin) built for CTR.
        io_archive = copy(build / 'obj/runtime/bin/ctr/libdart_io.a', f'lib/{mode}/io.a', True)
        run([sys.executable, ROOT / 'toolchain/test/test_ctr_native_offsets.py', '--source', source,
             '--build', build, '--mode', mode, '--output', work / f'native-offsets-{mode}'])
        modes[mode] = dict(compatibility=identity['cache_key'], objects=objects, archive=archive,
                           io_archive=io_archive)
    platform = output / 'lib/platform.dill'
    dart = source / 'tools/sdks/dart-sdk/bin/dart'
    run([dart, source / 'pkg/front_end/tool/compile_platform.dart', '--target=vm',
         '--sdk=' + str(source / 'sdk'), '-Ddart.vm.product=false', '-Ddart.isVM=true',
         'dart:core,dart:_ctr', source / 'sdk/lib/_internal/ctr/platform.json',
         source / 'tools/sdks/dart-sdk/lib/_internal/vm_platform_strong.dill',
         platform, work / 'outline.dill'])
    run([dart, '--packages=' + str(source / '.dart_tool/package_config.json'),
         ROOT / 'runtime/ctr/test/check_retention.dart', platform])
    if len(snapshot_hashes) != 1:
        raise RuntimeError('AOT and JIT runtime snapshot hashes differ')
    record = dict(schema=1, sdk_head=state['head'], snapshot_hash=snapshot_hashes.pop(),
                  modes=modes, platform='lib/platform.dill',
                  program_size=32, program_identity_offset=16,
                  link=dict(layout=layout, math=math_relative,
                            startup=[shared[n] for n in ['3dsx_crt0.o', 'crti.o', 'crtbegin.o']],
                            libraries=[shared[n] for n in ['libctru.a', 'libstdc++.a', 'libm.a']],
                            grouped=[shared[n] for n in ['libgcc.a', 'libc.a', 'libsysbase.a']],
                            end=[shared[n] for n in ['crtend.o', 'crtn.o']]),
                  files={str(p.relative_to(output)).replace('\\', '/'): file_hash(p)
                         for p in sorted((output / 'lib').rglob('*')) if p.is_file()},
                  producer=dict(original_sha256=original_hashes, software_math=math_record,
                                toolchain=provider, manifest=manifest),
                  scope='Target asset export only; native host bundles and application execution remain unqualified')
    verify_source(source, manifest)
    (output / 'runtime.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(dict(sdk_head=state['head'], files=len(record['files']),
                         bytes=sum(p.stat().st_size for p in (output / 'lib').rglob('*') if p.is_file()))), flush=True)
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--build-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    freeze_runtime(args.source.resolve(), args.build_root.resolve(), args.output.resolve())
