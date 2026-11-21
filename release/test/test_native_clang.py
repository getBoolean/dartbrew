"""Producer-policy tests for the bundled clang; these do not qualify a compiler."""
import hashlib
import io
import json
from pathlib import Path
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import native_clang as native  # noqa: E402
from native_binutils import check_dependencies  # noqa: E402

PIN = json.loads(native.PIN.read_text())
PROFILE = json.loads(native.PROFILE.read_text())


def archive(path, members):
    """members: (name, bytes) regular files, or (name, ('symlink', target))."""
    with tarfile.open(path, 'w:xz') as stream:
        for name, content in members:
            entry = tarfile.TarInfo(name)
            if isinstance(content, tuple):
                entry.type, entry.linkname = tarfile.SYMTYPE, content[1]
                stream.addfile(entry)
            else:
                entry.size = len(content)
                stream.addfile(entry, io.BytesIO(content))


def elf(e_type=1, attributes=None):
    """Minimal little-endian ARM ELF32 with an optional .ARM.attributes section."""
    tags = b''
    for tag, value in (attributes or {}).items():
        tags += bytes([tag, value])
    sub = b'\x01' + struct.pack('<I', 5 + len(tags)) + tags
    vendor = b'aeabi\0'
    section = b'A' + struct.pack('<I', 4 + len(vendor) + len(sub)) + vendor + sub
    body_offset, sections = 52, []
    if attributes is not None:
        sections.append((0x70000003, body_offset, len(section)))
    table = body_offset + len(section)
    header = bytearray(52)
    header[:6] = b'\x7fELF\x01\x01'
    struct.pack_into('<HH', header, 16, e_type, 40)
    struct.pack_into('<I', header, 32, table)
    struct.pack_into('<I', header, 36, native.EF_ARM_EABI5)
    struct.pack_into('<HH', header, 46, 40, len(sections))
    entries = b''.join(struct.pack('<IIIIIIIIII', 0, kind, 0, 0, offset, size, 0, 0, 1, 0)
                       for kind, offset, size in sections)
    return bytes(header) + section + entries


class PinTest(unittest.TestCase):
    def test_every_sdk_host_has_a_pinned_input(self):
        self.assertEqual(set(PIN['hosts']), set(native.TARGETS))
        self.assertRegex(PIN['source']['sha256'], '^[0-9a-f]{64}$')
        for host, record in PIN['hosts'].items():
            with self.subTest(host=host):
                if record['kind'] == 'release':
                    self.assertRegex(record['sha256'], '^[0-9a-f]{64}$')
                    self.assertTrue(record['url'].endswith('/' + record['archive']))
                    self.assertTrue(record['archive'].startswith(record['root']))
                else:
                    self.assertEqual(record['kind'], 'source')
                    native.cmake_arguments(host, 'src', 'build', dict(
                        CC='cc', CXX='c++', MACOSX_DEPLOYMENT_TARGET='13.0', SDKROOT='/sdk'))

    def test_license_notices_are_shipped(self):
        for name in PIN['license_files']:
            text = (native.ROOT / 'release/licenses' / name).read_text()
            self.assertIn('Apache License', text)
            self.assertIn('LLVM Exceptions', text)


