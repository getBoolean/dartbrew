// Copyright (c) 2026, the Dart project authors. All rights reserved.
// Use of this source code is governed by a BSD-style license in LICENSE.
import 'dart:typed_data';
import 'dart:math' as math;

import 'numeric/numeric_compare_cases.dart';
import 'numeric/numeric_float_cases.dart';
import 'numeric/numeric_round_cases.dart';
import 'numeric/numeric_sqrt_cases.dart';
import 'numeric/numeric_pow_cases.dart';
import 'numeric/numeric_remainder_cases.dart';
import 'numeric/numeric_libm_cases.dart';

@pragma('vm:never-inline')
double fromBits(int bits) {
  final data = ByteData(8)..setUint64(0, bits, Endian.little);
  return data.getFloat64(0, Endian.little);
}

@pragma('vm:never-inline')
int bits(double value) {
  final data = ByteData(8)..setFloat64(0, value, Endian.little);
  return data.getUint64(0, Endian.little);
}

@pragma('vm:never-inline')
double divide(double left, double right) => left / right;
@pragma('vm:never-inline')
double add(double left, double right) => left + right;
@pragma('vm:never-inline')
double subtract(double left, double right) => left - right;
@pragma('vm:never-inline')
double multiply(double left, double right) => left * right;
@pragma('vm:never-inline')
double square(double value) => value * value;

void expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

@pragma('vm:never-inline')
double acrossAllocation(double value) {
  final live = List<double>.generate(32, (i) => add(value, fromBits(i + 1)));
  return subtract(live.last, fromBits(32));
}

@pragma('vm:never-inline')
bool equal(double left, double right) => left == right;
@pragma('vm:never-inline')
bool unequal(double left, double right) => left != right;
@pragma('vm:never-inline')
bool less(double left, double right) => left < right;
@pragma('vm:never-inline')
bool lessEqual(double left, double right) => left <= right;
@pragma('vm:never-inline')
bool greater(double left, double right) => left > right;
@pragma('vm:never-inline')
bool greaterEqual(double left, double right) => left >= right;

void compareMatrix() {
  for (final row in numericCompareCases) {
    final left = fromBits(row[0]);
    final right = fromBits(row[1]);
    final order = row[2];
    final location = '${row[0].toRadixString(16)}/${row[1].toRadixString(16)}';
    expect(equal(left, right) == (order == 0), 'equal $location');
    expect(unequal(left, right) == (order != 0), 'unequal $location');
    expect(less(left, right) == (order == -1), 'less $location');
    expect(
      lessEqual(left, right) == (order == -1 || order == 0),
      'lessEqual $location',
    );
    expect(greater(left, right) == (order == 1), 'greater $location');
    expect(
      greaterEqual(left, right) == (order == 0 || order == 1),
      'greaterEqual $location',
    );
  }
}

@pragma('vm:never-inline')
double minimum(double left, double right) => math.min(left, right);
@pragma('vm:never-inline')
double maximum(double left, double right) => math.max(left, right);
@pragma('vm:never-inline')
bool negative(double value) => value.isNegative;
@pragma('vm:never-inline')
bool nan(double value) => value.isNaN;
@pragma('vm:never-inline')
bool infinite(double value) => value.isInfinite;
@pragma('vm:never-inline')
bool finite(double value) => value.isFinite;

void minMaxMatrix() {
  for (final row in numericCompareCases) {
    final left = fromBits(row[0]);
    final right = fromBits(row[1]);
    final low = minimum(left, right);
    final high = maximum(left, right);
    final order = row[2];
    final location = '${row[0].toRadixString(16)}/${row[1].toRadixString(16)}';
    if (order == 2) {
      expect(nan(low) && nan(high), 'min/max NaN $location');
    } else {
      var expectedMin = order == 1 ? row[1] : row[0];
      var expectedMax = order == -1 ? row[1] : row[0];
      if (((row[0] | row[1]) & 0x7fffffffffffffff) == 0) {
        expectedMin = row[0] | row[1];
        expectedMax = row[0] & row[1];
      }
      expect(bits(low) == expectedMin, 'min $location');
      expect(bits(high) == expectedMax, 'max $location');
    }
  }
}

void classificationMatrix() {
  final patterns = numericCompareCases.map((row) => row[0]).toSet();
  for (final pattern in patterns) {
    final value = fromBits(pattern);
    final magnitude = pattern & 0x7fffffffffffffff;
    final isNan = magnitude > 0x7ff0000000000000;
    final location = pattern.toRadixString(16);
    expect(nan(value) == isNan, 'isNaN $location');
    expect(negative(value) == (pattern < 0 && !isNan), 'isNegative $location');
    expect(
      infinite(value) == (magnitude == 0x7ff0000000000000),
      'isInfinite $location',
    );
    expect(
      finite(value) == (magnitude < 0x7ff0000000000000),
      'isFinite $location',
    );
  }
}

