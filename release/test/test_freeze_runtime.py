import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from freeze_runtime import freeze_runtime


class RuntimeExportTest(unittest.TestCase):
    def test_existing_directory_is_preserved_before_source_access(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            owner = output / 'owner'
            owner.write_text('keep')
            with self.assertRaisesRegex(RuntimeError, 'exists'):
                freeze_runtime(output / 'absent-sdk', output / 'absent-build', output)
            self.assertEqual(list(output.iterdir()), [owner])
            self.assertEqual(owner.read_text(), 'keep')


@unittest.skipUnless(os.environ.get('CTR_RUNTIME_EXPORT'),
                     'set CTR_RUNTIME_EXPORT to a freeze_runtime.py output directory')
class ExportedIoLibraryTest(unittest.TestCase):
    def test_io_library_links_whole_against_each_runtime(self):
        runtime = Path(os.environ['CTR_RUNTIME_EXPORT'])
        record = json.loads((runtime / 'runtime.json').read_text())
        profile = json.loads((ROOT / 'toolchain/target-ctr.json').read_text())
        prefix = profile['compiler_prefix']
        link = record['link']
        asset = lambda name: str(runtime / name)
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / 'main.cc').write_text('int main() { return 0; }\n')
            subprocess.run([prefix + 'g++', *profile['cflags'], '-c', work / 'main.cc',
                            '-o', work / 'main.o'], check=True)
            for mode in ('aot', 'jit'):
                with self.subTest(mode=mode):
                    io = record['modes'][mode]['io_archive']
                    self.assertEqual(io, f'lib/{mode}/io.a')
                    self.assertIn(io, record['files'])
                    # The application link of dartbrew's CTR pipeline, with every
                    # I/O object forced in so no unresolved reference can hide.
                    result = subprocess.run([
                        prefix + 'ld', '--defsym=__sync_synchronize=__sync_synchronize_cp15dmb',
                        '-T', asset(link['layout']), '-u', '__sync_synchronize_cp15dmb',
                        '-o', work / f'{mode}.elf', *map(asset, link['startup']), work / 'main.o',
                        asset(link['math']), '--whole-archive', asset(io), '--no-whole-archive',
                        asset(record['modes'][mode]['archive']), *map(asset, link['libraries']),
                        '--start-group', *map(asset, link['grouped']), '--end-group',
                        *map(asset, link['end'])], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