class ArchiveTest(unittest.TestCase):
    def test_archive_whose_hash_differs_from_the_pin_is_rejected(self):
        records = [PIN['source'], *[r for r in PIN['hosts'].values() if r['kind'] == 'release']]
        for record in records:
            with self.subTest(archive=record['archive']), tempfile.TemporaryDirectory() as directory:
                fetched = []

                def fetch(url, path):
                    fetched.append(url)
                    Path(path).write_bytes(b'tampered archive')

                with self.assertRaisesRegex(ValueError, 'archive digest mismatch'):
                    native.fetch_verified(record, directory, fetch)
                self.assertEqual(fetched, [record['url']])

    def test_archive_matching_the_pin_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            content = b'pinned archive'
            record = dict(url='https://example.invalid/a.tar.xz', archive='a.tar.xz',
                          sha256=hashlib.sha256(content).hexdigest())
            path = native.fetch_verified(record, directory, lambda url, p: Path(p).write_bytes(content))
            self.assertEqual(path.read_bytes(), content)

    def test_release_extraction_keeps_only_the_driver_and_resource_headers(self):
        for host in ('windows-x64', 'macos-arm64'):
            record = PIN['hosts'][host]
            suffix = '.exe' if host == 'windows-x64' else ''
            with self.subTest(host=host), tempfile.TemporaryDirectory() as directory:
                root, driver = record['root'], b'clang driver bytes'
                path = Path(directory) / 'llvm.tar.xz'
                archive(path, [(f'{root}/bin/lld{suffix}', b'not shipped'),
                               (f'{root}/{record["member"]}', driver),
                               (f'{root}/lib/clang/23/include/arm_acle.h', b'/* acle */'),
                               (f'{root}/lib/libLLVM.a', b'not shipped')])
                output = Path(directory) / 'out'
                native.extract_release(path, output, record, PIN['major'], suffix)
                shipped = sorted(p.relative_to(output).as_posix() for p in output.rglob('*') if p.is_file())
                self.assertEqual(shipped, ['bin/ctr-clang' + suffix, 'lib/clang/23/include/arm_acle.h'])
                self.assertEqual((output / 'bin' / ('ctr-clang' + suffix)).read_bytes(), driver)

    def test_release_extraction_rejects_unsafe_or_incomplete_archives(self):
        record = PIN['hosts']['macos-arm64']
        root = record['root']
        header = (f'{root}/lib/clang/23/include/arm_acle.h', b'/* acle */')
        cases = {
            'escape': [(f'{root}/../escape', b'x'), header],
            'symlinked driver': [(f'{root}/{record["member"]}', ('symlink', 'clang')), header],
            'no headers': [(f'{root}/{record["member"]}', b'driver')],
            'no driver': [header],
        }
        for label, members in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'llvm.tar.xz'
                archive(path, members)
                with self.assertRaises(ValueError):
                    native.extract_release(path, Path(directory) / 'out', record, PIN['major'], '')
                self.assertFalse((Path(directory) / 'escape').exists())

    def test_source_links_cannot_leave_the_source_tree(self):
        root = PIN['source']['root']
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'source.tar.xz'
            archive(path, [(f'{root}/llvm/CMakeLists.txt', b'project(LLVM)'),
                           (f'{root}/llvm/escape', ('symlink', '../../../outside'))])
            with self.assertRaisesRegex(ValueError, 'escapes root'):
                native.extract_source(path, Path(directory) / 'source', root)


class SourceBuildTest(unittest.TestCase):
    environment = dict(CC='/usr/bin/gcc', CXX='/usr/bin/g++',
                       MACOSX_DEPLOYMENT_TARGET='13.0', SDKROOT='/sdk')

    def test_linux_clang_links_its_cxx_runtime_statically(self):
        arguments = native.cmake_arguments('linux-x64', '/src', '/build', self.environment)
        self.assertIn('-DLLVM_STATIC_LINK_CXX_STDLIB=ON', arguments)
        self.assertIn('-DCMAKE_EXE_LINKER_FLAGS=-static-libgcc', arguments)
        self.assertIn('-DLLVM_TARGETS_TO_BUILD=ARM', arguments)
        self.assertIn('-DLLVM_ENABLE_ZLIB=OFF', arguments)
        self.assertIn('-DCMAKE_C_COMPILER=/usr/bin/gcc', arguments)

    def test_intel_mac_builds_thin_x64_for_the_declared_minimum(self):
        arguments = native.cmake_arguments('macos-x64', '/src', '/build', self.environment)
        self.assertIn('-DCMAKE_OSX_ARCHITECTURES=x86_64', arguments)
        self.assertIn('-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0', arguments)

    def test_parallel_compiles_are_bounded_by_memory(self):
        gib = 1 << 30
        self.assertEqual(native.compile_jobs(10 * gib, 16), 5)
        self.assertEqual(native.compile_jobs(64 * gib, 8), 8)
        self.assertEqual(native.compile_jobs(gib, 8), 1)

    def test_windows_has_no_source_recipe(self):
        with self.assertRaises(ValueError):
            native.cmake_arguments('windows-x64', '/src', '/build', self.environment)


