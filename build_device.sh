#!/var/jb/bin/bash
# Device-side build for SBTouch/Autiva. Runs ON the phone with the phone's own
# Procursus clang-16 — that is the proven compiler for this device, and the
# reason the toolchain is not a variable here.
#
#   ./build_device.sh dylib   -> /tmp/SpringBoardTouch.dylib.new
#   ./build_device.sh cli     -> ./sbtctl
#
# Constraints baked in (measured 2026-11-11):
#   * no floating-point std::to_chars/from_chars in the phone's libc++;
#   * binaries must run from /var/jb (a /tmp binary is SIGKILLed);
#   * ad-hoc sign with ldid or the image will not load.
set -eu
cd "$(dirname "$0")"

CXX=${CXX:-/var/jb/usr/bin/clang++}
LDID=${LDID:-/var/jb/usr/bin/ldid}
BUILD=${AUTIVA_BUILD:-dev}
DEFS="-DAUTIVA_BUILD=\"$BUILD\""
OBJ=.obj
mkdir -p "$OBJ"
rm -f "$OBJ"/*.o

CORE_FLAGS="-std=c++20 -O2 -fno-exceptions -fno-rtti -arch arm64 -Isrc/core $DEFS"
IOS_FLAGS="$CORE_FLAGS -fobjc-arc"
FRAMEWORKS="-framework Foundation -framework CoreFoundation -framework IOKit \
 -framework CoreGraphics -framework ImageIO -framework Metal -framework CoreImage \
 -framework MobileCoreServices -framework UIKit"

build_objects() {
  for f in src/core/*.cpp; do
    $CXX $CORE_FLAGS -c "$f" -o "$OBJ/$(basename "$f").o"
  done
  for f in src/ios/*.mm; do  # entry log hid capture ipc monitor
    $CXX $IOS_FLAGS -c "$f" -o "$OBJ/$(basename "$f").o"
  done
}

case "${1:-dylib}" in
  dylib)
    build_objects
    OUT=${OUT:-/tmp/SpringBoardTouch.dylib.new}
    # Private SPI (kIOSurface*, CARenderServer*) lives in frameworks that are not
    # in the public SDK; resolve those at load time instead of failing the link.
    $CXX -arch arm64 -dynamiclib -undefined dynamic_lookup -o "$OUT" "$OBJ"/*.o $FRAMEWORKS
    $LDID -S "$OUT"
    echo "== dylib =="
    # `file` is not installed on the device; `ls` + the marker are the evidence.
    ls -l "$OUT"
    ;;
  cli)
    OUT=${OUT:-./sbtctl}
    $CXX $CORE_FLAGS -o "$OUT" src/cli/sbtctl.cpp src/core/json.cpp src/core/protocol.cpp src/core/rng.cpp src/core/profile.cpp \
      -framework CoreFoundation
    $LDID -S "$OUT"
    echo "== cli =="
    # `file` is not installed on the device; `ls` + the marker are the evidence.
    ls -l "$OUT"
    ;;
  *)
    echo "usage: $0 [dylib|cli]" >&2
    exit 2
    ;;
esac
