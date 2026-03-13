#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MODULE_ID="pipewire"
DEVICE_HOST="${DEVICE_HOST:-move.local}"
REMOTE_MODULE="/data/UserData/move-anything/modules/sound_generators/$MODULE_ID"
REMOTE_CHROOT="/data/UserData/pw-chroot"
DIST_DIR="$REPO_ROOT/dist/$MODULE_ID"
ROOTFS_TAR="$REPO_ROOT/dist/pw-chroot.tar.gz"
ROOTFS_DESKTOP_TAR="$REPO_ROOT/dist/pw-chroot-desktop.tar.gz"

echo "=== Installing PipeWire Module ==="
echo "Device: $DEVICE_HOST"
echo ""

# ── Install module files ──
if [ ! -d "$DIST_DIR" ]; then
    echo "Error: $DIST_DIR not found. Run ./scripts/build.sh first."
    exit 1
fi

echo "--- Deploying module to $REMOTE_MODULE ---"
ssh "root@$DEVICE_HOST" "mkdir -p $REMOTE_MODULE"
scp -r "$DIST_DIR/"* "root@$DEVICE_HOST:$REMOTE_MODULE/"
ssh "root@$DEVICE_HOST" "chmod +x $REMOTE_MODULE/start-pw.sh $REMOTE_MODULE/stop-pw.sh && chown -R ableton:users $REMOTE_MODULE"

# ── Install pipewire-midi module ──
MIDI_MODULE_ID="pipewire-midi"
MIDI_DIST_DIR="$REPO_ROOT/dist/$MIDI_MODULE_ID"
REMOTE_MIDI_MODULE="/data/UserData/move-anything/modules/sound_generators/$MIDI_MODULE_ID"

if [ -d "$MIDI_DIST_DIR" ]; then
    echo ""
    echo "--- Deploying pipewire-midi module to $REMOTE_MIDI_MODULE ---"
    ssh "root@$DEVICE_HOST" "mkdir -p $REMOTE_MIDI_MODULE"
    scp -r "$MIDI_DIST_DIR/"* "root@$DEVICE_HOST:$REMOTE_MIDI_MODULE/"
    ssh "root@$DEVICE_HOST" "chmod +x $REMOTE_MIDI_MODULE/start-pw.sh $REMOTE_MIDI_MODULE/stop-pw.sh && chown -R ableton:users $REMOTE_MIDI_MODULE"
fi

# ── Install pw-helper (setuid root helper for chroot management) ──
PW_HELPER="$REPO_ROOT/build/pw-helper"
if [ -f "$PW_HELPER" ]; then
    echo ""
    echo "--- Installing pw-helper (setuid root) ---"
    ssh "root@$DEVICE_HOST" "mkdir -p /data/UserData/move-anything/bin"
    scp "$PW_HELPER" "root@$DEVICE_HOST:/data/UserData/move-anything/bin/pw-helper"
    ssh "root@$DEVICE_HOST" "chown root:root /data/UserData/move-anything/bin/pw-helper && chmod 4755 /data/UserData/move-anything/bin/pw-helper"
    echo "pw-helper installed at /data/UserData/move-anything/bin/pw-helper"
fi

# ── Install pw-helper-midi ──
PW_HELPER_MIDI="$REPO_ROOT/build/pw-helper-midi"
if [ -f "$PW_HELPER_MIDI" ]; then
    echo ""
    echo "--- Installing pw-helper-midi (setuid root) ---"
    scp "$PW_HELPER_MIDI" "root@$DEVICE_HOST:/data/UserData/move-anything/bin/pw-helper-midi"
    ssh "root@$DEVICE_HOST" "chown root:root /data/UserData/move-anything/bin/pw-helper-midi && chmod 4755 /data/UserData/move-anything/bin/pw-helper-midi"
    echo "pw-helper-midi installed at /data/UserData/move-anything/bin/pw-helper-midi"
fi

# ── Install jack-physical-shim to chroot ──
JACK_SHIM="$REPO_ROOT/build/jack-physical-shim.so"
if [ -f "$JACK_SHIM" ]; then
    echo ""
    echo "--- Installing jack-physical-shim to chroot ---"
    ssh "root@$DEVICE_HOST" "mkdir -p $REMOTE_CHROOT/usr/local/lib"
    scp "$JACK_SHIM" "root@$DEVICE_HOST:$REMOTE_CHROOT/usr/local/lib/jack-physical-shim.so"
    ssh "root@$DEVICE_HOST" "chmod 644 $REMOTE_CHROOT/usr/local/lib/jack-physical-shim.so"
    echo "jack-physical-shim installed at $REMOTE_CHROOT/usr/local/lib/jack-physical-shim.so"
fi

# ── Install pw-jack-physical wrapper ──
PW_JACK_PHYSICAL="$REPO_ROOT/src/pw-jack-physical"
if [ -f "$PW_JACK_PHYSICAL" ]; then
    scp "$PW_JACK_PHYSICAL" "root@$DEVICE_HOST:$REMOTE_CHROOT/usr/local/bin/pw-jack-physical"
    ssh "root@$DEVICE_HOST" "chmod +x $REMOTE_CHROOT/usr/local/bin/pw-jack-physical"
fi

# ── Install midi-bridge to chroot ──
MIDI_BRIDGE="$REPO_ROOT/build/midi-bridge"
if [ -f "$MIDI_BRIDGE" ]; then
    echo ""
    echo "--- Installing midi-bridge to chroot ---"
    scp "$MIDI_BRIDGE" "root@$DEVICE_HOST:$REMOTE_CHROOT/usr/local/bin/midi-bridge"
    ssh "root@$DEVICE_HOST" "chmod +x $REMOTE_CHROOT/usr/local/bin/midi-bridge"
    echo "midi-bridge installed at $REMOTE_CHROOT/usr/local/bin/midi-bridge"
