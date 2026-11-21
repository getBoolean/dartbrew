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
- `features`: per-feature results (required from `0.1.0-preview.5` on).

Other fields (build provenance, notes) are free-form records for people.

## Feature results

`features` is a list. Each feature has a `name`, the units or requirements it
`covers` (free text) and `results` for every required environment:

- `console_aot`: AOT app on a real console.
- `console_jit`: JIT app on a real console.
- `azahar_aot`: AOT app in Azahar.

Each result is `"pass"`, `"fail"`, or
`{"result": "not_applicable", "reason": "..."}`. Use `not_applicable` only where
the environment cannot provide the feature, and say why. Azahar cannot run the
JIT VM or the runtime `.so` loader. Everything else must be `pass`.

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

`0.1.0-preview.4` and earlier were published before feature results existed;
their files have no `features` section and the guard does not ask for one.

## The publish guard

Run before any `gh release upload`:

```console
python release/check_release.py --results docs/qualification/<version>/results.json out/*/dartbrew-*.zip
```

It refuses the release when an archive has no passing host record for the
version or its SHA-256 differs, when `features` is missing or empty, or when a
feature has a required environment that is not `pass` (or `not_applicable` with
a reason). The error names the archive, or the feature and environment.

Its tests: `python -B -m unittest discover -s release/test -p test_check_release.py -v`.
