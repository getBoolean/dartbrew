import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('check_release', Path(__file__).parents[1] / 'check_release.py')
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

VERSION = '9.9.9-test'
AZAHAR_NO_JIT = 'Azahar cannot run the JIT VM (needs Luma3DS custom SVC 0x80)'


def feature(name='files', **results):
    return dict(name=name, covers='U6, R1',
                results=dict(dict(console_aot='pass', console_jit='pass', azahar_aot='pass'), **results))


class CheckReleaseTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.archive = self.root / f'dartbrew-{VERSION}-linux-x64.zip'
        self.archive.write_bytes(b'qualified bytes')
        self.entry = dict(sdk_archive=self.archive.name, result='pass',
                          sdk_sha256=hashlib.sha256(b'qualified bytes').hexdigest())

    def tearDown(self):
        self.directory.cleanup()

    def results(self, version=VERSION, features=None, **changes):
        path = self.root / f'results-{len(list(self.root.glob("results-*.json")))}.json'
        document = dict(version=version, hosts=[dict(self.entry, **changes)])
        document['features'] = [feature()] if features is None else features
        if features == 'absent':
            del document['features']
        path.write_text(json.dumps(document))
        return path

    def test_qualified_archive_passes(self):
        self.assertEqual(check.check_release(self.results(), [self.archive], VERSION), [self.archive.name])

    def test_unqualified_archives_are_refused(self):
        other = self.root / f'dartbrew-{VERSION}-windows-x64.zip'
        other.write_bytes(b'qualified bytes')
        stale = self.root / 'dartbrew-0.0.1-linux-x64.zip'
        stale.write_bytes(b'qualified bytes')
        renamed = self.root / f'ctr-dart-{VERSION}-linux-x64.zip'
        renamed.write_bytes(b'qualified bytes')
        cases = [
            ('results for another version', self.results(version='0.0.1'), self.archive, 'not ' + VERSION),
            ('changed bytes', self.results(sdk_sha256='0' * 64), self.archive, 'differs'),
            ('failed qualification', self.results(result='fail'), self.archive, 'did not pass'),
            ('missing host record', self.results(), other, 'no qualification record'),
            ('older version name', self.results(sdk_archive=stale.name), stale, 'no qualification record'),
            ('pre-dartbrew archive name', self.results(sdk_archive=renamed.name), renamed,
             'no qualification record'),
        ]
        for label, results, archive, message in cases:
            with self.subTest(label), self.assertRaisesRegex(ValueError, message):
                check.check_release(results, [archive], VERSION)

    def test_default_version_comes_from_the_preview_manifest(self):
        current = json.loads((check.ROOT / 'release/preview.json').read_text(encoding='utf-8'))['version']
        self.assertNotEqual(current, VERSION)
        with self.assertRaisesRegex(ValueError, 'not ' + current):
            check.check_release(self.results(), [self.archive])

    def test_features_passing_on_required_environments_are_accepted(self):
        no_loader = dict(result='not_applicable', reason='Azahar cannot run the runtime .so loader')
        features = [feature('files'), feature('loader', azahar_aot=no_loader)]
        self.assertEqual(check.check_release(self.results(features=features), [self.archive], VERSION),
                         [self.archive.name])

    def test_feature_failures_are_refused_naming_feature_and_environment(self):
        not_applicable = dict(result='not_applicable', reason=AZAHAR_NO_JIT)
        cases = [
            ('failed console JIT', [feature('stdio', console_jit='fail')], 'stdio.*console_jit'),
            ('failed console AOT', [feature('romfs', console_aot='fail')], 'romfs.*console_aot'),
            ('missing environment', [dict(name='exit', covers='U8', results=dict(console_aot='pass', console_jit='pass'))],
             'exit.*azahar_aot'),
            ('not applicable without reason', [feature('loader', azahar_aot=dict(result='not_applicable'))],
             'loader.*azahar_aot'),
            ('not applicable with blank reason', [feature('loader', azahar_aot=dict(result='not_applicable', reason=' '))],
             'loader.*azahar_aot'),
            ('bare not applicable string', [feature('loader', azahar_aot='not_applicable')], 'loader.*azahar_aot'),
            ('second feature fails', [feature('files'), feature('platform', console_jit='fail')],
             'platform.*console_jit'),
            ('no features section', 'absent', 'no features'),
            ('empty features section', [], 'no features'),
        ]
        for label, features, message in cases:
            with self.subTest(label), self.assertRaisesRegex(ValueError, message):
                check.check_release(self.results(features=features), [self.archive], VERSION)
        accepted = [feature('jit-only', azahar_aot=not_applicable)]
        self.assertEqual(check.check_release(self.results(features=accepted), [self.archive], VERSION),
                         [self.archive.name])

    def test_preview_4_results_without_features_still_pass(self):
        version = '0.1.0-preview.4'
        committed = json.loads((check.ROOT / f'docs/qualification/{version}/results.json').read_text(encoding='utf-8'))
        self.assertNotIn('features', committed)
        archives = []
        for host in committed['hosts']:
            archive = self.root / host['sdk_archive']
            archive.write_bytes(host['host'].encode())
            host['sdk_sha256'] = hashlib.sha256(host['host'].encode()).hexdigest()
            archives.append(archive)
        path = self.root / 'preview4.json'
        path.write_text(json.dumps(committed))
        self.assertEqual(check.check_release(path, archives, version), [a.name for a in archives])
        with self.assertRaisesRegex(ValueError, 'no features'):
            committed['version'] = '0.1.0-preview.5'
            for archive, host in zip(archives, committed['hosts']):
                renamed = archive.with_name(archive.name.replace('preview.4', 'preview.5'))
                archive.rename(renamed)
                host['sdk_archive'] = renamed.name
            path.write_text(json.dumps(committed))
            check.check_release(path, [self.root / h['sdk_archive'] for h in committed['hosts']], '0.1.0-preview.5')