fi

if [ ! -f "$PW_HELPER" ]; then
    echo ""
    echo "NOTE: pw-helper not found. PipeWire must be started manually as root."
    echo "  ssh root@$DEVICE_HOST"
    echo "  sh $REMOTE_MODULE/start-pw.sh /tmp/pw-to-move-<slot> <slot>"
fi

# ── Install rootfs (prefer desktop if available, fall back to minimal) ──
CHOSEN_TAR=""
if [ -f "$ROOTFS_DESKTOP_TAR" ]; then
    CHOSEN_TAR="$ROOTFS_DESKTOP_TAR"
    echo ""
    echo "--- Deploying DESKTOP rootfs to $REMOTE_CHROOT ---"
elif [ -f "$ROOTFS_TAR" ]; then
    CHOSEN_TAR="$ROOTFS_TAR"
    echo ""
    echo "--- Deploying rootfs to $REMOTE_CHROOT ---"
fi

if [ -n "$CHOSEN_TAR" ]; then
    if ssh "root@$DEVICE_HOST" "[ -d $REMOTE_CHROOT/usr ]" 2>/dev/null; then
        echo "Chroot already exists at $REMOTE_CHROOT. Skipping rootfs deploy."
        echo "To force redeploy: ssh root@$DEVICE_HOST 'rm -rf $REMOTE_CHROOT'"
    else
        echo "Uploading rootfs ($(du -h "$CHOSEN_TAR" | cut -f1))..."
        scp "$CHOSEN_TAR" "root@$DEVICE_HOST:/data/pw-chroot.tar.gz"
        ssh "root@$DEVICE_HOST" "
            mkdir -p $REMOTE_CHROOT
            cd $REMOTE_CHROOT
            tar -xzf /data/pw-chroot.tar.gz
            rm /data/pw-chroot.tar.gz
        "
        echo "Rootfs deployed."
    fi
else
    echo ""
    echo "NOTE: No rootfs tarball found."
    echo "  Minimal: ./scripts/build-rootfs.sh"
    echo "  Desktop: ./scripts/build-rootfs.sh --desktop"
fi

# ── Install convenience scripts to /data/UserData ──
REMOTE_SCRIPTS="/data/UserData"
echo ""
echo "--- Installing convenience scripts ---"
scp "$REPO_ROOT/src/mount-chroot.sh" "$REPO_ROOT/src/start-vnc.sh" \
    "root@$DEVICE_HOST:$REMOTE_SCRIPTS/"
ssh "root@$DEVICE_HOST" "chmod +x $REMOTE_SCRIPTS/mount-chroot.sh $REMOTE_SCRIPTS/start-vnc.sh"
echo "Scripts installed to $REMOTE_SCRIPTS/"

# ── Install chroot profile (auto-sets XDG_RUNTIME_DIR) ──
echo ""
echo "--- Installing chroot profile ---"
ssh "root@$DEVICE_HOST" "mkdir -p $REMOTE_CHROOT/etc/profile.d && cat > $REMOTE_CHROOT/etc/profile.d/pipewire.sh << 'PROFEOF'
# Auto-set PipeWire environment for Move bridge
export XDG_RUNTIME_DIR=/tmp/pw-runtime-1
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/pw-runtime-1/dbus-pw
PROFEOF
chmod 644 $REMOTE_CHROOT/etc/profile.d/pipewire.sh"

# ── Disable PipeWire RT scheduling (prevents SIGKILL from kernel RT throttling) ──
echo ""
echo "--- Installing PipeWire no-RT config ---"
ssh "root@$DEVICE_HOST" "mkdir -p $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d && cat > $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d/no-rt.conf << 'RTEOF'
context.modules = [
    { name = libpipewire-module-rt
      args = {
          nice.level = 0
          rt.prio = 0
          rt.time.soft = -1
          rt.time.hard = -1
      }
      flags = [ ifexists nofail ]
    }
]
RTEOF
chmod 644 $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d/no-rt.conf
mkdir -p $REMOTE_CHROOT/etc/wireplumber/wireplumber.conf.d
cp $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d/no-rt.conf $REMOTE_CHROOT/etc/wireplumber/wireplumber.conf.d/no-rt.conf
echo '# Disabled - RT scheduling conflicts with Move audio engine' > $REMOTE_CHROOT/etc/security/limits.d/25-pw-rlimits.conf"

echo ""
echo "=== Install Complete ==="
echo "Module: $REMOTE_MODULE"
echo "Chroot: $REMOTE_CHROOT"
echo ""
echo "Load 'PipeWire' as a sound generator in Move Everything."
echo ""
echo "Enter the chroot:"
echo "  ssh root@$DEVICE_HOST"
echo "  chroot $REMOTE_CHROOT bash -l"
echo "  mpg321 -s song.mp3 | aplay -f S16_LE -r 44100 -c 2 -D pipewire"
echo ""
echo "Desktop (if installed):"
echo "  ssh root@$DEVICE_HOST"
echo "  sh /data/UserData/start-vnc.sh"
echo "  # Connect VNC client to move.local:5901 (password: everything)"
echo ""
echo "PipeWire + MIDI:"
echo "  Load 'PipeWire + MIDI' as a sound generator in Move Everything."
echo "  JACK MIDI ports 'Move MIDI In' and 'Move MIDI Out' appear in chroot."
echo "  Example: pw-jack fluidsynth --midi-driver=jack --audio-driver=jack -r 48000 /usr/share/sounds/sf2/FluidR3_GM.sf2"