@pragma('vm:never-inline')
double floorDouble(double v) => v.floorToDouble();
@pragma('vm:never-inline')
double ceilDouble(double v) => v.ceilToDouble();
@pragma('vm:never-inline')
double truncDouble(double v) => v.truncateToDouble();
@pragma('vm:never-inline')
double roundDouble(double v) => v.roundToDouble();
@pragma('vm:never-inline')
int truncInt(double v) => v.toInt();
@pragma('vm:never-inline')
int floorInt(double v) => v.floor();
@pragma('vm:never-inline')
int ceilInt(double v) => v.ceil();
@pragma('vm:never-inline')
int roundInt(double v) => v.round();

@pragma('vm:never-inline')
int narrowBits(double value) {
  final data = Float32List(1)..[0] = value;
  return Uint32List.view(data.buffer)[0];
}

@pragma('vm:never-inline')
double widenValue(int pattern) {
  final data = Uint32List(1)..[0] = pattern;
  return Float32List.view(data.buffer)[0];
}

void floatMatrix() {
  for (final row in numericFloatCases) {
    final location = row[1].toRadixString(16);
    if (row[0] == 1) {
      final actual = narrowBits(fromBits(row[1]));
      final expected = row[2];
      expect(
        (expected & 0x7fffffff) > 0x7f800000
            ? (actual & 0x7fffffff) > 0x7f800000
            : actual == expected,
        'narrow $location',
      );
    } else {
      final actual = widenValue(row[1]);
      final isNan = (row[1] & 0x7fffffff) > 0x7f800000;
      expect(isNan ? actual.isNaN : bits(actual) == row[2], 'widen $location');
    }
  }
}

void roundingMatrix() {
  for (final row in numericRoundCases) {
    final value = fromBits(row[0]);
    final location = row[0].toRadixString(16);
    final results = [
      floorDouble(value),
      ceilDouble(value),
      truncDouble(value),
      roundDouble(value),
    ];
    for (var i = 0; i < 4; i++) {
      expect(
        value.isNaN ? results[i].isNaN : bits(results[i]) == row[i + 1],
        'rounding $i $location',
      );
    }
    if (value.isFinite) {
      final integers = [
        truncInt(value),
        floorInt(value),
        ceilInt(value),
        roundInt(value),
      ];
      for (var i = 0; i < 4; i++) {
        expect(integers[i] == row[i + 5], 'integer $i $location');
      }
    } else {
      for (final operation in [truncInt, floorInt, ceilInt, roundInt]) {
        var threw = false;
        try {
          operation(value);
        } on UnsupportedError {
          threw = true;
        }
        expect(threw, 'missing integer error $location');
      }
    }
  }
}

@pragma('vm:never-inline')
double squareRoot(double value) => math.sqrt(value);

void sqrtMatrix() {
  for (final row in numericSqrtCases) {
    final value = squareRoot(fromBits(row[0]));
    final expectedNaN = (row[1] & 0x7fffffffffffffff) > 0x7ff0000000000000;
    expect(
      expectedNaN ? value.isNaN : bits(value) == row[1],
      'sqrt ${row[0].toRadixString(16)}',
    );
  }
}

void main() {
  final normal = fromBits(0x0010000000000000);
  final tiny = fromBits(1);
  final two = fromBits(0x4000000000000000);
  compareMatrix();
  classificationMatrix();
  minMaxMatrix();
  roundingMatrix();
  floatMatrix();
  sqrtMatrix();
  powMatrix();
  remainderMatrix();
  libmMatrix();
  for (var i = 0; i < 20000; i++) {
    expect(
      bits(divide(normal, two)) == 0x0008000000000000,
      'positive underflow',
    );
    expect(
      bits(divide(-normal, two)) == 0x8008000000000000,
      'negative underflow',
    );
    expect(bits(add(tiny, tiny)) == 2, 'subnormal addition');
    expect(
      bits(subtract(normal, tiny)) == 0x000fffffffffffff,
      'subnormal subtraction',
    );
    expect(bits(multiply(tiny, two)) == 2, 'subnormal multiplication');
    expect(
      bits(square(fromBits(0x1ff0000000000000))) == 0x0004000000000000,
      'square underflow',
    );
    expect(tiny > 0.0, 'positive subnormal comparison');
    expect(-tiny < 0.0, 'negative subnormal comparison');
    expect(tiny != 0.0, 'nonzero subnormal comparison');
    expect(tiny.toInt() == 0 && (-tiny).toInt() == 0, 'integer conversion');
    expect(bits(acrossAllocation(tiny)) == 1, 'allocation/runtime transport');
  }
  for (final value in [
    tiny,
    -tiny,
    normal,
    -0.0,
    double.infinity,
    double.negativeInfinity,
  ]) {
    expect(
      bits(double.parse(value.toString())) == bits(value),
      'parse/format roundtrip',
    );
  }
  expect(double.parse(double.nan.toString()).isNaN, 'NaN roundtrip');
  expect(divide(fromBits(0), fromBits(0)).isNaN, 'invalid arithmetic');
  expect(
    bits(divide(fromBits(0x8000000000000000), two)) == 0x8000000000000000,
    'signed zero',
  );
  print('focused numeric checks passed');
}

