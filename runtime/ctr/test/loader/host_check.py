"""U5 host check: validates loader_core.c's relocation processing without a console.

Runs the host build of the loader (host_check) on libsample.so at a fake base and
checks every relocated slot against values computed independently from
devkitARM's readelf output. Also checks the unsupported-relocation and
missing-symbol errors.

usage: python3 host_check.py HOST_CHECK READELF LIBSAMPLE_SO LIBBADRELOC_SO WORKDIR
"""
import os
import re
import struct
import subprocess
import sys

BASE = 0x30000000
EXPORTS = {"host_log": 0x00100010, "host_value": 0x00100020,
           "__aeabi_idiv": 0x00100030, "strlen": 0x00100040}
LOOKUPS = ["add", "get_initialized", "call_through_pointer", "read_host_value",
           "read_sample_global", "divide", "message_length", "scale"]
REQUIRED = {"R_ARM_RELATIVE", "R_ARM_ABS32", "R_ARM_GLOB_DAT", "R_ARM_JUMP_SLOT"}

failures = 0


def check(ok, label):
    global failures
    if not ok:
        failures += 1
    print(("PASS " if ok else "FAIL ") + label)


def run(*args):
    return subprocess.run(args, capture_output=True, text=True)


def readelf(tool, flags, path):
    result = run(tool, "-W", *flags, path)
    if result.returncode != 0:
        sys.exit(result.stderr)
    return result.stdout


def main(host, tool, sample, bad, workdir):
    data = open(sample, "rb").read()
    header = readelf(tool, ["-h"], sample)
    check(re.search(r"Type:\s+DYN", header) is not None, "libsample.so is ET_DYN")
    check("hard-float ABI" in header, "libsample.so is hard-float EABI")

    segments = []  # (offset, vaddr, filesz, memsz, flags)
    for m in re.finditer(r"^\s*LOAD\s+0x(\w+)\s+0x(\w+)\s+0x\w+\s+0x(\w+)\s+0x(\w+)\s+(.{3})",
                         readelf(tool, ["-l"], sample), re.M):
        segments.append((int(m[1], 16), int(m[2], 16), int(m[3], 16), int(m[4], 16), m[5]))
    min_vaddr = min(s[1] for s in segments) & ~0xFFF

    def file_word(vaddr):
        for offset, start, filesz, _, _ in segments:
            if start <= vaddr < start + filesz:
                return struct.unpack_from("<I", data, offset + vaddr - start)[0]
        return 0  # .bss

    defined = {}
    for m in re.finditer(r"^\s*\d+:\s+(\w+)\s+\d+\s+\w+\s+(\w+)\s+\w+\s+(\w+)\s+(\S+)",
                         readelf(tool, ["--dyn-syms"], sample), re.M):
        if m[3] != "UND" and m[2] in ("GLOBAL", "WEAK"):
            defined[m[4]] = int(m[1], 16)

    relocs = []  # (offset, type, symbol or None)
    for m in re.finditer(r"^([0-9a-f]{8})\s+[0-9a-f]{8}\s+(R_ARM_\w+)(?:[ \t]+[0-9a-f]+[ \t]+(\S+))?",
                         readelf(tool, ["-r"], sample), re.M):
        relocs.append((int(m[1], 16), m[2], m[3]))
    types = {r[1] for r in relocs}
    check(REQUIRED <= types, "libsample.so needs all four handled types: " + ", ".join(sorted(types)))

    image_path = os.path.join(workdir, "libsample.image")
    symbols = [f"{k}={v:x}" for k, v in EXPORTS.items()]
    result = run(host, sample, f"{BASE:x}", image_path, *symbols, *LOOKUPS)
    check(result.returncode == 0,
          "host loader maps and relocates libsample.so: " + (result.stdout or result.stderr or "no output").splitlines()[0])
    if result.returncode != 0:
        return
    out = result.stdout
    image = open(image_path, "rb").read()
    bias = BASE - min_vaddr

    def symbol_value(name):
        return bias + defined[name] if name in defined else EXPORTS[name]

    for offset, rtype, name in relocs:
        original = file_word(offset)
        expected = {
            "R_ARM_RELATIVE": lambda: bias + original,
            "R_ARM_ABS32": lambda: symbol_value(name) + original,
            "R_ARM_GLOB_DAT": lambda: symbol_value(name),
            "R_ARM_JUMP_SLOT": lambda: symbol_value(name),
        }[rtype]() & 0xFFFFFFFF
        actual = struct.unpack_from("<I", image, offset - min_vaddr)[0]
        check(actual == expected, f"{rtype:16} @0x{offset:x} {name or '':14} "
              f"= 0x{actual:08x} (expected 0x{expected:08x})")

    counts = [int(x) for x in re.search(r"^counts (.*)$", out, re.M)[1].split()]
    want = [sum(r[1] == t for r in relocs) for t in
            ("R_ARM_RELATIVE", "R_ARM_ABS32", "R_ARM_GLOB_DAT", "R_ARM_JUMP_SLOT")]
    check(counts == want, f"per-type counts {counts} match readelf {want}")

    lo, hi = (int(x, 16) for x in re.search(r"^exec (\S+) (\S+)$", out, re.M).groups())
    inits = [int(x, 16) for x in re.findall(r"^init (\S+)$", out, re.M)]
    check(len(inits) >= 1 and all(BASE + lo <= a < BASE + hi for a in inits),
          f".init_array entries {[hex(a) for a in inits]} point into relocated text")
    for name in LOOKUPS:
        m = re.search(rf"^lookup {name} (\S+)$", out, re.M)
        check(m and m[1] != "missing" and int(m[1], 16) == bias + defined[name],
              f"lookup {name} = base + st_value")

    partial = [f"{k}={v:x}" for k, v in EXPORTS.items() if k not in ("host_value", "strlen")]
    result = run(host, sample, f"{BASE:x}", image_path, *partial)
    print("  ->", result.stdout.strip())
    check(result.returncode == 2 and "host_value" in result.stdout and "strlen" in result.stdout,
          "missing imports fail the load and every missing symbol is named")

    result = run(host, bad, f"{BASE:x}", image_path, *symbols)
    print("  ->", result.stdout.strip())
    check(result.returncode == 2 and "R_ARM_TLS_DTPMOD32" in result.stdout,
          "libbadreloc.so is rejected with an error naming R_ARM_TLS_DTPMOD32")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    main(*sys.argv[1:])
    print("host check:", "PASSED" if failures == 0 else f"FAILED ({failures})")
    sys.exit(1 if failures else 0)
