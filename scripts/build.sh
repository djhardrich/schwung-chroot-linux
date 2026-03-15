#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="move-anything-pipewire-builder"
OUTPUT_BASENAME="${OUTPUT_BASENAME:-pipewire-module}"

# ── If running outside Docker, re-exec inside container ──
if [ ! -f /.dockerenv ]; then
    echo "=== Building Docker image ==="
    docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$REPO_ROOT"

    echo "=== Cleaning previous build ==="
    rm -rf "$REPO_ROOT/build" "$REPO_ROOT/dist"

    echo "=== Running build inside container ==="
    docker run --rm \
        -v "$REPO_ROOT:/build" \
        -u "$(id -u):$(id -g)" \
        -w /build \
        -e OUTPUT_BASENAME="$OUTPUT_BASENAME" \
        "$IMAGE_NAME" ./scripts/build.sh
    exit $?
fi

# ── Inside Docker: cross-compile ──
echo "=== Cross-compiling dsp.so ==="
mkdir -p build/module

"${CROSS_PREFIX}gcc" -O3 -g -shared -fPIC \
    src/dsp/pipewire_plugin.c \
    -o build/module/dsp.so \
    -Isrc/dsp \
    -lpthread -lm

echo "=== Cross-compiling pw-helper ==="
"${CROSS_PREFIX}gcc" -O2 -static \
    src/pw-helper.c \
    -o build/pw-helper

echo "=== Cross-compiling midi-bridge ==="
"${CROSS_PREFIX}gcc" -O2 -Wall \
    src/midi-bridge.c \
    -o build/midi-bridge \
    $(pkg-config --cflags --libs libpipewire-0.3)

echo "=== Cross-compiling jack-physical-shim.so ==="
"${CROSS_PREFIX}gcc" -shared -fPIC -O2 \
    src/jack-physical-shim.c \
    -o build/jack-physical-shim.so \
    -ldl

echo "=== Assembling module package ==="
cp src/module.json  build/module/
cp src/ui.js        build/module/
cp src/start-pw.sh     build/module/
cp src/stop-pw.sh      build/module/
cp src/mount-chroot.sh build/module/
cp src/start-vnc.sh    build/module/
chmod +x build/module/start-pw.sh build/module/stop-pw.sh \
         build/module/mount-chroot.sh build/module/start-vnc.sh

# Include helpers, shims, and midi-bridge in module package
mkdir -p build/module/bin build/module/chroot-lib
cat build/pw-helper              > build/module/bin/pw-helper
cat build/midi-bridge            > build/module/bin/midi-bridge
cat build/jack-physical-shim.so  > build/module/chroot-lib/jack-physical-shim.so
cp src/pw-jack-physical         build/module/chroot-lib/
chmod +x build/module/bin/pw-helper build/module/bin/midi-bridge \
         build/module/chroot-lib/pw-jack-physical

# ── Package ──
rm -rf dist
mkdir -p dist
tar -cf - -C build module | tar -xf - -C dist
mv dist/module dist/pipewire

(cd dist && tar -czvf "${OUTPUT_BASENAME}.tar.gz" pipewire/)

echo ""
echo "=== Build complete ==="
echo "Module: dist/${OUTPUT_BASENAME}.tar.gz"
echo "Files:  dist/pipewire/"
