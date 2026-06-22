#!/bin/bash
# =============================================================================
# AuroraOS — build orchestrator
# =============================================================================
# This is the ONE command that builds the ISO. Run it from anywhere:
#
#     ./build.sh
#
# What it does:
#   1. Syncs the auroraos/ source tree from the Windows folder into Ubuntu's
#      NATIVE filesystem (/home/user/auroraos-build) — building on /mnt/c is
#      slow and breaks on symlinks/device nodes, so we never do it.
#   2. Runs `lb config` to generate the live-build config tree.
#   3. Runs `lb build` to produce the ISO (downloads ~2-3GB of debs first run).
#   4. Copies the finished ISO back to the Windows folder.
#
# Usage:
#   ./build.sh           # full build
#   ./build.sh clean     # wipe the build dir and start over
#   ./build.sh config    # only run the config step (no build)
# =============================================================================

set -e

# --- Paths ---
# Resolve the directory THIS script lives in (works when invoked via WSL path).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/auroraos"
BUILD_DIR="/home/user/auroraos-build"
OUTPUT_DIR="$SCRIPT_DIR/build-output"
VERSION="0.55"                                  # keep in sync with 10-branding.hook
OUT_ISO="auroraos-${VERSION}-amd64.iso"         # canonical name used by site/Worker

# Reproducible-ish builds: derive a stable timestamp from the source tree so
# repeated builds of the same sources are closer to bit-identical.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(find "$SRC_DIR" -type f -printf '%T@\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d. -f1)"
    export SOURCE_DATE_EPOCH
fi

# Refuse to run a privileged recursive delete on an empty/suspicious path.
safe_rmrf() {
    case "$1" in
        ""|"/"|"/home"|"/home/"|"/root"|"$HOME") echo "refusing rm -rf '$1'"; exit 1 ;;
    esac
    sudo rm -rf "$1"
}

