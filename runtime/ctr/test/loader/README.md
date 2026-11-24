# U5 runtime loader spike

Go/no-go prototype for loading an ELF shared object on the console at runtime (plan U5, KTD9, R14). This is spike code: U16 rewrites it as the production loader, or replaces it with link-time resolution if the result is no-go.

## Files

| File | Role |
| --- | --- |
| `loader_core.c`, `loader_core.h` | Portable loader core. Parses ELF32, maps `PT_LOAD` segments, reads `PT_DYNAMIC`, applies `R_ARM_RELATIVE`, `R_ARM_ABS32`, `R_ARM_GLOB_DAT` and `R_ARM_JUMP_SLOT`, and looks up exports. It rejects any other relocation type with an error naming it. |
| `ctr_main.c` | The `.3dsx` app. It embeds both sample objects and writes them to `sdmc:/3ds/loader-spike/`, then loads them back from the SD card. It resolves imports against a hand-written export table, flushes caches and makes text executable through patch 0009's path (Luma SVC 0x80, then `svcControlProcessMemory` `MEMOP_PROT`), runs `.init_array`, and calls into the object. |
| `sample/libsample.c` | Sample object. Each export exercises one relocation or import path. |
| `sample/libbadreloc.c` | Negative sample. Its TLS variable needs `R_ARM_TLS_DTPMOD32`. |
| `build.sh` | Builds everything. |

## Build

Run inside the toolchain container:

```sh
docker exec ctr-dart-toolchain sh /work/runtime/ctr/test/loader/build.sh
```

Use `MSYS_NO_PATHCONV=1` when running this from Git Bash. Output goes to `runtime/ctr/test/loader/build/` by default (git-ignored), or to the directory given as the first argument.

Shared-object flags are the CTR cflags plus `-O2 -fPIC -shared -nostdlib -Wl,--hash-style=sysv`. devkitARM's `ld` produces `ET_DYN` hard-float EABI objects with these flags. Text and data land on separate 0x1000 pages. libc and libgcc are not linked into the object, so `strlen` and `__aeabi_idiv` become imports that the app resolves.

## Run on the console

The console needs Luma3DS, which provides the custom SVCs. Upload `build/loader-spike.3dsx` with the netloader (`3dslink build/loader-spike.3dsx`), or copy it to `sdmc:/3ds/`. No other files are needed.

The app prints to the top screen and writes `sdmc:/3ds/loader-spike/loader-spike.log`. The log is closed after every line, so a crash still leaves the last step reached ("about to call ..."). The app exits on START or after 30 seconds.

Go means the log ends with `VERDICT: GO`: `add(2, 3)` returned 5 through a function pointer, and the object called the app's `host_log`.
