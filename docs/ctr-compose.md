# Local CTR builds with Compose

Container builds use the repository's `compose.yaml`. Its toolchain service has
the explicit name `ctr-dart-toolchain`. The repository and build state
are host-folder bind mounts. SDK sources, dependency downloads and build output
belong under `/state`, so they persist outside the container's writable layer.

From the repository root in PowerShell:

```powershell
$env:CTR_IMAGE = (Get-Content toolchain/versions.json -Raw | ConvertFrom-Json).container.image
$env:CTR_STATE_DIR = '<state-dir>'
New-Item -ItemType Directory -Force -Path $env:CTR_STATE_DIR,
    (Join-Path $env:CTR_STATE_DIR 'cache'),
    (Join-Path $env:CTR_STATE_DIR 'tmp') | Out-Null
docker compose config
docker compose up -d toolchain
```

Replace `<state-dir>` with an existing host folder that has enough space, such
as a folder inside a WSL distribution
(`\\wsl.localhost\<distro>\home\<user>\ctr-compose-state`).
It remains a host-folder bind mount, not a Docker-managed volume. Pass Windows
UNC paths through the environment variable so Compose preserves their meaning.
Linux hosts can set `CTR_IMAGE` to the same manifest pin,
set `CTR_STATE_DIR` to an existing absolute folder, and use the same Compose
commands. Create its `cache` and `tmp` subfolders before starting the service.

The state filesystem must distinguish filenames that differ only by case.
CIPD's pinned Google Cloud SDK includes such terminfo names as `2621A` and
`2621a`; a case-insensitive Windows bind directory can make extraction fail
with a missing-file error. Enable case sensitivity before populating a new
NTFS state directory, or use a case-sensitive Linux host folder. Existing
state folders need inspection and migration; changing a parent flag does not
retroactively repair existing children. Preserve failed state for diagnosis
and retain dependency signature/hash checks and version pins when retrying.

For a new, empty NTFS state directory, enable case sensitivity before creating
children: `fsutil.exe file setCaseSensitiveInfo <directory> enable`. Prefer a
Linux filesystem for SDK builds: on one Windows workstation a 250-file write/read
probe took 3.33 seconds on the Windows bind and 0.014 seconds on the Linux host
bind. This is a small filesystem measurement, not a general build speed ratio.

Use `docker compose exec -T toolchain` for commands in the existing named
container. Run one Ninja process per output directory. Read the output paths
and compatibility records printed by configuration before starting builds.

The [release checklist](releasing.md) gives the bootstrap, native build and
verification commands to run in this service.

Remove this project's container and network with `docker compose down`.
Its host state folder is retained. Inspect or archive that folder before
deleting it separately. Legacy containers from earlier experiments require
cleanup by their recorded names; they are not owned by this Compose project.