# --- Inside WSL? ---
if ! grep -qi microsoft /proc/version 2>/dev/null; then
    echo "ERROR: build.sh must run inside WSL/Ubuntu (it targets /home/user)."
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# --- Subcommands ---
case "${1:-build}" in
    clean)
        echo "[aurora-build] Cleaning $BUILD_DIR ..."
        # build tree contains root-owned cache (lb build runs as root) -> use sudo.
        safe_rmrf "$BUILD_DIR"
        rm -rf "${OUTPUT_DIR:?}"/*
        echo "[aurora-build] Done. Run ./build.sh to start fresh."
        exit 0
        ;;
    config)
        ONLY_CONFIG=1
        ;;
    build|"")
        ONLY_CONFIG=0
        ;;
    *)
        echo "Usage: $0 [clean|config|build]"
        exit 1
        ;;
esac

# --- 1. Sync source tree into native filesystem (preserving package cache) ---
echo "[aurora-build] Step 1/4: Syncing source to $BUILD_DIR ..."

# live-build caches DOWNLOADED PACKAGES in build_dir/cache/. Re-downloading ~3GB
# on every rebuild is wasteful, so we preserve that cache across syncs.
#
# NOTE: we deliberately do NOT preserve chroot/ or .build/ — those reflect the
# assembled system and must be rebuilt when package lists or hooks change. The
# package CACHE (the .deb files) is what saves the re-download; the chroot
# rebuild from cache is fast (~10-15 min) and ensures correctness.
#
# The build tree contains root-owned files (lb build runs as root), so we use
# sudo for any deletion. Backup cache -> wipe -> restore cache -> sync source.

if [ -d "$BUILD_DIR/cache" ]; then
    echo "[aurora-build]   preserving package cache for fast rebuild..."
    # Move (rename) the cache aside rather than cp -a it: a rename is atomic,
    # instant, and — crucially — can't be corrupted by a buggy `cp` (modern
    # Ubuntu's default uutils `cp -a` mangled the bootstrap cache, which then
    # restored an empty chroot). Clear any stale backup from a prior aborted run.
    [ -e "$BUILD_DIR.cache.bak" ] && safe_rmrf "$BUILD_DIR.cache.bak"
    if sudo mv "$BUILD_DIR/cache" "$BUILD_DIR.cache.bak"; then
        safe_rmrf "$BUILD_DIR"
        mkdir -p "$BUILD_DIR"
        sudo mv "$BUILD_DIR.cache.bak" "$BUILD_DIR/cache"
        sudo chown -R root:root "$BUILD_DIR/cache" 2>/dev/null || true
    else
        echo "[aurora-build]   WARNING: could not preserve cache; keeping existing tree."
    fi
else
    [ -d "$BUILD_DIR" ] && safe_rmrf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
fi

cp -a "$SRC_DIR"/. "$BUILD_DIR"/
cd "$BUILD_DIR"

# Make scripts & hooks executable (cp from /mnt/c can lose the +x bit).
chmod +x auto/config 2>/dev/null || true
find config/hooks -name '*.hook.*' -exec chmod +x {} \; 2>/dev/null || true
find config/includes.chroot/usr/local -type f -exec chmod +x {} \; 2>/dev/null || true

# --- 2. Run lb config ---
echo "[aurora-build] Step 2/4: Running lb config ..."
# lb config runs as the normal user (writes config files only).
lb config || { echo "[aurora-build] ERROR: lb config failed."; exit 1; }
echo "[aurora-build] Config generated."

if [ "$ONLY_CONFIG" = "1" ]; then
    echo "[aurora-build] --config only; stopping before build."
    exit 0
fi

# --- 2b. GNU coreutils shim (modern Ubuntu/WSL defaults to uutils) ---
# Ubuntu 25.10+/26.04 ship Rust "uutils" coreutils as the default, whose `chroot`
# is incompatible with live-build (it fails with: chroot: failed to run command
# '/usr/bin/env'). If we detect uutils AND GNU coreutils is installed (the
# gnu-coreutils package, which provides gnu-prefixed binaries like /usr/bin/
# gnuchroot), build a symlink farm of un-prefixed GNU tools and put it first on
# PATH for the privileged build so live-build uses GNU chroot/cp/etc.
GNU_BIN=""
if chroot --version 2>/dev/null | grep -qi uutils && [ -x /usr/sbin/gnuchroot ]; then
    GNU_BIN="/tmp/aurora-gnu-coreutils"
    rm -rf "$GNU_BIN"; mkdir -p "$GNU_BIN"
    # GNU coreutils ship gnu-prefixed in BOTH /usr/bin (env, cp, …) and
    # /usr/sbin (chroot). Symlink the un-prefixed names into the farm.
    for g in /usr/bin/gnu* /usr/sbin/gnu*; do
        [ -e "$g" ] || continue
        name="$(basename "$g")"; name="${name#gnu}"
        [ -n "$name" ] && ln -sf "$g" "$GNU_BIN/$name"
    done
    echo "[aurora-build] Detected uutils coreutils; using GNU coreutils for the build."
    echo "[aurora-build]   ($(ls "$GNU_BIN" | wc -l) tools shimmed, incl. chroot=$(readlink -f "$GNU_BIN/chroot"))"
fi

# --- 3. Run lb build (this is the long step) ---
# lb build MUST run as root: it uses debootstrap, mount, chroot. Pass PATH and
# HOME through sudo explicitly (sudo's secure_path ignores -E), so live-build
# keeps the user's apt cache and (if needed) the GNU coreutils shim.
echo "[aurora-build] Step 3/4: Building ISO (first run downloads ~2-3GB) ..."
echo "[aurora-build] This can take 30-90 minutes depending on bandwidth/CPU."
if [ -n "$GNU_BIN" ]; then
    sudo env "PATH=$GNU_BIN:$PATH" "HOME=$HOME" lb build || RC=$?
else
    sudo env "HOME=$HOME" lb build || RC=$?
fi
RC=${RC:-0}
if [ "$RC" -ne 0 ]; then
    echo "[aurora-build] ERROR: lb build failed with exit code $RC."
    echo "[aurora-build] See build-output/build.log for details."
    exit "$RC"
fi

# --- 4. Copy the ISO out to the Windows folder under its canonical name ---
ISO=$(ls -1 *.iso 2>/dev/null | head -1)
if [ -z "$ISO" ]; then
    echo "[aurora-build] ERROR: no ISO produced. Check build logs in $BUILD_DIR."
    exit 1
fi

echo "[aurora-build] Step 4/4: Copying $ISO to $OUTPUT_DIR/$OUT_ISO ..."
cp -v "$ISO" "$OUTPUT_DIR/$OUT_ISO"
# Produce a checksum that names the canonical file (so it matches what the
# website/Worker publish and what users verify against).
( cd "$OUTPUT_DIR" && sha256sum "$OUT_ISO" > "$OUT_ISO.sha256" )

echo
echo "================================================================"
echo " BUILD COMPLETE"
echo "================================================================"
echo " ISO:     $OUTPUT_DIR/$OUT_ISO"
echo " Size:    $(du -h "$OUTPUT_DIR/$OUT_ISO" | cut -f1)"
echo " SHA256:  $OUTPUT_DIR/$OUT_ISO.sha256"
echo "================================================================"
echo " Next:    flash to USB with Rufus or balenaEtcher (see README),"
echo "          or publish an update channel with ./release.sh publish"