@pragma('vm:never-inline')
double power(double value, double exponent) =>
    math.pow(value, exponent).toDouble();

void powMatrix() {
  for (final row in numericPowCases) {
    final actual = power(fromBits(row[0]), fromBits(row[1]));
    final expected = fromBits(row[2]);
    expect(
      expected.isNaN ? actual.isNaN : bits(actual) == row[2],
      'pow ${row[0].toRadixString(16)}/${row[1].toRadixString(16)}',
    );
  }
}

@pragma('vm:never-inline')
double remainder(double left, double right) => left.remainder(right);
@pragma('vm:never-inline')
double modulo(double left, double right) => left % right;

void remainderMatrix() {
  for (final row in numericRemainderCases) {
    final left = fromBits(row[0]);
    final right = fromBits(row[1]);
    final r = remainder(left, right);
    final m = modulo(left, right);
    final location = '${row[0].toRadixString(16)}/${row[1].toRadixString(16)}';
    expect(
      fromBits(row[2]).isNaN ? r.isNaN : bits(r) == row[2],
      'remainder $location',
    );
    expect(
      fromBits(row[3]).isNaN ? m.isNaN : bits(m) == row[3],
      'modulo $location',
    );
  }
}

@pragma('vm:never-inline')
double libmPow(double x, double y) => math.pow(x, y).toDouble();

@pragma('vm:never-inline')
double libmSin(double x) => math.sin(x);

@pragma('vm:never-inline')
double libmLog(double x) => math.log(x);

@pragma('vm:never-inline')
double libmAtan2(double x, double y) => math.atan2(x, y);

@pragma('vm:never-inline')
double libmCos(double x) => math.cos(x);

@pragma('vm:never-inline')
double libmTan(double x) => math.tan(x);

@pragma('vm:never-inline')
double libmAsin(double x) => math.asin(x);

@pragma('vm:never-inline')
double libmAcos(double x) => math.acos(x);

@pragma('vm:never-inline')
double libmAtan(double x) => math.atan(x);

@pragma('vm:never-inline')
double libmExp(double x) => math.exp(x);

@pragma('vm:never-inline')
double libmFloor(double x) => x.floorToDouble();

@pragma('vm:never-inline')
double libmCeil(double x) => x.ceilToDouble();

@pragma('vm:never-inline')
double libmTrunc(double x) => x.truncateToDouble();

@pragma('vm:never-inline')
double libmRound(double x) => x.roundToDouble();

void libmMatrix() {
  const magnitude = 0x7fffffffffffffff;
  const infinity = 0x7ff0000000000000;
  for (final row in numericLibmCases) {
    final x = fromBits(row[1]), y = fromBits(row[2]);
    final double value;
    switch (row[0]) {
      case 0:
        value = libmPow(x, y);
        break;
      case 1:
        value = libmSin(x);
        break;
      case 2:
        value = libmLog(x);
        break;
      case 3:
        value = libmAtan2(x, y);
        break;
      case 4:
        value = libmCos(x);
        break;
      case 5:
        value = libmTan(x);
        break;
      case 6:
        value = libmAsin(x);
        break;
      case 7:
        value = libmAcos(x);
        break;
      case 8:
        value = libmAtan(x);
        break;
      case 9:
        value = libmExp(x);
        break;
      case 10:
        value = libmFloor(x);
        break;
      case 11:
        value = libmCeil(x);
        break;
      case 12:
        value = libmTrunc(x);
        break;
      case 13:
        value = libmRound(x);
        break;
      default:
        throw StateError('unknown math operation');
    }
    final actual = bits(value), expected = row[3];
    final a = actual & magnitude, e = expected & magnitude;
    final bool same;
    if (actual == expected) {
      same = true;
    } else if (e > infinity) {
      same = a > infinity && (actual & 0x0008000000000000) != 0;
    } else if (row[0] >= 10 ||
        a == 0 ||
        e == 0 ||
        a >= infinity ||
        e >= infinity) {
      same = false;
    } else {
      same = (actual < 0) == (expected < 0) && (actual - expected).abs() <= 2;
    }
    expect(
      same,
      'libm ${row[0]} ${row[1].toRadixString(16)}/${row[2].toRadixString(16)}',
    );
  }
}
