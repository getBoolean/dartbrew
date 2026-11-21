import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('bundle_native_sdk', Path(__file__).parents[1] / 'bundle_native_sdk.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class BundlePolicyTest(unittest.TestCase):
    def test_unsealed_component_cannot_be_copied(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            asset = root / 'asset'
            asset.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                bundle.checked(root, 'asset', '0' * 64)

    def test_component_identity_mismatches_are_rejected(self):
        head = 'a' * 40
        cases = [
            ('host', ('host', 'host'), 'macos-arm64', 'host or SDK identity'),
            ('binutils host', ('arm', 'host'), 'windows-x64', 'host or SDK identity'),
            ('SDK head', ('runtime', 'sdk_head'), 'b' * 40, 'host or SDK identity'),
            ('Program size', ('runtime', 'program_size'), 36, 'Program ABI'),
            ('identity offset', ('runtime', 'program_identity_offset'), 20, 'Program ABI'),
            ('short hash', ('host', 'generated', 'git_short_hash'), 'c' * 10, 'SDK hash'),
            ('snapshot hash', ('runtime', 'snapshot_hash'), 'e' * 32, 'snapshot hash'),
        ]
        for label, path, value, message in cases:
            with self.subTest(label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                documents = {
                    'host': dict(host='linux-x64', source=dict(head=head),
                                 generated=dict(git_short_hash=head[:10], snapshot_hash='d' * 32)),
                    'arm': dict(host='linux-x64'),
                    'runtime': dict(sdk_head=head, program_size=32,
                                    program_identity_offset=16, snapshot_hash='d' * 32),
                }
                target = documents[path[0]]
                for key in path[1:-1]:
                    target = target[key]
                target[path[-1]] = value
                for name, folder, filename in [('host', 'precompiler', 'native-precompiler.json'),
                                               ('arm', 'binutils', 'provenance.json'),
                                               ('runtime', 'runtime', 'runtime.json')]:
                    (root / folder).mkdir()
                    (root / folder / filename).write_text(json.dumps(documents[name]))
                with self.assertRaisesRegex(ValueError, message):
                    bundle.assemble(root / 'ctr', root / 'precompiler', root / 'binutils',
                                    root / 'runtime', root / 'out' / 'sdk', 'test')
                self.assertFalse((root / 'out').exists())

    def test_compiler_components_are_checked_before_output(self):
        head = 'a' * 40
        library = 'f' * 64
        cases = [
            ('clang without headers', dict(headers=False), 'used together'),
            ('clang host', dict(clang_host='windows-x64'), 'clang component host'),
            ('headers from another devkitPro', dict(header_library='0' * 64), 'frozen runtime library'),
        ]
        for label, change, message in cases:
            with self.subTest(label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                documents = {
                    ('precompiler', 'native-precompiler.json'): dict(
                        host='linux-x64', source=dict(head=head),
                        generated=dict(git_short_hash=head[:10], snapshot_hash='d' * 32)),
                    ('binutils', 'provenance.json'): dict(host='linux-x64'),
                    ('runtime', 'runtime.json'): dict(
                        sdk_head=head, program_size=32, program_identity_offset=16, snapshot_hash='d' * 32,
                        producer=dict(original_sha256={'lib/shared/libc.a': library})),
                    ('clang', 'provenance.json'): dict(host=change.get('clang_host', 'linux-x64'), files={}),
                    ('headers', 'headers.json'): dict(
                        library_sha256={'lib/shared/libc.a': change.get('header_library', library)}, files={}),
                }
                for (folder, filename), document in documents.items():
                    (root / folder).mkdir()
                    (root / folder / filename).write_text(json.dumps(document))
                headers = root / 'headers' if change.get('headers', True) else None
                with self.assertRaisesRegex(ValueError, message):
                    bundle.assemble(root / 'ctr', root / 'precompiler', root / 'binutils', root / 'runtime',
                                    root / 'out' / 'sdk', 'test', clang=root / 'clang', headers=headers)
                self.assertFalse((root / 'out').exists())

    def test_existing_output_is_preserved_before_component_access(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            owner = output / 'owner'
            owner.write_text('keep')
            with self.assertRaisesRegex(ValueError, 'exists'):
                bundle.assemble('absent', 'absent', 'absent', 'absent', output, 'test')
            self.assertEqual(list(output.iterdir()), [owner])
            self.assertEqual(owner.read_text(), 'keep')

    def test_readme_describes_dartbrew_commands(self):
        for command in ('doctor', 'create', 'compile', 'run', 'test', 'devices'):
            self.assertIn('dartbrew ' + command, bundle.README_TEXT)
        self.assertIn('dartbrew.exe', bundle.README_TEXT)
        self.assertNotIn('ctr build', bundle.README_TEXT)
        self.assertNotIn('ctr doctor', bundle.README_TEXT)
