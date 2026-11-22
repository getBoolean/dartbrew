"""Pure producer contract tests; these do not qualify a native compiler build."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import ctypes
import random
import shutil

MODULE = Path(__file__).resolve().parents[1] / 'native_precompiler.py'
spec = importlib.util.spec_from_file_location('native_precompiler', MODULE)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativePrecompilerTests(unittest.TestCase):
    def test_producer_overlay_restores_owned_sources_and_preserves_foreign_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            graph = source / 'runtime/bin/BUILD.gn'
            graph.parent.mkdir(parents=True)
            original = b'    sources = [\n      "gen_snapshot.cc",\n    ]\n'
            graph.write_bytes(original)
            os_source = source / 'runtime/vm/os_macos.cc'
            os_source.parent.mkdir(parents=True)
            os_source.write_bytes(b'intptr_t OS::ActivationFrameAlignment() {\n#if DART_HOST_OS_IOS\n'
                                  b'#endif  // DART_HOST_OS_IOS\n}\n\nuintptr_t OS::CurrentRSS() {')
            with native.producer_overlay(source) as receipt:
                self.assertIn(b'ctr_stable_sort.c', graph.read_bytes())
                self.assertIn('DART_TARGET_OS_CTR', os_source.read_text())
                self.assertEqual(receipt['kind'], 'native-sort-and-target-alignment-v1')
            self.assertEqual(graph.read_bytes(), original)
            self.assertFalse((graph.parent / 'ctr_stable_sort.c').exists())
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                with native.producer_overlay(source):
                    graph.write_bytes(b'foreign edit')
            self.assertEqual(graph.read_bytes(), b'foreign edit')

    @unittest.skipUnless(shutil.which('cc'), 'native C compiler required')
    def test_native_sort_preserves_equal_key_order_for_dynamic_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            library = Path(directory) / 'sort.so'
            subprocess.run(['cc', '-shared', '-fPIC', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-Dqsort=ctr_test_sort', str(MODULE.with_name('native_stable_sort.c')),
                            '-o', str(library)], check=True)
            callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
            class Pair(ctypes.Structure):
                _fields_ = [('key', ctypes.c_int), ('sequence', ctypes.c_int)]
            def compare(left, right):
                a = ctypes.cast(left, ctypes.POINTER(Pair)).contents.key
                b = ctypes.cast(right, ctypes.POINTER(Pair)).contents.key
                return (a > b) - (a < b)
            callback = callback_type(compare)
            sort = ctypes.CDLL(str(library)).ctr_test_sort
            sort.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, callback_type]
            rng = random.Random(2105)
            for length in [0, 1, 2, 3, 31, 32, 33, 129, 1000]:
                values = [(rng.randrange(-5, 6), i) for i in range(length)]
                array = (Pair * length)(*[Pair(*pair) for pair in values])
                sort(array, length, ctypes.sizeof(Pair), callback)
                self.assertEqual([(p.key, p.sequence) for p in array], sorted(values, key=lambda p: p[0]))

    def test_supported_host_graphs_are_native_with_ctr_arm_backend(self):
        manifest = json.loads(native.DEFAULT_MANIFEST.read_text(encoding='utf-8'))
        for system, cpu, expected in [('Windows', 'AMD64', 'windows-x64'),
                                      ('Darwin', 'x86_64', 'macos-x64'),
                                      ('Darwin', 'arm64', 'macos-arm64'),
                                      ('Linux', 'x86_64', 'linux-x64')]:
            with self.subTest(host=expected):
                host = native.current_host(manifest, system, cpu)
                self.assertEqual(host.name, expected)
                args = native.gn_arguments(host)
                self.assertEqual(args['current_cpu'], expected.split('-')[1])
                self.assertEqual(args['target_cpu'], args['current_cpu'])
                self.assertEqual(args['target_os'], 'ctr')
                self.assertEqual(args['dart_target_arch'], 'arm')
                self.assertTrue(args['dart_armv6k'])
                self.assertFalse(args['dart_use_compressed_pointers'])
                self.assertFalse(any(key.startswith(('arm_', 'ctr_')) for key in args))

    def test_generated_identity_is_extracted_and_bound_to_source(self):
        head = 'abcdef0123456789abcdef0123456789abcdef01'
        text = ('const char* Version::snapshot_hash_ = "' + '1' * 32 + '";\n'
                'const char* Version::git_short_hash_ = "abcdef0123";\n')
        self.assertEqual(native.generated_identity(text, head),
                         dict(snapshot_hash='1' * 32, git_short_hash='abcdef0123'))
        with self.assertRaisesRegex(RuntimeError, 'does not match'):
            native.generated_identity(text, '0' * 40)
        with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
            native.generated_identity(text + text, head)

    def test_ctr_definitions_are_required(self):
        self.assertEqual(native.verify_definitions('\n'.join(native.REQUIRED_DEFINES)),
                         sorted(native.REQUIRED_DEFINES))
        with self.assertRaisesRegex(RuntimeError, 'missing CTR'):
            native.verify_definitions('TARGET_ARCH_X64 DART_TARGET_OS_LINUX')

    def test_existing_output_and_unbounded_jobs_fail_before_materialization(self):
        with tempfile.TemporaryDirectory(prefix='native-precompiler-test-') as temp:
            with patch.object(native, 'materialize') as materialize:
                with self.assertRaisesRegex(RuntimeError, 'output already exists'):
                    native.build(Path(temp) / 'work', Path(temp), native.DEFAULT_MANIFEST, 2)
                with self.assertRaisesRegex(RuntimeError, 'jobs must be'):
                    native.build(Path(temp) / 'work', Path(temp) / 'new', native.DEFAULT_MANIFEST, 9)
                materialize.assert_not_called()


if __name__ == '__main__':
    unittest.main()
