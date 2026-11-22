"""Public command integration tests using local Git repositories only."""
import hashlib
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import bootstrap  # noqa: E402
from common import DEFAULT_MANIFEST, read_json, verify_icu  # noqa: E402


def run(*args, cwd=None):
    return subprocess.run([str(x) for x in args], cwd=cwd, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


class ToolchainTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.upstream = self.base / 'upstream'
        self.upstream.mkdir()
        self.git('init', cwd=self.upstream)
        self.git('config', 'user.name', 'Fixture', cwd=self.upstream)
        self.git('config', 'user.email', 'fixture@example.invalid', cwd=self.upstream)
        self.git('config', 'core.autocrlf', 'false', cwd=self.upstream)
        (self.upstream / 'feature.txt').write_bytes(b'upstream\n')
        self.git('add', 'feature.txt', cwd=self.upstream)
        self.git('commit', '-m', 'fixture', cwd=self.upstream)
        self.rev = self.git('rev-parse', 'HEAD', cwd=self.upstream).stdout.strip()
        (self.upstream / 'feature.txt').write_bytes(b'ctr patch\n')
        patch = self.git('diff', '--binary', cwd=self.upstream).stdout
        self.patch = self.base / 'port.patch'
        self.patch.write_bytes(patch.encode())
        self.git('restore', 'feature.txt', cwd=self.upstream)
        self.manifest = self.base / 'versions.json'
        self.data = {'schema_version': 1,
            'dart': {'repository': str(self.upstream), 'revision': self.rev, 'version': 'fixture'},
            'patches': [{'path': self.patch.name, 'sha256': hashlib.sha256(self.patch.read_bytes()).hexdigest()}],
            'dependencies': {'depot_tools': {'repository': str(self.upstream), 'revision': self.rev},
                             'dart_deps': {'path': 'DEPS', 'sha256': 'fixture'}},
            'container': {'image': 'fixture@sha256:' + '0' * 64}}
        self.save_manifest()
        self.source = self.base / 'managed'

    def save_manifest(self):
        self.manifest.write_text(json.dumps(self.data))

    def git(self, *args, cwd):
        result = run('git', *args, cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def bootstrap(self):
        return run(sys.executable, ROOT / 'bootstrap.py', '--manifest', self.manifest,
                   '--source', self.source)

    def verify(self):
        return run(sys.executable, ROOT / 'bootstrap.py', 'verify', '--manifest', self.manifest,
                   '--source', self.source)

    def test_clean_materialization_reproduces_patch_and_is_idempotent(self):
        first = self.bootstrap()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual((self.source / 'feature.txt').read_text(), 'ctr patch\n')
        head = self.git('rev-parse', 'HEAD', cwd=self.source).stdout
        self.assertEqual(self.git('status', '--porcelain', cwd=self.source).stdout, '')
        second = self.bootstrap()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=self.source).stdout, head)
        state = json.loads(first.stdout)
        self.assertEqual(state['upstream_revision'], self.rev)
        self.assertEqual(state['patches'][0]['sha256'], self.data['patches'][0]['sha256'])

    def test_verify_accepts_a_bootstrapped_checkout(self):
        self.assertEqual(self.bootstrap().returncode, 0)
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['upstream_revision'], self.rev)

    def test_verify_names_a_patch_whose_hash_differs_from_its_pin(self):
        self.assertEqual(self.bootstrap().returncode, 0)
        self.patch.write_text('tampered')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('patch hash mismatch', result.stderr)
        self.assertIn(self.patch.name, result.stderr)

    def test_verify_refuses_a_missing_checkout_without_creating_it(self):
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unmanaged', result.stderr.lower())
        self.assertFalse(self.source.exists())

    def test_dirty_source_is_refused_and_edits_survive(self):
        self.assertEqual(self.bootstrap().returncode, 0)
        edit = self.source / 'feature.txt'
        edit.write_text('precious edit\n')
        result = self.bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('dirty', result.stderr.lower())
        self.assertEqual(edit.read_text(), 'precious edit\n')

    def test_wrong_clean_source_is_refused_without_reset(self):
        self.assertEqual(self.bootstrap().returncode, 0)
        self.git('checkout', '--detach', self.rev, cwd=self.source)
        head = self.git('rev-parse', 'HEAD', cwd=self.source).stdout
        result = self.bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('mismatch', result.stderr.lower())
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=self.source).stdout, head)

    def test_unmanaged_directory_is_preserved(self):
        self.source.mkdir()
        (self.source / 'keep').write_text('private')
        result = self.bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unmanaged', result.stderr.lower())
        self.assertEqual((self.source / 'keep').read_text(), 'private')

    def test_patch_hash_mismatch_refuses_before_materializing(self):
        self.patch.write_text('tampered')
        result = self.bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('hash', result.stderr.lower())
        self.assertFalse(self.source.exists())

    def test_icu_patch_is_replayed_and_preserves_local_changes(self):
        pin = {**self.data['dart'], 'patches': self.data['patches']}
        self.data['dependencies']['icu'] = pin
        self.save_manifest()
        dependency = self.source / 'third_party' / 'icu'
        dependency.parent.mkdir(parents=True)
        self.git('clone', str(self.upstream), str(dependency), cwd=self.base)
        self.git('config', 'core.autocrlf', 'false', cwd=dependency)
        bootstrap.patch_icu(self.source, self.data, self.manifest)
        self.assertEqual((dependency / 'feature.txt').read_text(), 'ctr patch\n')
        head = self.git('rev-parse', 'HEAD', cwd=dependency).stdout
        bootstrap.patch_icu(self.source, self.data, self.manifest)
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=dependency).stdout, head)
        verify_icu(self.source, self.data)
        # gclient can restore the pinned clean dependency on a later sync.
        self.git('checkout', '--detach', self.rev, cwd=dependency)
        bootstrap.patch_icu(self.source, self.data, self.manifest)
        self.assertEqual(self.git('rev-parse', 'HEAD', cwd=dependency).stdout, head)
        (dependency / 'feature.txt').write_text('unexpected committed change\n')
        self.git('add', 'feature.txt', cwd=dependency)
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-m', 'unexpected dependency commit', cwd=dependency)
        with self.assertRaisesRegex(RuntimeError, 'mismatch'):
            bootstrap.patch_icu(self.source, self.data, self.manifest)
        self.git('checkout', '--detach', head.strip(), cwd=dependency)
        (dependency / 'feature.txt').write_text('private edit\n')
        with self.assertRaisesRegex(RuntimeError, 'dirty'):
            bootstrap.patch_icu(self.source, self.data, self.manifest)
        self.assertEqual((dependency / 'feature.txt').read_text(), 'private edit\n')
        with self.assertRaisesRegex(RuntimeError, 'dirty'):
            verify_icu(self.source, self.data)

    def test_icu_patch_hash_is_checked_before_source_creation(self):
        self.data['dependencies']['icu'] = {
            **self.data['dart'], 'patches': self.data['patches']}
        self.data['patches'] = []
        self.save_manifest()
        self.patch.write_text('tampered dependency patch')
        result = self.bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('hash', result.stderr.lower())
        self.assertFalse(self.source.exists())

    def test_pinned_patch_and_specs_bytes_survive_autocrlf_checkout(self):
        shutil.copyfile(ROOT.parent / '.gitattributes', self.upstream / '.gitattributes')
        manifest = json.loads((ROOT / 'versions.json').read_text())
        all_patches = manifest['patches'] + manifest['dependencies'].get('icu', {}).get('patches', [])
        files = [ROOT / patch['path'] for patch in all_patches] + [ROOT / name for name in
            ('ctr.specs', 'versions.json', 'target-ctr.json')]
        for path in files:
            destination = self.upstream / 'toolchain' / path.relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        self.git('-c', 'core.autocrlf=false', 'add', '.gitattributes', 'toolchain', cwd=self.upstream)
        self.git('commit', '-m', 'locked source inputs', cwd=self.upstream)
        checkout = self.base / 'crlf-checkout'
        self.git('-c', 'core.autocrlf=true', 'clone', '--quiet', self.upstream, checkout, cwd=self.base)
        for patch in all_patches:
            path = checkout / 'toolchain' / patch['path']
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), patch['sha256'])
        self.assertEqual((checkout / 'toolchain' / 'ctr.specs').read_bytes(), (ROOT / 'ctr.specs').read_bytes())