class AuditTest(unittest.TestCase):
    def test_windows_driver_may_import_system_dlls_only(self):
        # The imports of the pinned clang.exe (static CRT).
        upstream = ['advapi32.dll', 'kernel32.dll', 'ntdll.dll', 'ole32.dll', 'oleaut32.dll',
                    'shell32.dll', 'version.dll']
        with mock.patch.object(native, 'pe_imports', return_value=upstream):
            self.assertEqual(native.audit_tool('clang.exe', 'windows-x64')['dependencies'], upstream)
        for dependency in ('vcruntime140.dll', 'libwinpthread-1.dll', 'zlib1.dll'):
            with self.subTest(dependency=dependency), \
                    mock.patch.object(native, 'pe_imports', return_value=[*upstream, dependency]), \
                    self.assertRaisesRegex(ValueError, 'unbundled host dependency'):
                native.audit_tool('clang.exe', 'windows-x64')

    def test_official_linux_driver_dependencies_are_rejected(self):
        # Why linux-x64 builds from source: the release binary needs these.
        for dependency in ('libstdc++.so.6', 'libgcc_s.so.1', 'libz.so.1'):
            with self.subTest(dependency=dependency), self.assertRaises(ValueError):
                check_dependencies('linux-x64', ['libc.so.6', dependency], ['2.34'])

    def test_objects_must_be_armv6k_hard_float(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sample.o'
            for arch in native.CPU_ARCH_V6_V6K:
                path.write_bytes(elf(attributes={native.TAG_CPU_ARCH: arch, native.TAG_ABI_VFP_ARGS: 1}))
                kind, flags, attributes = native.require_armv6k_hard_float(path)
                self.assertEqual((kind, attributes[native.TAG_ABI_VFP_ARGS]), (1, 1))
            for label, attributes in [('soft-float', {native.TAG_CPU_ARCH: 9, native.TAG_ABI_VFP_ARGS: 0}),
                                      ('ARMv7', {native.TAG_CPU_ARCH: 10, native.TAG_ABI_VFP_ARGS: 1}),
                                      ('no attributes', None)]:
                with self.subTest(label):
                    path.write_bytes(elf(attributes=attributes))
                    with self.assertRaises(ValueError):
                        native.require_armv6k_hard_float(path)


class TargetConfigTest(unittest.TestCase):
    headers = dict(
        include=dict(c=['target/include', 'target/libctru/include'],
                     cxx=['target/include/c++/16.1.0', 'target/include/c++/16.1.0/arm-none-eabi/armv6k/fpu',
                          'target/include/c++/16.1.0/backward']),
        defines=['__3DS__'],
        abi_macros={'__INT32_TYPE__': 'long int', '__INT32_C(c)': 'c ## L', '__DEVKITPRO__': '1'},
        abi_checks={'__ARM_SIZEOF_MINIMAL_ENUM': '1'})
    clang = dict(resource_headers='lib/clang/23/include')

    def test_flags_come_from_the_ctr_profile_and_the_gcc_abi(self):
        config = native.target_config(PROFILE, self.clang, self.headers)
        flags = config['flags']
        self.assertEqual(flags[:1 + len(PROFILE['cflags'])], ['--target=arm-none-eabi', *PROFILE['cflags']])
        for flag in ('-fshort-enums', '-nostdinc', '-D__3DS__', '-U__INT32_TYPE__',
                     '-D__INT32_TYPE__=long int', '-U__INT32_C', '-D__INT32_C(c)=c ## L', '-D__DEVKITPRO__=1'):
            self.assertIn(flag, flags)
        self.assertLess(flags.index('-U__INT32_TYPE__'), flags.index('-D__INT32_TYPE__=long int'))
        self.assertEqual(config['cxx_flags'], ['--driver-mode=g++'])

    def test_int_sized_enums_add_no_short_enum_flag(self):
        headers = dict(self.headers, abi_checks={'__ARM_SIZEOF_MINIMAL_ENUM': '4'})
        self.assertNotIn('-fshort-enums', native.target_config(PROFILE, self.clang, headers)['flags'])

    def test_include_order_puts_libstdcxx_before_clang_before_newlib(self):
        include = native.target_config(PROFILE, self.clang, self.headers)['include']
        self.assertEqual(include['c'], ['lib/clang/23/include', 'target/include', 'target/libctru/include'])
        self.assertEqual(include['cxx'], [*self.headers['include']['cxx'], 'lib/clang/23/include',
                                          'target/include', 'target/libctru/include'])

    def test_header_paths_differing_only_by_case_are_found(self):
        self.assertEqual(native.case_collisions(['target/include/a.h', 'target/include/b.h']), [])
        self.assertEqual(native.case_collisions(['target/include/Foo.h', 'target/include/foo.h']),
                         [('target/include/Foo.h', 'target/include/foo.h')])


if __name__ == '__main__':
    unittest.main()
