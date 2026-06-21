#!/bin/sh
# =============================================================================
# AuroraOS — mount the encrypted Persistent volume (passphrase-based LUKS2)
# =============================================================================
# Called by boot-mode.sh during a Persistent boot. Opens the AuroraPersistent
# LUKS2 partition using a PASSPHRASE typed by the user, then bind-mounts the
# persistent subdirectories over the live system.
#
# The partition is identified by its GPT name (PARTLABEL), NOT a filesystem
# label: the partition is LUKS-encrypted, so it exposes no ext4 label until it
# is opened. Looking it up by filesystem label (the old behaviour) always failed
# and silently fell back to amnesic.
#
# If the wrong passphrase is given or the volume doesn't exist, we fall back to
# amnesic mode for this session (better than a non-booting system).
# =============================================================================

set -u

LUKS_NAME="aurora_persistent"
MAPPED="/dev/mapper/$LUKS_NAME"
MOUNTPOINT="/mnt/persistent"
PARTLABEL="AuroraPersistent"
MAX_TRIES=3

# Locate the persistent partition by its GPT partition name.
PART=$(blkid -t PARTLABEL="$PARTLABEL" -o device 2>/dev/null | head -1)
if [ -z "$PART" ]; then
    PART=$(lsblk -prno NAME,PARTLABEL 2>/dev/null | awk -v l="$PARTLABEL" '$2==l{print $1; exit}')
fi
if [ -z "$PART" ]; then
    echo "[aurora] No partition named $PARTLABEL found (persistence not set up)."
    exit 1
fi

# Confirm it really is a LUKS container before prompting.
if ! cryptsetup isLuks "$PART" 2>/dev/null; then
    echo "[aurora] $PART exists but is not a LUKS volume; skipping persistence."
    exit 1
fi

# Open with the user's passphrase (prompt up to MAX_TRIES times). cryptsetup
# exit code 2 == bad passphrase; other codes are real errors, so we don't burn
# a retry on them.
if [ ! -e "$MAPPED" ]; then
    echo "[aurora] Persistent volume found. Enter your passphrase to unlock it."
    i=0
    while [ "$i" -lt "$MAX_TRIES" ]; do
        i=$((i + 1))
        cryptsetup open --type luks2 "$PART" "$LUKS_NAME"
        rc=$?
        [ "$rc" -eq 0 ] && break
        if [ "$rc" -ne 2 ]; then
            echo "[aurora] cryptsetup error ($rc) opening $PART. Falling back to amnesic."
            exit 1
        fi
        echo "[aurora] Incorrect passphrase (attempt $i of $MAX_TRIES)."
        if [ "$i" -ge "$MAX_TRIES" ]; then
            echo "[aurora] Too many failed attempts. Falling back to amnesic mode."
            exit 1
        fi
    done
fi

mkdir -p "$MOUNTPOINT"
if ! mount "$MAPPED" "$MOUNTPOINT" 2>/dev/null; then
    echo "[aurora] Could not mount the persistent filesystem. Falling back to amnesic."
    cryptsetup close "$LUKS_NAME" 2>/dev/null || true
    exit 1
fi

# Bind-mount persistent subdirectories over the live system. These are the
# directories whose contents survive reboot.
for dir in home/aurora/Documents home/aurora/Downloads home/aurora/Persistent \
           home/aurora/.config home/aurora/.local home/aurora/.gnupg \
           home/aurora/.ssh var/lib/apt/lists \
           etc/NetworkManager/system-connections; do
    src="$MOUNTPOINT/$dir"
    dst="/$dir"
    if [ -d "$src" ]; then
        mkdir -p "$dst"
        mount --bind "$src" "$dst" || echo "[aurora] WARNING: could not bind $dst"
    fi
done

echo "[aurora] Persistent volume unlocked and mounted at $MOUNTPOINT"
exit 0
