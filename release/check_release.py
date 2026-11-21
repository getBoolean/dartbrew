"""Refuse to publish SDK archives that were not qualified for this version.

Run before uploading to a GitHub release:

    python release/check_release.py --results <evidence>/results.json <archives...>

Every archive must be named dartbrew-<version>-<host>.zip for the version in
release/preview.json, and its SHA-256 must match a passing host entry in the
committed qualification results for that same version.

From 0.1.0-preview.5 on, results.json must also list features. Each feature
must pass on console_aot, console_jit and azahar_aot, or be not_applicable
there with a reason. See docs/qualification/README.md.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENTS = ('console_aot', 'console_jit', 'azahar_aot')
# Published before per-feature results existed; their results.json has no features.
WITHOUT_FEATURES = {f'0.1.0-preview.{n}' for n in range(1, 5)}


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def check_release(results_path, archives, version=None):
    if version is None:
        version = json.loads((ROOT / 'release/preview.json').read_text(encoding='utf-8'))['version']
    results = json.loads(Path(results_path).read_text(encoding='utf-8'))
    if results.get('version') != version:
        raise ValueError(f'qualification results are for {results.get("version")}, not {version}')
    qualified = {entry['sdk_archive']: entry for entry in results.get('hosts', [])}
    if not archives:
        raise ValueError('no archives given')
    for archive in map(Path, archives):
        entry = qualified.get(archive.name)
        if not archive.name.startswith(f'dartbrew-{version}-') or entry is None:
            raise ValueError(f'{archive.name} has no qualification record for {version}')
        if entry.get('result') != 'pass':
            raise ValueError(f'{archive.name} did not pass qualification')
        if digest(archive) != entry.get('sdk_sha256'):
            raise ValueError(f'{archive.name} differs from the qualified bytes')
    if version not in WITHOUT_FEATURES:
        check_features(results.get('features'), version)
    return [Path(archive).name for archive in archives]


def check_features(features, version):
    if not features:
        raise ValueError(f'qualification results for {version} have no features')
    for feature in features:
        name = feature.get('name')
        for environment in ENVIRONMENTS:
            outcome = feature.get('results', {}).get(environment)
            if outcome == 'pass':
                continue
            if (isinstance(outcome, dict) and outcome.get('result') == 'not_applicable'
                    and str(outcome.get('reason', '')).strip()):
                continue
            raise ValueError(f'feature {name} did not pass on {environment}: {json.dumps(outcome)}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('archives', nargs='+', type=Path)
    args = parser.parse_args()
    try:
        names = check_release(args.results, args.archives)
    except ValueError as error:
        print(f'refusing to publish: {error}', file=sys.stderr)
        sys.exit(1)
    print('qualified: ' + ', '.join(names))