class HostTest(unittest.TestCase):
    def test_supported_hosts_select_their_gclient_and_gn_executables(self):
        manifest = read_json(DEFAULT_MANIFEST)
        for system, machine, name, gclient, gn in [
                ('Linux', 'x86_64', 'linux-x64', 'gclient', 'gn'),
                ('Windows', 'AMD64', 'windows-x64', 'gclient.bat', 'gn.exe'),
                ('Darwin', 'x86_64', 'macos-x64', 'gclient', 'gn'),
                ('Darwin', 'arm64', 'macos-arm64', 'gclient', 'gn')]:
            with self.subTest(host=name):
                host = bootstrap.current_host(manifest, system, machine)
                self.assertEqual(host.name, name)
                self.assertEqual(host.gclient, gclient)
                self.assertEqual(host.gn, gn)
                self.assertRegex(bootstrap.gn_pin(manifest, host)['binary_sha256'], r'^[0-9a-f]{64}$')

    def test_unsupported_host_is_refused(self):
        manifest = read_json(DEFAULT_MANIFEST)
        for system, machine in [('Windows', 'arm64'), ('Linux', 'aarch64'), ('FreeBSD', 'amd64')]:
            with self.subTest(system=system, machine=machine):
                with self.assertRaisesRegex(RuntimeError, 'unsupported host'):
                    bootstrap.current_host(manifest, system, machine)

    def test_mismatched_gclient_is_preserved(self):
        manifest = read_json(DEFAULT_MANIFEST)
        with tempfile.TemporaryDirectory(prefix='bootstrap-test-') as temp:
            source = Path(temp) / 'sdk'
            config = Path(temp) / '.gclient'
            config.write_text('owner configuration\n')
            with self.assertRaisesRegex(RuntimeError, 'unmanaged or mismatched'):
                bootstrap.write_gclient_config(source, manifest)
            self.assertEqual(config.read_text(), 'owner configuration\n')
            config.unlink()
            bootstrap.write_gclient_config(source, manifest)
            bootstrap.write_gclient_config(source, manifest)
            self.assertEqual(config.read_text(), bootstrap.gclient_config(source, manifest))

    def test_gn_archive_and_binary_are_both_verified(self):
        data = b'unit-test bytes, not a compiler'
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('gn', data)
        archive = buffer.getvalue()
        pin = dict(archive_sha256=hashlib.sha256(archive).hexdigest(),
                   binary_sha256=hashlib.sha256(data).hexdigest())
        self.assertEqual(bootstrap.checked_gn_bytes(archive, pin, 'gn'), data)
        with self.assertRaisesRegex(RuntimeError, 'archive hash'):
            bootstrap.checked_gn_bytes(archive + b'changed', pin, 'gn')
        with self.assertRaisesRegex(RuntimeError, 'binary hash'):
            bootstrap.checked_gn_bytes(archive, {**pin, 'binary_sha256': '0' * 64}, 'gn')


