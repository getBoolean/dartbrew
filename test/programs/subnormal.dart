import 'dart:typed_data';

const _tiny = 5e-324;
const _twiceTiny = 1e-323;

// Give the optimizer constant operands in an ordinary runtime method.
@pragma('vm:never-inline')
List<double> foldedResults() {
  final tiny = _tiny;
  final twiceTiny = _twiceTiny;
  return [tiny + tiny, twiceTiny - tiny, tiny * 2.0, twiceTiny / 2.0];
}

@pragma('vm:never-inline')
List<double> runtimeResults(double tiny, double twiceTiny) => [
  tiny + tiny,
  twiceTiny - tiny,
  tiny * 2.0,
  twiceTiny / 2.0,
];

int bits(double value) => (ByteData(8)..setFloat64(0, value)).getUint64(0);

void main() {
  // Decode operands at run time so the calls exercise runtime arithmetic.
  final bytes = ByteData(8);
  final tiny = (bytes..setUint64(0, 1)).getFloat64(0);
  final twiceTiny = (bytes..setUint64(0, 2)).getFloat64(0);
  const expected = [2, 1, 2, 1];
  const names = ['add', 'subtract', 'multiply', 'divide'];
  const trials = 20000;
  for (var trial = 0; trial < trials; trial++) {
    final folded = foldedResults();
    final actual = runtimeResults(tiny, twiceTiny);
    for (var i = 0; i < expected.length; i++) {
      final foldedBits = bits(folded[i]);
      final runtimeBits = bits(actual[i]);
      if (foldedBits != expected[i] || runtimeBits != expected[i]) {
        throw StateError(
          '${names[i]}: folded=$foldedBits runtime=$runtimeBits',
        );
      }
      if (trial == trials - 1) print('${names[i]}:$runtimeBits');
    }
  }
}
