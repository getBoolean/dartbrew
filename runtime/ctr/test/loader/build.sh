#!/bin/sh
# U5 spike build. Runs inside the ctr-dart-toolchain container:
#   sh /work/runtime/ctr/test/loader/build.sh [OUT]
# Builds the sample .so files and a self-contained loader-spike.3dsx (the
# .so files are embedded and written to sdmc:/3ds/loader-spike/ on first
# run). OUT defaults to ./build.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/build}
DKP=${DEVKITPRO:-/opt/devkitpro}
G=$DKP/devkitARM/bin/arm-none-eabi-
CTRU=$DKP/libctru
# toolchain/target-ctr.json cflags.
ARCH="-marm -march=armv6k -mtune=mpcore -mfpu=vfp -mfloat-abi=hard -mtp=soft"
mkdir -p "$OUT"

# Shared objects: no libc/libgcc linked in; their imports (strlen,
# __aeabi_idiv, host_*) resolve against the app's export table at load time.
SOFLAGS="$ARCH -O2 -fPIC -shared -nostdlib -Wl,--hash-style=sysv -Wall -Wextra -Werror"
"${G}gcc" $SOFLAGS "$HERE/sample/libsample.c" -o "$OUT/libsample.so"
"${G}gcc" $SOFLAGS "$HERE/sample/libbadreloc.c" -o "$OUT/libbadreloc.so"
"${G}readelf" -W -h -l -d -r --dyn-syms "$OUT/libsample.so" > "$OUT/libsample.readelf.txt"
"${G}readelf" -W -r "$OUT/libbadreloc.so" > "$OUT/libbadreloc.readelf.txt"

# Console app.
cat > "$OUT/embed.s" <<ASM
.section .rodata
.balign 4
.global libsample_so, libsample_so_end, libbadreloc_so, libbadreloc_so_end
libsample_so: .incbin "$OUT/libsample.so"
libsample_so_end:
.balign 4
libbadreloc_so: .incbin "$OUT/libbadreloc.so"
libbadreloc_so_end:
ASM
CFLAGS="$ARCH -O2 -g -std=gnu11 -D__3DS__ -Wall -Wextra -Werror -I$CTRU/include -I$HERE"
"${G}gcc" $CFLAGS -c "$HERE/ctr_main.c" -o "$OUT/ctr_main.o"
"${G}gcc" $CFLAGS -c "$HERE/loader_core.c" -o "$OUT/loader_core.o"
"${G}gcc" $ARCH -c "$OUT/embed.s" -o "$OUT/embed.o"
"${G}gcc" -specs=3dsx.specs $ARCH -g "$OUT/ctr_main.o" "$OUT/loader_core.o" "$OUT/embed.o" \
  -L"$CTRU/lib" -lctru -lm -o "$OUT/loader-spike.elf"
"$DKP/tools/bin/smdhtool" --create "dartbrew loader spike" "U5 runtime loader go/no-go" \
  "dartbrew" "$CTRU/default_icon.png" "$OUT/loader-spike.smdh"
"$DKP/tools/bin/3dsxtool" "$OUT/loader-spike.elf" "$OUT/loader-spike.3dsx" \
  --smdh="$OUT/loader-spike.smdh"
echo "built $OUT/loader-spike.3dsx"
