"""Generated SDK identity contract read by freeze_runtime.py."""
import importlib.util
from pathlib import Path
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'native_precompiler.py'
spec = importlib.util.spec_from_file_location('native_precompiler', MODULE)
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class GeneratedIdentityTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
