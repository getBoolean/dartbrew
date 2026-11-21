#!/bin/sh
# U4 spike build. Runs inside the ctr-dart-toolchain container:
#   sh /work/runtime/ctr/test/scheduling/build.sh [OUT]
# Builds a self-contained sched-spike.3dsx. OUT defaults to ./build.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/build}
DKP=${DEVKITPRO:-/opt/devkitpro}
G=$DKP/devkitARM/bin/arm-none-eabi-
CTRU=$DKP/libctru
# toolchain/target-ctr.json cflags.
ARCH="-marm -march=armv6k -mtune=mpcore -mfpu=vfp -mfloat-abi=hard -mtp=soft"
mkdir -p "$OUT"
CFLAGS="$ARCH -O2 -g -std=gnu11 -D__3DS__ -Wall -Wextra -Werror -I$CTRU/include"
"${G}gcc" $CFLAGS -c "$HERE/ctr_main.c" -o "$OUT/ctr_main.o"
"${G}gcc" -specs=3dsx.specs $ARCH -g "$OUT/ctr_main.o" -L"$CTRU/lib" -lctru -lm \
  -o "$OUT/sched-spike.elf"
"$DKP/tools/bin/smdhtool" --create "dartbrew sched spike" "U4 scheduling and memory" \
  "dartbrew" "$CTRU/default_icon.png" "$OUT/sched-spike.smdh"
"$DKP/tools/bin/3dsxtool" "$OUT/sched-spike.elf" "$OUT/sched-spike.3dsx" \
  --smdh="$OUT/sched-spike.smdh"
echo "built $OUT/sched-spike.3dsx"
