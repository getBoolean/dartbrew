"""The ULP allowance CTR math results are compared with."""

# Operation numbers index this tuple; from Floor on they round to integers.
NAMES = ('Pow', 'Sin', 'Log', 'Atan2', 'Cos', 'Tan', 'Asin', 'Acos', 'Atan',
         'Exp', 'Floor', 'Ceil', 'Trunc', 'Round')


def agrees(op, actual, expected):
    if actual == expected:
        return True
    magnitude = 0x7fffffffffffffff
    a, e = actual & magnitude, expected & magnitude
    if e > 0x7ff0000000000000:
        return a > 0x7ff0000000000000 and bool(actual & (1 << 51))
    # Special values, signed zeros and integral rounding stay bit-exact. Do not
    # allow a nonzero subnormal to be replaced by zero within a ULP allowance.
    if op >= NAMES.index('Floor') or a == 0 or e == 0 or a >= 0x7ff0000000000000 or e >= 0x7ff0000000000000:
        return False
    return actual >> 63 == expected >> 63 and abs(actual - expected) <= 2
