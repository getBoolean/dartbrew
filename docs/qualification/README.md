# Qualification results

Each dartbrew preview is qualified before it is published. Its results live in
`docs/qualification/<version>/results.json`, next to any verification files the
results name.

## Release results

`results.json` records:

- `version`: the release version, matching `release/preview.json`.
- `hosts`: one entry per host SDK archive, with `sdk_archive` (the file name,
  `dartbrew-<version>-<host>.zip`), `sdk_sha256` and `result` (`pass` or `fail`).
- `console` and `azahar`: what ran on a real console and in Azahar, and how.
- `devkitpro`: package versions in `devkitARM` and `libctru`. Record host-specific differences alongside the host records.
- `features`: per-feature results (required from `0.1.0-preview.5` on).

Other fields (build provenance, notes) are free-form records for people.

## Feature results

`features` is a list. Each feature has a `name`, the units or requirements it
`covers` (free text) and `results` for every required environment:

- `console_aot`: AOT app on a real console.
- `console_jit`: JIT app on a real console.
- `azahar_aot`: AOT app in Azahar.

Each result is `"pass"`, `"fail"`, or
`{"result": "not_applicable", "reason": "..."}`. Both console environments
require `pass` for every feature. Azahar AOT permits `not_applicable` for the
features named `jit-only` and `runtime loader`, with a reason explaining the
emulator limitation. Every other Azahar result must be `pass`.

```json
"features": [
  {
    "name": "files",
    "covers": "U6, R1",
    "results": {"console_aot": "pass", "console_jit": "pass", "azahar_aot": "pass"}
  },
  {
    "name": "runtime loader",
    "covers": "U16",
    "results": {
      "console_aot": "pass",
      "console_jit": "pass",
      "azahar_aot": {"result": "not_applicable", "reason": "Azahar cannot run the runtime .so loader"}
    }
  }
]
```

Preview.4 and earlier have historical records produced before this feature
matrix existed. Each release candidate needs its own measurements.

## Checking the archives

Run `dart run release_tools:check_release` from `packages/release_tools`,
passing `--results` and the three SDK ZIP paths. The guard checks archive
names, SHA-256 digests, passing host records, devkitPro versions and the
environment results for each recorded feature. The [release checklist](../releasing.md)
gives the order of the checks and publication steps.
