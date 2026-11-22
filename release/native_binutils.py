#!/usr/bin/env python3
"""CI-only producer of native GNU ARM as/ld; never required by SDK recipients.

Build on the destination architecture. Linux execution belongs in the repository's
named Compose service. Build/download directories must be fresh and outside any
SDK checkout. The artifact includes the exact source archive and build material.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tarfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
PIN = Path(__file__).with_name("binutils-source.json")
TARGETS = {"linux-x64": ("Linux", "x86_64"),
           "windows-x64": ("Windows", "x86_64"),
           "macos-x64": ("Darwin", "x86_64"),
           "macos-arm64": ("Darwin", "arm64")}
CONFIGURE = ["--target=arm-none-eabi", "--disable-nls", "--disable-werror",
             "--disable-gdb", "--disable-gprofng", "--disable-gprof",
             "--disable-gold", "--disable-libctf", "--disable-sim",
             "--disable-shared", "--enable-static", "--disable-plugins",
             "--without-debuginfod", "--without-zstd", "--without-system-zlib",
             "--enable-deterministic-archives"]


def digest(path, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def verify_source(path, pin):
    for algorithm in ("sha256", "sha512"):
        if digest(path, algorithm) != pin[algorithm]:
            raise ValueError(f"source digest mismatch ({algorithm})")


def extract_source(archive, destination, directory):
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(archive, "r:xz") as stream:
        for member in stream.getmembers():
            parts = Path(member.name).parts
            if not parts or parts[0] != directory or ".." in parts or "\\" in member.name:
                raise ValueError(f"source member escapes root: {member.name}")
            if not (member.isdir() or member.isfile()):
                raise ValueError(f"unsupported source member: {member.name}")
        # The pinned archive contains only regular files and directories. Extract
        # those explicitly; the producer image's Python predates tarfile filters.
        for member in stream.getmembers():
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o777)
                os.utime(target, (member.mtime, member.mtime))
    return destination / directory


def run(arguments, cwd=None, env=None, log=None):
    result = subprocess.run([arg.as_posix() if isinstance(arg, Path) else str(arg) for arg in arguments], cwd=cwd, env=env,
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=False)
    if log is not None:
        log.write_text(result.stdout)
    if result.returncode:
        print(result.stdout[-8000:], flush=True)
        result.check_returncode()
    return result.stdout


def check_dependencies(target, dependencies, glibc_versions=()):
    """Fail closed: the public bin directory contains two executables only."""
    for dependency in dependencies:
        if target == "windows-x64":
            allowed = dependency.lower() in {"kernel32.dll", "msvcrt.dll", "ucrtbase.dll",
                                             "advapi32.dll", "shell32.dll", "user32.dll"}
            allowed = allowed or dependency.lower().startswith("api-ms-win-crt-")
        elif target.startswith("macos-"):
            allowed = dependency.startswith(("/usr/lib/", "/System/Library/"))
        else:
            allowed = dependency in {"libc.so.6", "libm.so.6", "libdl.so.2",
                                     "libpthread.so.0", "ld-linux-x86-64.so.2"}
        if not allowed:
            raise ValueError(f"unbundled host dependency: {dependency}")
    maximum = tuple(map(int, json.loads(PIN.read_text())["linux_glibc_maximum"].split(".")))
    if any(tuple(map(int, version.split("."))) > maximum for version in glibc_versions):
        raise ValueError("GNU/Linux artifact exceeds declared glibc baseline")


def audit_binary(path, target):
    blob = path.read_bytes()
    versions = []
    if target == "windows-x64":
        if blob[:2] != b"MZ":
            raise ValueError("Windows tool is not PE")
        offset = struct.unpack_from("<I", blob, 0x3c)[0]
        if blob[offset:offset + 4] != b"PE\0\0" or struct.unpack_from("<H", blob, offset + 4)[0] != 0x8664:
            raise ValueError("Windows tool is not x64 PE")
        report = run(["objdump", "-p", path])
        dependencies = re.findall(r"DLL Name:\s*(\S+)", report)
        if not dependencies:
            raise ValueError("PE dependency audit returned no import table")
    elif target.startswith("macos-"):
        expected = 0x0100000C if target.endswith("arm64") else 0x01000007
        if blob[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack_from("<I", blob, 4)[0] != expected:
            raise ValueError("macOS tool is not the requested thin native Mach-O")
        report = run(["otool", "-L", path])
        dependencies = [line.strip().split(" (", 1)[0] for line in report.splitlines()[1:] if line.strip()]
        if not dependencies:
            raise ValueError("Mach-O dependency audit returned no load commands")
    else:
        if blob[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", blob, 18)[0] != 62:
            raise ValueError("Linux tool is not x64 ELF")
        report = run(["readelf", "-d", "--version-info", path])
        dependencies = re.findall(r"\(NEEDED\).*?\[(.*?)\]", report)
        versions = sorted(set(re.findall(r"\bGLIBC_([0-9.]+)", report)))
        if not dependencies or not versions:
            raise ValueError("ELF dependency/version audit returned no dynamic runtime")
    check_dependencies(target, dependencies, versions)
    return {"dependencies": dependencies, "glibc_versions": versions, "report": report}


def smoke_test(binary_dir, work, suffix):
    first = work / "entry.s"
    second = work / "helper.s"
    first.write_text(".syntax unified\n.arm\n.arch armv6k\n.fpu vfp\n.text\n.global _start\n_start: bl helper\n bx lr\n")
    second.write_text(".syntax unified\n.arm\n.arch armv6k\n.text\n.global helper\nhelper: mov r0, #7\n bx lr\n")
    assembler = binary_dir / ("ctr-as" + suffix)
    linker = binary_dir / ("ctr-ld" + suffix)
    for source in (first, second):
        run([assembler, "-march=armv6k", "-mfpu=vfp", "-mfloat-abi=hard", "-o", source.with_suffix(".o"), source])
    elf = work / "smoke.elf"
    run([linker, "-m", "armelf", "-Ttext=0x100000", "-e", "_start", "-o", elf,
         first.with_suffix(".o"), second.with_suffix(".o")])
    blob = elf.read_bytes()
    if (blob[:6] != b"\x7fELF\x01\x01" or struct.unpack_from("<H", blob, 18)[0] != 40
            or struct.unpack_from("<I", blob, 24)[0] != 0x100000):
        raise ValueError("assembler/linker smoke did not produce expected ARM ELF")
    return {"armv6k_assemble_and_cross_object_link": "passed", "elf_sha256": digest(elf),
            "scope": "Synthetic ARM ELF only; full CTR SDK/application/device acceptance is separate."}


def build(target, work, output):
    machine = platform.machine().lower()
    if machine == "amd64":
        machine = "x86_64"
    if (platform.system(), machine) != TARGETS[target]:
        raise ValueError("producer must execute on the requested native host architecture")
    work.mkdir(parents=True, exist_ok=False)
    output.mkdir(parents=True, exist_ok=False)
    pin = json.loads(PIN.read_text())
    archive = work / pin["archive"]
    with urllib.request.urlopen(pin["url"], timeout=120) as response, archive.open("wb") as stream:
        shutil.copyfileobj(response, stream)
    verify_source(archive, pin)
    source = extract_source(archive, work / "source", pin["source_directory"])
    build_dir = work / "build"
    build_dir.mkdir()
    env = os.environ.copy()
    # Explicit native compilers prevent a devkitARM PATH entry selecting ARM GCC.
    compiler = "clang" if target.startswith("macos-") else "gcc"
    compiler_path = run(["xcrun", "--find", "clang"]).strip() if compiler == "clang" else shutil.which(compiler)
    cxx_path = run(["xcrun", "--find", "clang++"]).strip() if compiler == "clang" else shutil.which("g++")
    if not compiler_path or not cxx_path:
        raise ValueError(f"missing producer compiler: {compiler}")
    env.update(CC=Path(compiler_path).as_posix(), CXX=Path(cxx_path).as_posix(),
               CFLAGS="-O2", CXXFLAGS="-O2", LDFLAGS="-static" if target == "windows-x64" else "")
    if target.startswith("macos-"):
        env["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
        env["SDKROOT"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        env["CFLAGS"] += ' -isysroot ' + env["SDKROOT"]
        env["CXXFLAGS"] += ' -isysroot ' + env["SDKROOT"]
        env["LDFLAGS"] = '-isysroot ' + env["SDKROOT"]
    configure_script = source / "configure"
    if target == "windows-x64":
        # Autoconf writes srcdir into Makefile targets. A Windows drive colon
        # there is parsed as GNU make syntax; use the MSYS spelling at this edge.
        configure_script = run(["cygpath", "-u", configure_script]).strip()
    command = ["sh", configure_script, *CONFIGURE, "--prefix=/unused-ctr-binutils"]
    logs = work / "logs"
    logs.mkdir()
    run(command, build_dir, env, logs / "configure.log")
    run(["make", "-j2", "all-gas", "all-ld"], build_dir, env, logs / "make.log")
    binary_dir = output / "bin"
    binary_dir.mkdir()
    suffix = ".exe" if target == "windows-x64" else ""
    tools = {}
    for upstream, public in (("gas/as-new", "ctr-as"), ("ld/ld-new", "ctr-ld")):
        destination = binary_dir / (public + suffix)
        shutil.copy2(build_dir / (upstream + suffix), destination)
        destination.chmod(0o755)
        audit = audit_binary(destination, target)
        version = run([destination, "--version"])
        if "GNU" not in version or "2.46" not in version:
            raise ValueError("unexpected producer tool version")
        tools[destination.name] = {"sha256": digest(destination), "version": version, **audit}
    verification = smoke_test(binary_dir, work, suffix)
    notices = output / "licenses"
    notices.mkdir()
    for license_path in source.glob("COPYING*"):
        shutil.copy2(license_path, notices / license_path.name)
    if not (notices / "COPYING3").is_file():
        raise ValueError("upstream GPLv3 license is missing")
    if target == "windows-x64":
        host_notices = Path(compiler_path).resolve().parents[1] / "share/licenses"
        if not host_notices.is_dir():
            raise ValueError("MinGW host runtime license directory is missing")
        shutil.copytree(host_notices, notices / "mingw-host-packages")
    (output / "NOTICE.txt").write_text(
        "GNU Binutils assembler and linker, built from unmodified GNU sources.\n"
        "ctr-as and ctr-ld retain GNU attribution and --version output.\n"
        "GNU Binutils is licensed under GPLv3 or later; see licenses and the complete source archive.\n"
        "Corresponding source and the controlling build scripts accompany these binaries in source/.\n"
        "No affiliation with or endorsement by devkitPro is implied. These are independent GNU builds.\n"
        "" + pin["compatibility"] + "\n")
    source_material = output / "source"
    source_material.mkdir()
    shutil.copy2(archive, source_material / archive.name)
    for relative in ("release/native_binutils.py", "release/binutils-source.json",
                     "release/test/test_native_binutils.py", "compose.yaml",
                     "toolchain/versions.json"):
        destination = source_material / "build-material" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, destination)
    shutil.copytree(logs, source_material / "build-logs")
    # Preserve generated configuration, including the exact native compiler/linker
    # probes. This is build evidence, not a requirement on SDK recipients.
    for log in build_dir.rglob("config.log"):
        destination = source_material / "configuration" / log.relative_to(build_dir)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(log, destination)
    (source_material / "BUILD.txt").write_text(
        "Producer instructions (SDK recipients use the native binaries directly).\n"
        "The complete unmodified GNU source archive is included beside this file.\n"
        "Build material preserves repository paths under build-material/.\n"
        "From build-material/, run on the matching native host, with fresh directories:\n"
        f"python3 release/native_binutils.py --target {target} --work /absolute/fresh-work --output /absolute/fresh-output\n"
        "On Windows use the MSYS2 MinGW64 producer Python and Windows output paths.\n"
        "On Linux run the command with docker compose exec -T toolchain after preparing\n"
        "CTR_IMAGE and CTR_STATE_DIR and starting the named service.\n"
        "No build or package installation is needed to run the resulting executables.\n")
    revision = os.environ.get("GITHUB_SHA")
    if revision is None and (ROOT / ".git").exists():
        revision = run(["git", "-c", "safe.directory=" + str(ROOT), "rev-parse", "HEAD"], ROOT).strip()
    provenance = {"schema_version": 1, "host": target, "target": pin["target"], "source": pin,
                  "producer_revision": revision,
                  "compiler": {"path": compiler_path, "sha256": digest(Path(compiler_path)),
                               "version": run([compiler_path, "--version"]),
                               "details": run([compiler_path, "-v"])},
                  "build_tools": {"make": run(["make", "--version"]),
                                  "shell": {"path": shutil.which("sh"),
                                            "sha256": digest(Path(shutil.which("sh")))}},
                  "configure": [str(arg) for arg in command],
                  "environment": {key: env.get(key) for key in ("CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS", "MACOSX_DEPLOYMENT_TARGET", "SDKROOT")},
                  "host_platform": platform.platform(), "tools": tools,
                  "linux_glibc_maximum": pin["linux_glibc_maximum"] if target == "linux-x64" else None,
                  "macos_minimum": "13.0" if target.startswith("macos-") else None}
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    (output / "verification.json").write_text(json.dumps(verification, indent=2) + "\n")
    hashes = {path.relative_to(output).as_posix(): digest(path)
              for path in sorted(output.rglob("*")) if path.is_file()}
    (output / "SHA256SUMS").write_text("".join(f"{value}  {name}\n" for name, value in hashes.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=TARGETS, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.target, args.work.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
