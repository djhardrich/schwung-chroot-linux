#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MODULE_ID="pipewire"
# Replace move.local with your device's IP address if mDNS is not available
DEVICE_HOST="${DEVICE_HOST:-move.local}"
REMOTE_MODULE="/data/UserData/move-anything/modules/sound_generators/$MODULE_ID"
REMOTE_CHROOT="/data/UserData/pw-chroot"
DIST_DIR="$REPO_ROOT/dist/$MODULE_ID"
ROOTFS_TAR="$REPO_ROOT/dist/pw-chroot.tar.gz"
ROOTFS_DESKTOP_TAR="$REPO_ROOT/dist/pw-chroot-desktop.tar.gz"

USER_SSH="ableton@$DEVICE_HOST"
ROOT_SSH="root@$DEVICE_HOST"

echo "=== Installing PipeWire Module ==="
echo "Device: $DEVICE_HOST"
echo ""

# ── Install module files (ableton owns /data/UserData) ──
if [ ! -d "$DIST_DIR" ]; then
    echo "Error: $DIST_DIR not found. Run ./scripts/build.sh first."
    exit 1
fi

echo "--- Deploying module to $REMOTE_MODULE ---"
ssh "$USER_SSH" "mkdir -p $REMOTE_MODULE"
scp -r "$DIST_DIR/"* "$USER_SSH:$REMOTE_MODULE/"
ssh "$USER_SSH" "chmod +x $REMOTE_MODULE/start-pw.sh $REMOTE_MODULE/stop-pw.sh"

# ── Install pw-helper (setuid root — requires root) ──
PW_HELPER="$REPO_ROOT/build/pw-helper"
if [ -f "$PW_HELPER" ]; then
    echo ""
    echo "--- Installing pw-helper (setuid root) ---"
    ssh "$ROOT_SSH" "mkdir -p /data/UserData/move-anything/bin"
    scp "$PW_HELPER" "$ROOT_SSH:/data/UserData/move-anything/bin/pw-helper"
    ssh "$ROOT_SSH" "chown root:root /data/UserData/move-anything/bin/pw-helper && chmod 4755 /data/UserData/move-anything/bin/pw-helper"
    echo "pw-helper installed at /data/UserData/move-anything/bin/pw-helper"
fi

# ── Install rootfs (prefer desktop if available, fall back to minimal) ──
# Done before chroot file installs so the directory structure exists
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
    if ssh "$ROOT_SSH" "[ -d $REMOTE_CHROOT/usr ]" 2>/dev/null; then
        echo "Chroot already exists at $REMOTE_CHROOT. Skipping rootfs deploy."
        echo "To force redeploy: ssh $ROOT_SSH 'rm -rf $REMOTE_CHROOT'"
    else
        echo "Uploading rootfs ($(du -h "$CHOSEN_TAR" | cut -f1))..."
        # Root required to preserve file ownership from tarball
        scp "$CHOSEN_TAR" "$ROOT_SSH:/data/pw-chroot.tar.gz"
        ssh "$ROOT_SSH" "
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

# ── Install files into chroot (root-owned paths) ──
JACK_SHIM="$REPO_ROOT/build/jack-physical-shim.so"
if [ -f "$JACK_SHIM" ]; then
    echo ""
    echo "--- Installing jack-physical-shim to chroot ---"
    ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/usr/local/lib"
    scp "$JACK_SHIM" "$ROOT_SSH:$REMOTE_CHROOT/usr/local/lib/jack-physical-shim.so"
    ssh "$ROOT_SSH" "chmod 644 $REMOTE_CHROOT/usr/local/lib/jack-physical-shim.so"
    echo "jack-physical-shim installed at $REMOTE_CHROOT/usr/local/lib/jack-physical-shim.so"
fi

PW_JACK_PHYSICAL="$REPO_ROOT/src/pw-jack-physical"
if [ -f "$PW_JACK_PHYSICAL" ]; then
    ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/usr/local/bin"
    scp "$PW_JACK_PHYSICAL" "$ROOT_SSH:$REMOTE_CHROOT/usr/local/bin/pw-jack-physical"
    ssh "$ROOT_SSH" "chmod +x $REMOTE_CHROOT/usr/local/bin/pw-jack-physical"
fi

MIDI_BRIDGE="$REPO_ROOT/build/midi-bridge"
if [ -f "$MIDI_BRIDGE" ]; then
    echo ""
    echo "--- Installing midi-bridge to chroot ---"
    ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/usr/local/bin"
    scp "$MIDI_BRIDGE" "$ROOT_SSH:$REMOTE_CHROOT/usr/local/bin/midi-bridge"
    ssh "$ROOT_SSH" "chmod +x $REMOTE_CHROOT/usr/local/bin/midi-bridge"
    echo "midi-bridge installed at $REMOTE_CHROOT/usr/local/bin/midi-bridge"
fi

if [ ! -f "$PW_HELPER" ]; then
    echo ""
    echo "NOTE: pw-helper not found. PipeWire must be started manually as root."
    echo "  ssh $ROOT_SSH"
    echo "  sh $REMOTE_MODULE/start-pw.sh /tmp/pw-to-move-<slot> <slot>"
fi

# ── Install convenience scripts (ableton owns /data/UserData) ──
REMOTE_SCRIPTS="/data/UserData"
echo ""
echo "--- Installing convenience scripts ---"
scp "$REPO_ROOT/src/mount-chroot.sh" "$REPO_ROOT/src/start-vnc.sh" \
    "$USER_SSH:$REMOTE_SCRIPTS/"
ssh "$USER_SSH" "chmod +x $REMOTE_SCRIPTS/mount-chroot.sh $REMOTE_SCRIPTS/start-vnc.sh"
echo "Scripts installed to $REMOTE_SCRIPTS/"

# ── Install chroot profile (root-owned path) ──
echo ""
echo "--- Installing chroot profile ---"
ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/etc/profile.d && cat > $REMOTE_CHROOT/etc/profile.d/pipewire.sh << 'PROFEOF'
# Auto-set PipeWire environment for Move bridge
export XDG_RUNTIME_DIR=/tmp/pw-runtime-1
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/pw-runtime-1/dbus-pw
PROFEOF
chmod 644 $REMOTE_CHROOT/etc/profile.d/pipewire.sh"

# ── Disable PipeWire RT scheduling (prevents SIGKILL from kernel RT throttling) ──
echo ""
echo "--- Installing PipeWire no-RT config ---"
ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d && cat > $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d/no-rt.conf << 'RTEOF'
context.properties = {
    module.rt = false
}
RTEOF
chmod 644 $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d/no-rt.conf
mkdir -p $REMOTE_CHROOT/etc/wireplumber/wireplumber.conf.d
cp $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d/no-rt.conf $REMOTE_CHROOT/etc/wireplumber/wireplumber.conf.d/no-rt.conf
mkdir -p $REMOTE_CHROOT/etc/security/limits.d
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
echo "MIDI:"
echo "  JACK MIDI ports 'Move MIDI In' and 'Move MIDI Out' appear in chroot."
echo "  Example: pw-jack fluidsynth --midi-driver=jack --audio-driver=jack -r 48000 /usr/share/sounds/sf2/FluidR3_GM.sf2"
echo ""
echo "Desktop (if installed):"
echo "  ssh root@$DEVICE_HOST"
echo "  sh /data/UserData/start-vnc.sh"
echo "  # Connect VNC client to move.local:5901 (password: everything)"
