"""Producer: compile the CLI, assemble a native SDK and run real builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import zipfile

from bundle_native_sdk import assemble, archive_sdk, checked, digest, read
from native_dependencies import audit_sdk

ROOT = Path(__file__).resolve().parents[1]


def verify_codegen(assembly, expected, host, compiler_version):
    actual = hashlib.sha256(assembly).hexdigest()
    if actual == expected:
        return dict(match='exact', sha256=actual, comparable_sha256=actual)
    platforms = {'linux-x64': 'linux', 'windows-x64': 'windows',
                 'macos-x64': 'macos', 'macos-arm64': 'macos'}
    platform_name = platforms.get(host)
    prefix = 'Dart SDK version: '
    suffix = f' on "{platform_name}_arm"'
    if (platform_name is None or not compiler_version.startswith(prefix)
            or not compiler_version.endswith(suffix) or '\n' in compiler_version
            or '\r' in compiler_version):
        raise ValueError('native precompiler version or target architecture differs')
    producer = 'Dart ' + compiler_version[len(prefix):] + '\n'
    canonical = producer[:-len(suffix + '\n')] + ' on "linux_arm"\n'
    banner = ('.string ' + json.dumps(producer) + '\n').encode()
    reference_banner = ('.string ' + json.dumps(canonical) + '\n').encode()
    marker = b'.section .debug_info,""\n'
    if assembly.count(marker) != 1:
        raise ValueError('expected one DWARF compilation unit')
    before, debug = assembly.split(marker)
    if debug.count(banner) != 1:
        raise ValueError('DWARF producer does not match the native compiler version')
    comparable = before + marker + debug.replace(banner, reference_banner, 1)
    comparable_sha = hashlib.sha256(comparable).hexdigest()
    if comparable_sha != expected:
        raise ValueError('native precompiler differs beyond the DWARF producer host name; retained cross-host-probe.S')
    return dict(match='dwarf-producer-host-only', sha256=actual,
                comparable_sha256=comparable_sha, producer_host=platform_name,
                reference_producer_host='linux')


def build(precompiler, binutils, runtime, output, clang=None, headers=None):
    precompiler, binutils, runtime, output = map(Path, (precompiler, binutils, runtime, output))
    if output.exists():
        raise ValueError('producer output already exists')
    host = read(precompiler / 'native-precompiler.json')
    suffix = '.exe' if os.name == 'nt' else ''
    os_name = {'Windows': 'windows', 'Darwin': 'macos', 'Linux': 'linux'}[platform.system()]
    cpu = {'AMD64': 'x64', 'x86_64': 'x64', 'arm64': 'arm64', 'aarch64': 'arm64'}[platform.machine()]
    if host['host'] != f'{os_name}-{cpu}':
        raise ValueError('producer host differs from native components')
    for line in (binutils / 'SHA256SUMS').read_text().splitlines():
        sha, name = line.split('  ', 1)
        checked(binutils, name, sha)
    dart = precompiler / 'host-dart/bin' / ('dart' + suffix)
    version = read(ROOT / 'release/preview.json')['version']
    output.mkdir(parents=True)
    probe = read(runtime / 'probe.json')
    probe_kernel = checked(runtime, probe['kernel'], probe['kernel_sha256'])
    probe_assembly = output / 'cross-host-probe.S'
    subprocess.run([str(precompiler / host['executable']['path']),
                    '--snapshot_kind=app-aot-assembly', '--assembly=' + str(probe_assembly),
                    str(probe_kernel)], check=True)
    version_probe = subprocess.run([str(precompiler / host['executable']['path']), '--version'],
                                   text=True, capture_output=True, check=True)
    codegen = verify_codegen(probe_assembly.read_bytes(), probe['assembly_sha256'], host['host'],
                             (version_probe.stdout + version_probe.stderr).strip())
    cli = output / ('dartbrew' + suffix)
    package = ROOT / 'packages/dartbrew'
    for arguments in [
        ['pub', 'get', '--enforce-lockfile'], ['analyze'], ['test', '-r', 'expanded'],
        ['compile', 'exe', '-DDARTBREW_VERSION=' + version, 'bin/dartbrew.dart', '-o', str(cli)],
    ]:
        subprocess.run([str(dart), *arguments], cwd=package, check=True)
    sdk = output / f'dartbrew-{version}-{host["host"]}'
    manifest = assemble(cli, precompiler, binutils, runtime, sdk, version, clang=clang, headers=headers)
    dependencies = audit_sdk(sdk, host['host'], manifest['tools'])
    archive = output / (sdk.name + '.zip')
    archive_sdk(sdk, archive)
    extracted = output / 'extracted download'
    with zipfile.ZipFile(archive) as package:
        package.extractall(extracted)
        if os.name != 'nt':
            for member in package.infolist():
                path = extracted / member.filename
                mode = (member.external_attr >> 16) & 0o777
                if not mode:
                    raise ValueError('SDK archive lost Unix file permissions')
                path.chmod(mode)
    installed = extracted / sdk.name
    env = dict(os.environ, PATH='')
    for arguments in [['--help'], ['--version'], ['doctor']]:
        subprocess.run([str(installed / cli.name), *arguments], env=env, check=True)
    compiler_check = None
    if 'native_compiler' in manifest:
        from native_clang import check_sdk_compiler
        compiler_check = check_sdk_compiler(installed, output / 'compiler-check')
    verification_env = dict(env, DARTBREW_NATIVE_SDK=str(installed))
    verification_work = output / 'verification-work'
    verification_work.mkdir()
    verification_env['CTR_NATIVE_VERIFY_DIR'] = str(verification_work)
    subprocess.run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s',
                    str(ROOT / 'release/test'), '-p', 'test_native_sdk_integration.py', '-v'],
                   cwd=ROOT, env=verification_env, check=True)
    candidates = output / 'execution-candidates.zip'
    with zipfile.ZipFile(candidates, 'x', compression=zipfile.ZIP_DEFLATED) as candidate_zip:
        for mode in ('aot', 'jit'):
            matches = [path for path in verification_work.glob('*/' + mode)
                       if (path / 'application.3dsx').is_file()]
            if len(matches) != 1:
                raise ValueError(f'expected one retained {mode} execution candidate')
            candidate = matches[0]
            for name in ('application.3dsx', 'artifact.json', 'run.json'):
                candidate_zip.write(candidate / name, mode + '/' + name)
            candidate_zip.write(candidate.parent / 'main.dart', mode + '/main.dart')
            for path in sorted((candidate / 'SDROOT').rglob('*')):
                if path.is_file():
                    candidate_zip.write(path, mode + '/' + path.relative_to(candidate).as_posix())
    receipt = dict(host=host['host'], sdk_archive=archive.name, sha256=digest(archive),
                   sdk_manifest_sha256=digest(sdk / 'sdk.json'),
                   files=len(manifest['files']), native_build_checks='extracted archive passed with PATH empty',
                   cross_host_generated_assembly=('byte-for-byte match with qualified Linux reference'
                       if codegen['match'] == 'exact' else
                       'byte-for-byte match except verified DW_AT_producer host name'),
                   code_generation=codegen,
                   dependency_audit=dependencies,
                   execution_candidates=dict(archive=candidates.name, sha256=digest(candidates)),
                   native_compiler_check=compiler_check,
                   scope='Real host-native build/package checks; target execution remains separate')
    (output / 'verification.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('precompiler', 'binutils', 'runtime', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--clang', type=Path, help='optional clang component (needs --headers)')
    parser.add_argument('--headers', type=Path, help='optional CTR target-header component')
    args = parser.parse_args()
    receipt = build(args.precompiler.resolve(), args.binutils.resolve(), args.runtime.resolve(), args.output.resolve(),
                    clang=args.clang and args.clang.resolve(), headers=args.headers and args.headers.resolve())
    print(json.dumps({key: value for key, value in receipt.items() if key != 'dependency_audit'}))