@unittest.skipUnless(os.environ.get('CTR_SDK_INTEGRATION') == '1',
                     'set CTR_SDK_INTEGRATION=1 after materializing the pinned SDK')
class SdkPatchReproductionTest(unittest.TestCase):
    def test_actual_sdk_patch_queue_reproduces_the_managed_tree(self):
        actual = Path(os.environ.get('CTR_SDK_SOURCE',
                                     ROOT.parent / 'third_party' / 'dart-sdk'))
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            manifest = json.loads((ROOT / 'versions.json').read_text())
            manifest['dart']['repository'] = str(actual)
            for patch in manifest['patches']:
                patch['path'] = str((ROOT / patch['path']).resolve())
            for patch in manifest['dependencies'].get('icu', {}).get('patches', []):
                patch['path'] = str((ROOT / patch['path']).resolve())
            fixture = base / 'versions.json'
            fixture.write_text(json.dumps(manifest))
            reproduced = base / 'dart-sdk'
            result = run(sys.executable, ROOT / 'bootstrap.py', '--manifest', fixture,
                         '--source', reproduced)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = run('git', '-C', actual, 'rev-parse', 'HEAD^{tree}')
            observed = run('git', '-C', reproduced, 'rev-parse', 'HEAD^{tree}')
            self.assertEqual(expected.returncode, 0, expected.stderr)
            self.assertEqual(observed.returncode, 0, observed.stderr)
            self.assertEqual(observed.stdout, expected.stdout)
            status = run('git', '-C', reproduced, 'status', '--porcelain')
            self.assertEqual(status.returncode, 0, status.stderr)
            self.assertEqual(status.stdout, '')


if __name__ == '__main__':
    unittest.main()
