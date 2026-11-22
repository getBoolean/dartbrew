import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('runtime_results', Path(__file__).parents[1] / 'results.py')
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)

# Shared with packages/dartbrew/test/verdict_test.dart so the two ports cannot drift.
VECTORS = json.loads((Path(__file__).parent / 'verdict_vectors.json').read_text())['cases']


class JournalTest(unittest.TestCase):
    def test_vectors(self):
        for case in VECTORS:
            with self.subTest(case['name']):
                value = results.validate('\n'.join(case['lines']), case['identity'], case.get('observation'))
                expect = case['expect']
                self.assertEqual(value['outcome'], expect['outcome'], value)
                self.assertEqual(value.get('reason'), expect['reason'], value)
                self.assertEqual(value['output'], expect['output'], value)
                self.assertEqual(value.get('exit_code'), expect.get('exit_code'), value)

    def test_truncation_at_every_record_boundary(self):
        case = VECTORS[0]
        self.assertEqual(case['expect']['outcome'], 'pass')
        for count in range(len(case['lines'])):
            with self.subTest(count=count):
                value = results.validate('\n'.join(case['lines'][:count]), case['identity'])
                self.assertEqual(value['outcome'], 'incomplete', value)
