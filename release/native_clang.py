#!/usr/bin/env python3
"""Producer of the bundled CTR C/C++ compiler; never required by SDK recipients.

Two components come from here:

  --target <host>  LLVM clang for one SDK host. Official LLVM release archives
                   are used where they meet the SDK dependency policy; the other
                   hosts build clang from the pinned LLVM source. Either way the
                   input is verified against release/clang-source.json. Run on
                   the destination host with fresh --work and --output folders.
  --headers        Host-independent CTR target headers (newlib, libstdc++,
                   libctru) from the producer container's devkitPro install,
                   bound to the frozen runtime libraries by hash.

The CTR compile configuration that ties them together is target_config(); the
SDK check that compiles and links C and C++ samples is check_sdk_compiler().
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import struct
import subprocess
import tarfile
import urllib.request

from native_binutils import audit_binary
from native_dependencies import WINDOWS_SYSTEM_DLLS, pe_imports


ROOT = Path(__file__).resolve().parents[1]
PIN = Path(__file__).with_name('clang-source.json')
PROFILE = ROOT / 'toolchain/target-ctr.json'
TARGETS = {'linux-x64': ('Linux', 'x86_64'),
           'windows-x64': ('Windows', 'x86_64'),
           'macos-x64': ('Darwin', 'x86_64'),
           'macos-arm64': ('Darwin', 'arm64')}
TRIPLE = 'arm-none-eabi'
TOOL = 'ctr-clang'
CMAKE = ['-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
         '-DLLVM_ENABLE_PROJECTS=clang', '-DLLVM_TARGETS_TO_BUILD=ARM',
         '-DLLVM_ENABLE_ZLIB=OFF', '-DLLVM_ENABLE_ZSTD=OFF',
         '-DLLVM_ENABLE_LIBXML2=OFF', '-DLLVM_ENABLE_LIBEDIT=OFF',
         '-DLLVM_ENABLE_LIBPFM=OFF', '-DLLVM_ENABLE_BINDINGS=OFF',
         '-DLLVM_BUILD_LLVM_DYLIB=OFF', '-DLLVM_LINK_LLVM_DYLIB=OFF',
         '-DBUILD_SHARED_LIBS=OFF', '-DLLVM_ENABLE_ASSERTIONS=OFF',
         '-DLLVM_INCLUDE_TESTS=OFF', '-DLLVM_INCLUDE_BENCHMARKS=OFF',
         '-DLLVM_INCLUDE_EXAMPLES=OFF', '-DLLVM_INCLUDE_DOCS=OFF',
         '-DCLANG_INCLUDE_TESTS=OFF', '-DCLANG_INCLUDE_DOCS=OFF',
         '-DCLANG_ENABLE_STATIC_ANALYZER=OFF', '-DCLANG_PLUGIN_SUPPORT=OFF',
         '-DLLVM_PARALLEL_LINK_JOBS=2']
# Integer-type macros the headers derive their typedefs from. GCC for
# arm-none-eabi makes int32_t `long`; clang makes it `int`. The SDK passes
# GCC's exact definitions so headers, C++ mangling and the prebuilt libraries agree.
ABI_MACRO = re.compile(r'__(U?INT(_LEAST|_FAST)?(8|16|32|64)|U?INTMAX|U?INTPTR|SIZE|PTRDIFF|'
                       r'WCHAR|WINT|CHAR8|CHAR16|CHAR32|SIG_ATOMIC)_(TYPE|MAX|MIN|WIDTH|C)__'
                       r'|__U?INT(8|16|32|64|MAX)_C\(c\)|__DEVKIT(ARM|PRO)__')
# Properties checked against GCC but never passed as defines: clang must
# produce them itself from the target flags.
ABI_CHECKS = ('__ARM_SIZEOF_MINIMAL_ENUM', '__ARM_SIZEOF_WCHAR_T', '__CHAR_UNSIGNED__',
              '__ARM_PCS_VFP', '__VFP_FP__', '__ARM_ARCH', '__ARM_ARCH_6K__', '__ARM_FP',
              '__SIZEOF_INT__', '__SIZEOF_LONG__', '__SIZEOF_LONG_LONG__', '__SIZEOF_POINTER__',
              '__SIZEOF_SIZE_T__', '__SIZEOF_WCHAR_T__', '__SIZEOF_WINT_T__',
              '__SIZEOF_DOUBLE__', '__SIZEOF_LONG_DOUBLE__', '__BIGGEST_ALIGNMENT__')
# Frozen runtime libraries whose ABI the headers describe (runtime.json keys).
HEADER_LIBRARIES = ('libc.a', 'libm.a', 'libstdc++.a', 'libgcc.a', 'libsysbase.a')
HEADER_PACKAGES = ('devkitarm-gcc', 'devkitarm-newlib', 'libctru')
EF_ARM_EABI5 = 0x05000000
# ARM EABI build attributes. Tag_CPU_arch: GCC records ARMv6K as 9 (v6K) and
# clang records -march=armv6k as 6 (v6), a subset the linker merges into v6K.
# Tag_ABI_VFP_args 1 passes floating-point arguments in VFP registers (hard-float).
TAG_CPU_ARCH, TAG_ABI_VFP_ARGS, CPU_ARCH_V6_V6K = 6, 28, (6, 9)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def run(arguments, cwd=None, env=None, log=None):
    result = subprocess.run([str(arg) for arg in arguments], cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    if log is not None:
        Path(log).write_text(result.stdout)
    if result.returncode:
        print(result.stdout[-8000:], flush=True)
        result.check_returncode()
    return result.stdout


def download(url, path):
    with urllib.request.urlopen(url, timeout=120) as response, Path(path).open('xb') as stream:
        shutil.copyfileobj(response, stream)


def fetch_verified(record, work, fetch=download):
    """Download one pinned archive into work; nothing is extracted on mismatch."""
    archive = Path(work) / record['archive']
    fetch(record['url'], archive)
    if digest(archive) != record['sha256']:
        raise ValueError(f'archive digest mismatch: {record["archive"]}')
    return archive


def member_path(name, root):
    """Archive member below root as relative parts; anything else is fatal."""
    path = PurePosixPath(name)
    if '\\' in name or path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != root:
        raise ValueError(f'archive member escapes root: {name}')
    return path.parts[1:]


def extract_release(archive, output, record, major, suffix):
    """Copy only the clang driver and its resource headers from a release archive.

    The driver keeps the archive member's bytes, so its hash is the upstream one.
    """
    root = record['root']
    driver = tuple(PurePosixPath(record['member']).parts)
    headers = ('lib', 'clang', major, 'include')
    found, count = False, 0
    with tarfile.open(archive, 'r|xz') as stream:
        for entry in stream:
            parts = member_path(entry.name, root)
            if parts == driver:
                if not entry.isfile():
                    raise ValueError('clang driver member is not a regular file')
                destination = output / 'bin' / (TOOL + suffix)
                found = True
            elif parts[:4] == headers and len(parts) > 4:
                if entry.isdir():
                    continue
                if not entry.isfile():
                    raise ValueError(f'unsupported resource header member: {entry.name}')
                destination = output.joinpath(*parts)
                count += 1
            else:
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            with stream.extractfile(entry) as source, destination.open('xb') as target:
                shutil.copyfileobj(source, target)
    if not found or not count:
        raise ValueError('archive lacks the clang driver or its resource headers')


def extract_source(archive, destination, root):
    """Extract the pinned LLVM source tree; links may only point inside it."""
    destination.mkdir(parents=True, exist_ok=False)
    top = (destination / root).resolve()
    with tarfile.open(archive, 'r:xz') as stream:
        for entry in stream:
            member_path(entry.name, root)
            target = destination / entry.name
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif entry.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(entry) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(entry.mode & 0o755 | 0o644)
            elif entry.issym():
                resolved = (target.parent / entry.linkname).resolve()
                if PurePosixPath(entry.linkname).is_absolute() or not resolved.is_relative_to(top):
                    raise ValueError(f'source link escapes root: {entry.name}')
                target.parent.mkdir(parents=True, exist_ok=True)
                os.symlink(entry.linkname, target)
            else:
                raise ValueError(f'unsupported source member: {entry.name}')
    return destination / root


def cmake_arguments(target, source, build_dir, environment):
    arguments = ['cmake', '-S', Path(source) / 'llvm', '-B', build_dir, *CMAKE,
                 '-DCMAKE_C_COMPILER=' + environment['CC'],
                 '-DCMAKE_CXX_COMPILER=' + environment['CXX']]
    if target == 'linux-x64':
        # The SDK policy admits only glibc libraries on Linux. LLVM's option adds
        # -static-libstdc++ only; -static-libgcc removes libgcc_s.so.1 as well.
        arguments += ['-DLLVM_STATIC_LINK_CXX_STDLIB=ON', '-DCMAKE_EXE_LINKER_FLAGS=-static-libgcc']
    elif target.startswith('macos-'):
        arguments += ['-DCMAKE_OSX_ARCHITECTURES=' + ('arm64' if target.endswith('arm64') else 'x86_64'),
                      '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + environment['MACOSX_DEPLOYMENT_TARGET'],
                      '-DCMAKE_OSX_SYSROOT=' + environment['SDKROOT']]
    else:
        raise ValueError(f'no source build recipe for {target}')
    return [str(argument) for argument in arguments]


def compile_jobs(memory_bytes, cpus):
    """Parallel compiles sized from memory: an LLVM compile can take about 2 GiB."""
    return max(1, min(cpus, memory_bytes // (2 << 30)))


def build_from_source(target, source, work, output, pin, suffix):
    environment = os.environ.copy()
    if target.startswith('macos-'):
        environment.update(CC=run(['xcrun', '--find', 'clang']).strip(),
                           CXX=run(['xcrun', '--find', 'clang++']).strip(),
                           MACOSX_DEPLOYMENT_TARGET=pin['macos_minimum'],
                           SDKROOT=run(['xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip())
    else:
        # Explicit native compilers keep a devkitARM PATH entry from being used.
        environment.update(CC=shutil.which('gcc') or '', CXX=shutil.which('g++') or '')
    if not environment['CC'] or not environment['CXX']:
        raise ValueError('missing producer host compiler')
    build_dir = work / 'build'
    logs = work / 'logs'
    logs.mkdir()
    configure = cmake_arguments(target, source, build_dir, environment)
    run(configure, env=environment, log=logs / 'configure.log')
    jobs = compile_jobs(os.sysconf('SC_PHYS_PAGES') * os.sysconf('SC_PAGE_SIZE'), os.cpu_count() or 1)
    run(['ninja', '-C', build_dir, '-j', jobs, 'clang', 'clang-resource-headers'], env=environment,
        log=logs / 'build.log')
    (output / 'bin').mkdir()
    shutil.copy2(build_dir / 'bin' / f'clang-{pin["major"]}', output / 'bin' / (TOOL + suffix))
    shutil.copytree(build_dir / 'lib/clang' / pin['major'] / 'include',
                    output / 'lib/clang' / pin['major'] / 'include')
    return dict(cmake=configure, ninja_jobs=jobs, compilers={key: run([environment[key], '--version'])
                                            for key in ('CC', 'CXX')},
                cmake_version=run(['cmake', '--version']), ninja_version=run(['ninja', '--version']),
                logs=sorted(path.name for path in logs.iterdir()))


def audit_tool(path, target):
    if target == 'windows-x64':
        dependencies = pe_imports(path)
        unbundled = [name for name in dependencies if name not in WINDOWS_SYSTEM_DLLS
                     and not name.startswith(('api-ms-win-', 'ext-ms-win-'))]
        if unbundled:
            raise ValueError(f'unbundled host dependency: {", ".join(unbundled)}')
        return {'dependencies': dependencies}
    return audit_binary(path, target)


def uleb(blob, at):
    value = shift = 0
    while True:
        byte = blob[at]
        at += 1
        value |= (byte & 0x7f) << shift
        shift += 7
        if not byte & 0x80:
            return value, at


def arm_attributes(blob, start, size):
    """File-scope public ("aeabi") build attributes of an .ARM.attributes section."""
    section = blob[start:start + size]
    if section[:1] != b'A':
        raise ValueError('unsupported ARM attributes format')
    at, values = 1, {}
    while at < len(section):
        length = struct.unpack_from('<I', section, at)[0]
        end = at + length
        vendor_end = section.index(0, at + 4)
        vendor, at = section[at + 4:vendor_end], vendor_end + 1
        while vendor == b'aeabi' and at < end:
            tag, sub_size = section[at], struct.unpack_from('<I', section, at + 1)[0]
            sub_end, at = at + sub_size, at + 5
            while tag == 1 and at < sub_end:
                name, at = uleb(section, at)
                if name in (4, 5, 67) or (name > 32 and name % 2):
                    at = section.index(0, at) + 1
                    continue
                value, at = uleb(section, at)
                if name == 32:
                    at = section.index(0, at) + 1
                values[name] = value
            at = sub_end
        at = end
    return values


def elf_identity(path):
    """(e_type, e_flags, file build attributes) of a little-endian ARM ELF32 file."""
    blob = Path(path).read_bytes()
    if blob[:6] != b'ELF' or struct.unpack_from('<H', blob, 18)[0] != 40:
        raise ValueError(f'not a little-endian ARM ELF32 file: {Path(path).name}')
    kind, flags = struct.unpack_from('<H', blob, 16)[0], struct.unpack_from('<I', blob, 36)[0]
    sections, entry_size, count = (struct.unpack_from('<I', blob, 32)[0],
                                   *struct.unpack_from('<HH', blob, 46))
    attributes = None
    for index in range(count):
        header = sections + index * entry_size
        if struct.unpack_from('<I', blob, header + 4)[0] == 0x70000003:  # SHT_ARM_ATTRIBUTES
            offset, size = struct.unpack_from('<II', blob, header + 16)
            attributes = arm_attributes(blob, offset, size)
    if attributes is None:
        raise ValueError(f'{Path(path).name} has no ARM build attributes')
    return kind, flags, attributes


def require_armv6k_hard_float(path):
    kind, flags, attributes = elf_identity(path)
    if (flags & 0xff000000 != EF_ARM_EABI5 or attributes.get(TAG_CPU_ARCH) not in CPU_ARCH_V6_V6K
            or attributes.get(TAG_ABI_VFP_ARGS) != 1):
        raise ValueError(f'{Path(path).name} is not ARMv6K EABI5 hard-float '
                         f'(e_flags {flags:#x}, attributes {attributes})')
    return kind, flags, attributes


def smoke_test(clang, work, profile):
    """Freestanding compile only: hosts other than the container have no target headers."""
    source = work / 'smoke.c'
    source.write_text('int seven(int a) { return a * 7; }\n')
    obj = work / 'smoke.o'
    run([clang, '--target=' + TRIPLE, *profile['cflags'], '-ffreestanding', '-Werror',
         '-c', source, '-o', obj])
    kind, flags, attributes = require_armv6k_hard_float(obj)
    if kind != 1:
        raise ValueError('smoke compile did not produce a relocatable object')
    return {'armv6k_hard_float_compile': 'passed', 'e_flags': hex(flags), 'attributes': attributes,
            'object_sha256': digest(obj),
            'scope': 'Freestanding compile only; the SDK check compiles and links C and C++ samples.'}


def host_tuple():
    machine = platform.machine().lower()
    return platform.system(), 'x86_64' if machine == 'amd64' else machine


def revision():
    value = os.environ.get('GITHUB_SHA')
    if value is None and (ROOT / '.git').exists():
        value = run(['git', '-c', 'safe.directory=' + str(ROOT), 'rev-parse', 'HEAD'], ROOT).strip()
    return value


def sealed(output):
    files = {path.relative_to(output).as_posix(): digest(path)
             for path in sorted(output.rglob('*')) if path.is_file()}
    (output / 'SHA256SUMS').write_text(''.join(f'{value}  {name}\n' for name, value in files.items()))


def build(target, work, output, fetch=download):
    if host_tuple() != TARGETS[target]:
        raise ValueError('producer must execute on the requested native host architecture')
    work.mkdir(parents=True, exist_ok=False)
    output.mkdir(parents=True, exist_ok=False)
    pin = read(PIN)
    profile = read(PROFILE)
    record = pin['hosts'][target]
    suffix = '.exe' if target == 'windows-x64' else ''
    if record['kind'] == 'release':
        archive = fetch_verified(record, work, fetch)
        extract_release(archive, output, record, pin['major'], suffix)
        build_record = None
    else:
        archive = fetch_verified(pin['source'], work, fetch)
        source = extract_source(archive, work / 'source', pin['source']['root'])
        build_record = build_from_source(target, source, work, output, pin, suffix)
    clang = output / 'bin' / (TOOL + suffix)
    clang.chmod(0o755)
    version = run([clang, '--version'])
    if f'clang version {pin["version"]}' not in version:
        raise ValueError('unexpected clang version')
    audit = audit_tool(clang, target)
    smoke_work = work / 'smoke'
    smoke_work.mkdir()
    verification = smoke_test(clang, smoke_work, profile)
    licenses = output / 'licenses'
    licenses.mkdir()
    for name in pin['license_files']:
        shutil.copyfile(ROOT / 'release/licenses' / name, licenses / name)
    (output / 'NOTICE.txt').write_text(
        f'LLVM clang {pin["version"]} driver and clang resource headers, unmodified.\n'
        f'Licensed under {pin["license"]}; see licenses/.\n'
        f'Input: {record.get("url", pin["source"]["url"])}\n'
        'ctr-clang is the upstream clang driver under a CTR tool name.\n')
    files = {path.relative_to(output).as_posix(): digest(path)
             for path in sorted(output.rglob('*'))
             if path.is_file() and path.relative_to(output).parts[0] in ('bin', 'lib')}
    provenance = dict(schema_version=1, host=target, version=pin['version'], major=pin['major'],
                      license=pin['license'], kind=record['kind'], input=record if record['kind'] == 'release'
                      else dict(pin['source'], reason=record['reason']),
                      producer_revision=revision(), host_platform=platform.platform(),
                      tool=dict(path=clang.relative_to(output).as_posix(), sha256=digest(clang),
                                version=version, **audit),
                      resource_headers=f'lib/clang/{pin["major"]}/include', files=files, build=build_record)
    (output / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    (output / 'verification.json').write_text(json.dumps(verification, indent=2) + '\n')
    sealed(output)
    return provenance


def copy_tree(source, destination, skip=()):
    files = {}
    for path in sorted(Path(source).rglob('*')):
        relative = path.relative_to(source)
        if any(relative.parts[:len(prefix)] == prefix for prefix in skip) or path.is_dir():
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'unsupported header entry: {path}')
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        files[target] = path
    return files


def case_collisions(names):
    seen, clashes = {}, []
    for name in names:
        key = name.lower()
        if key in seen and seen[key] != name:
            clashes.append((seen[key], name))
        seen.setdefault(key, name)
    return clashes


def macros(compiler, flags, language='c'):
    output = run([compiler, *flags, '-dM', '-E', '-x', language, os.devnull])
    values = {}
    for line in output.splitlines():
        if line.startswith('#define '):
            name, _, value = line[8:].partition(' ')
            values[name] = value
    return values


def build_headers(output, profile_path=PROFILE):
    """Copy CTR target headers from the devkitPro install the runtime was frozen from."""
    profile = read(profile_path)
    output.mkdir(parents=True, exist_ok=False)
    gcc = profile['compiler_prefix'] + 'gcc'
    flags = profile['cflags']
    version = run([gcc, '-dumpversion']).strip()
    multilib = run([gcc, *flags, '-print-multi-directory']).strip()
    newlib = Path(gcc).resolve().parents[1] / 'arm-none-eabi/include'
    libctru = Path(profile['libctru'])
    cxx = ('c++', version)
    cxx_target = ('c++', version, 'arm-none-eabi')
    copied = copy_tree(newlib, output / 'target/include', skip=[cxx_target])
    copied.update(copy_tree(newlib.joinpath(*cxx_target, *multilib.split('/')),
                            output.joinpath('target/include', *cxx_target, *multilib.split('/'))))
    copied.update(copy_tree(libctru / 'include', output / 'target/libctru/include'))
    for unexpected in sorted((newlib / 'c++').iterdir()):
        if unexpected.name != version:
            raise ValueError(f'unexpected libstdc++ header version: {unexpected.name}')
    names = sorted(path.relative_to(output).as_posix() for path in copied)
    clashes = case_collisions(names)
    if clashes:
        raise ValueError(f'header paths differ only by case: {clashes[:3]}')
    libraries = {f'lib/shared/{name}': digest(run([gcc, *flags, '-print-file-name=' + name]).strip())
                 for name in HEADER_LIBRARIES}
    libraries['lib/shared/libctru.a'] = digest(libctru / 'lib/libctru.a')
    installed = dict(line.split() for line in run(['dkp-pacman', '-Q']).splitlines() if line.strip())
    packages = {name: installed[name] for name in HEADER_PACKAGES}
    gcc_macros = macros(gcc, flags)
    abi_macros = {name: value for name, value in gcc_macros.items() if ABI_MACRO.fullmatch(name)}
    if not {'__INT32_TYPE__', '__DEVKITPRO__', '__DEVKITARM__'} <= abi_macros.keys():
        raise ValueError('compiler macro dump lacks the CTR ABI macros')
    # None records a property GCC leaves undefined (clang must leave it undefined too).
    abi_checks = {name: gcc_macros.get(name) for name in ABI_CHECKS}
    cxx_root = 'target/include/' + '/'.join(cxx)
    record = dict(schema_version=1, kind='ctr-target-headers', gcc_version=version, multilib=multilib,
                  packages=packages, profile_cflags=flags,
                  include=dict(c=['target/include', 'target/libctru/include'],
                               cxx=[cxx_root, f'{cxx_root}/arm-none-eabi/{multilib}', f'{cxx_root}/backward']),
                  defines=['__3DS__'], abi_macros=abi_macros, abi_checks=abi_checks,
                  library_sha256=libraries,
                  files={name: digest(output / name) for name in names},
                  licenses=['newlib.COPYING.NEWLIB', 'gcc.COPYING3', 'gcc.COPYING.RUNTIME',
                            'libctru-2.7.0.README.md'],
                  scope='Target headers for the frozen runtime libraries; no host tools.')
    for directory in record['include']['c'] + record['include']['cxx']:
        if not (output / directory).is_dir():
            raise ValueError(f'missing include directory: {directory}')
    (output / 'NOTICE.txt').write_text(
        'CTR target headers: newlib (devkitPro patches), libstdc++ (GCC runtime library\n'
        'exception) and libctru (zlib). Their notices are in the SDK notices folder.\n'
        'No devkitPro host tools are included; no endorsement by devkitPro is implied.\n')
    (output / 'headers.json').write_text(json.dumps(record, indent=2) + '\n')
    sealed(output)
    return record


def target_config(profile, clang, headers):
    """CTR compile configuration recorded in sdk.json; paths are SDK-relative.

    Compiler flags come from toolchain/target-ctr.json. The header ABI comes from
    the GCC that built the frozen libraries, recorded by build_headers().
    """
    resource = clang['resource_headers']
    flags = ['--target=' + TRIPLE, *profile['cflags']]
    if headers['abi_checks'].get('__ARM_SIZEOF_MINIMAL_ENUM') == '1':
        flags.append('-fshort-enums')
    flags.append('-nostdinc')
    flags += ['-D' + name for name in headers['defines']]
    for name, value in sorted(headers['abi_macros'].items()):
        flags += ['-U' + name.split('(')[0], f'-D{name}={value}']
    return dict(triple=TRIPLE, flags=flags, cxx_flags=['--driver-mode=g++'],
                include=dict(c=[resource, *headers['include']['c']],
                             cxx=[*headers['include']['cxx'], resource, *headers['include']['c']]))


SAMPLE_C = r'''#include <stdio.h>
#include <stdint.h>
#include <3ds.h>
int ctr_c_sample(uint32_t value) {
  printf("c:%lu tick:%llu\n", (unsigned long)value, (unsigned long long)svcGetSystemTick());
  return (int)value;
}
'''
SAMPLE_CXX = r'''#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
extern "C" int ctr_c_sample(uint32_t value);
int main() {
  std::vector<int> values{1, 2, 3};
  values.push_back(ctr_c_sample(4));
  std::string name = "vector";
  std::printf("%s:%zu\n", name.c_str(), values.size());
  return 0;
}
'''


def numeric(value):
    return int(value.rstrip('uUlL'), 0)


def check_sdk_compiler(sdk, work):
    """Compile C and C++ samples with the SDK's clang and link them with ctr-ld."""
    sdk, work = Path(sdk), Path(work)
    work.mkdir(parents=True, exist_ok=False)
    manifest = read(sdk / 'sdk.json')
    config = manifest['native_compiler']
    headers = read(sdk / 'provenance/target-headers.json')
    clang = sdk / manifest['tools']['clang']
    linker = sdk / manifest['tools']['ld']
    env = dict(os.environ, PATH='')
    common = [*config['flags'], '-Werror']

    def includes(language):
        return [argument for path in config['include'][language] for argument in ('-isystem', sdk / path)]

    seen = macros(clang, [*common, *includes('c')])
    for name, value in headers['abi_macros'].items():
        if seen.get(name) != value:
            raise ValueError(f'clang macro {name} differs from the target ABI')
    for name, value in headers['abi_checks'].items():
        if (name in seen) != (value is not None) or (value is not None and numeric(seen[name]) != numeric(value)):
            raise ValueError(f'clang ABI property {name} differs from the target ABI')
    (work / 'sample.c').write_text(SAMPLE_C)
    (work / 'sample.cpp').write_text(SAMPLE_CXX)
    objects = {}
    for source, language, extra in [('sample.c', 'c', []), ('sample.cpp', 'cxx', config['cxx_flags'])]:
        obj = work / (source + '.o')
        subprocess.run([str(a) for a in [clang, *extra, *common, *includes(language), '-c', work / source, '-o', obj]],
                       env=env, check=True)
        kind, flags, attributes = require_armv6k_hard_float(obj)
        objects[obj.name] = dict(bytes=obj.stat().st_size, e_flags=hex(flags), attributes=attributes,
                                 sha256=digest(obj))
    link = manifest['runtime']['link']
    elf = work / 'sample.elf'
    # Same layout and libraries as the dartbrew link; warnings (such as enum or
    # wchar_t size mismatches between objects) fail the check.
    subprocess.run([str(a) for a in [
        linker, '--fatal-warnings', '--no-warn-rwx-segments', '--no-warn-execstack',
        '--defsym=__sync_synchronize=__sync_synchronize_cp15dmb', '-X', '-T', sdk / link['layout'],
        '-d', '--emit-relocs', '--use-blx', '--gc-sections', '-u', '__sync_synchronize_cp15dmb',
        '-Map=' + str(work / 'sample.map'), '-o', elf,
        *[sdk / name for name in link['startup']], work / 'sample.c.o', work / 'sample.cpp.o',
        *[sdk / name for name in link['libraries']],
        '--start-group', *[sdk / name for name in link['grouped']], '--end-group',
        *[sdk / name for name in link['end']]]], env=env, check=True)
    kind, flags, attributes = require_armv6k_hard_float(elf)
    if kind != 2:
        raise ValueError('linked sample is not an executable ELF')
    return dict(objects=objects, elf=dict(bytes=elf.stat().st_size, e_flags=hex(flags),
                                          attributes=attributes, sha256=digest(elf)),
                abi_macros=len(headers['abi_macros']), abi_checks=len(headers['abi_checks']),
                scope='C printf/libctru and C++ std::vector samples compiled by the bundled clang '
                      'and linked by the bundled ctr-ld with the frozen runtime libraries; not executed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--target', choices=TARGETS)
    mode.add_argument('--headers', action='store_true')
    parser.add_argument('--work', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.headers:
        build_headers(args.output.resolve())
    else:
        if args.work is None:
            parser.error('--target needs --work')
        build(args.target, args.work.resolve(), args.output.resolve())


if __name__ == '__main__':
    main()
