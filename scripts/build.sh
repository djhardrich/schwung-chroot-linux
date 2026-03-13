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

    echo "=== Running build inside container ==="
    docker run --rm \
        -v "$REPO_ROOT:/build" \
        -u "$(id -u):$(id -g)" \
        -w /build \
        -e OUTPUT_BASENAME="$OUTPUT_BASENAME" \
        "$IMAGE_NAME" ./scripts/build.sh
    exit $?
fi

# ── Inside Docker: cross-compile DSP plugin ──
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

echo "=== Cross-compiling pipewire-midi dsp.so ==="
mkdir -p build/pipewire-midi-module
"${CROSS_PREFIX}gcc" -O3 -g -shared -fPIC \
    src/dsp/pipewire_midi_plugin.c \
    -o build/pipewire-midi-module/dsp.so \
    -Isrc/dsp \
    -lpthread -lm

echo "=== Cross-compiling pw-helper-midi ==="
"${CROSS_PREFIX}gcc" -O2 -static \
    src/pw-helper-midi.c \
    -o build/pw-helper-midi

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

# Include helpers and shims in module package
mkdir -p build/module/bin build/module/chroot-lib
cp build/pw-helper              build/module/bin/
cp build/jack-physical-shim.so  build/module/chroot-lib/
cp src/pw-jack-physical         build/module/chroot-lib/
chmod +x build/module/chroot-lib/pw-jack-physical

echo "=== Assembling pipewire-midi module package ==="
cp src/pipewire-midi/module.json  build/pipewire-midi-module/
cp src/pipewire-midi/ui.js        build/pipewire-midi-module/
cp src/start-pw-midi.sh           build/pipewire-midi-module/start-pw.sh
cp src/stop-pw-midi.sh            build/pipewire-midi-module/stop-pw.sh
cp src/mount-chroot.sh            build/pipewire-midi-module/
cp src/start-vnc.sh               build/pipewire-midi-module/
chmod +x build/pipewire-midi-module/start-pw.sh build/pipewire-midi-module/stop-pw.sh \
         build/pipewire-midi-module/mount-chroot.sh build/pipewire-midi-module/start-vnc.sh

# Include helpers, shims, and midi-bridge in midi module package
mkdir -p build/pipewire-midi-module/bin build/pipewire-midi-module/chroot-lib
cp build/pw-helper-midi            build/pipewire-midi-module/bin/
cp build/midi-bridge               build/pipewire-midi-module/bin/
cp build/jack-physical-shim.so     build/pipewire-midi-module/chroot-lib/
cp src/pw-jack-physical            build/pipewire-midi-module/chroot-lib/
chmod +x build/pipewire-midi-module/chroot-lib/pw-jack-physical

# ── Package ──
mkdir -p dist
rm -rf dist/pipewire
cp -r build/module dist/pipewire

(cd dist && tar -czvf "${OUTPUT_BASENAME}.tar.gz" pipewire/)

rm -rf dist/pipewire-midi
cp -r build/pipewire-midi-module dist/pipewire-midi

(cd dist && tar -czvf "pipewire-midi-module.tar.gz" pipewire-midi/)

echo ""
echo "=== Build complete ==="
echo "Module: dist/${OUTPUT_BASENAME}.tar.gz"
echo "Files:  dist/pipewire/"
echo "Module: dist/pipewire-midi-module.tar.gz"
echo "MIDI bridge: build/midi-bridge"
