#!/bin/bash
# =============================================================================
# AuroraOS — release / update-channel publisher  (runs on the build host)
# =============================================================================
# Turns a built ISO into a SIGNED update that AuroraOS devices can install via
# aurora-upgrade. Two subcommands:
#
#   ./release.sh keygen
#       One-time. Generates the minisign Ed25519 signing keypair:
#         signing/auroraos-update.key   <- PRIVATE. Keep secret & offline.
#         signing/auroraos-update.pub   <- public; also copied into the image
#                                          source so every build trusts it.
#       Run this BEFORE your first build, then build, so the public key is baked
#       in. NEVER commit the private key.
#
#   ./release.sh publish [ISO]
#       Extracts live/filesystem.squashfs from the ISO, hashes + signs it and a
#       manifest with your private key, and uploads the signed channel to R2:
#         updates/<version>/filesystem.squashfs(.minisig)
#         updates/<channel>/manifest.json(.minisig)
#       Requires R2 creds in the environment (see r2-upload.py header).
#
# Dependencies (build host): minisign, xorriso, squashfs-tools, python3+boto3.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load a gitignored .env (R2 creds, channel overrides) if present.
if [ -f "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

# --- GNU coreutils shim (build host may default to Rust "uutils") -------------
# Modern Ubuntu/WSL (25.10+/26.04) ships uutils coreutils, whose `mktemp -d`
# SILENTLY prints nothing (breaking the temp dir below) and whose `cp -a`/`chroot`
# misbehave — the same reason build.sh shims GNU coreutils for `lb build`. The
# OTA manifest's sha256 is security-critical, so if uutils is detected AND GNU
# coreutils is installed (gnu-prefixed binaries), put real GNU tools first on
# PATH for the whole release. (mkdir/ln/basename below are NOT among the broken
# uutils tools, so they are safe to use to build the shim.)
if mktemp --version 2>/dev/null | grep -qi uutils && [ -x /usr/bin/gnumktemp ]; then
    GNU_BIN="/tmp/aurora-gnu-coreutils.$$"
    mkdir -p "$GNU_BIN"
    for g in /usr/bin/gnu* /usr/sbin/gnu*; do
        [ -e "$g" ] || continue
        n="$(basename "$g")"; n="${n#gnu}"
        [ -n "$n" ] && ln -sf "$g" "$GNU_BIN/$n"
    done
    PATH="$GNU_BIN:$PATH"
    echo "[release] Detected uutils coreutils; using GNU coreutils ($GNU_BIN) for this run."
fi

SIGN_DIR="$HERE/signing"
PRIV="$SIGN_DIR/auroraos-update.key"
PUB="$SIGN_DIR/auroraos-update.pub"
IMAGE_PUB="$HERE/auroraos/config/includes.chroot/usr/local/share/aurora/aurora-update.pub"

CHANNEL="${UPDATE_CHANNEL:-stable}"
BUCKET="${R2_BUCKET:-auroraos-iso}"

die() { echo "release: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

cmd_keygen() {
    need minisign
    mkdir -p "$SIGN_DIR"
    if [ -f "$PRIV" ]; then
        die "private key already exists at $PRIV (refusing to overwrite)."
    fi
    echo "[release] Generating AuroraOS update signing keypair..."
    # -W: no password on the secret key (unattended signing). To password-protect
    # it instead, drop -W and you'll be prompted when signing.
    minisign -G -W -p "$PUB" -s "$PRIV"
    chmod 600 "$PRIV"
    mkdir -p "$(dirname "$IMAGE_PUB")"
    cp "$PUB" "$IMAGE_PUB"
    echo
    echo "[release] DONE."
    echo "  Private key: $PRIV   (KEEP SECRET — back it up offline, never commit)"
    echo "  Public key : $PUB"
    echo "  Baked into image source: $IMAGE_PUB"
    echo
    echo "  Next: run ./build.sh so the public key is included, then ./release.sh publish"
    echo "  Add signing/ to .gitignore."
}

cmd_publish() {
    need minisign; need xorriso; need unsquashfs; need python3
    [ -f "$PRIV" ] || die "no signing key. Run: ./release.sh keygen (then rebuild)."
    if grep -q REPLACE_WITH_YOUR_MINISIGN_PUBLIC_KEY "$IMAGE_PUB" 2>/dev/null; then
        die "image still has the placeholder public key. Run keygen + rebuild first."
    fi

    local ISO="${1:-$HERE/build-output/auroraos-0.1-amd64.iso}"
    [ -f "$ISO" ] || ISO="$(ls -1 "$HERE"/build-output/*.iso 2>/dev/null | head -1 || true)"
    [ -f "$ISO" ] || die "no ISO found (looked in build-output/)."
    echo "[release] Using ISO: $ISO"

    local WORK; WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' RETURN

    echo "[release] Extracting live/filesystem.squashfs from the ISO..."
    xorriso -osirrox on -indev "$ISO" -extract /live/filesystem.squashfs \
        "$WORK/filesystem.squashfs" >/dev/null 2>&1 \
        || die "could not extract the squashfs from the ISO."

    echo "[release] Reading version from the image..."
    local VER
    VER="$(unsquashfs -cat "$WORK/filesystem.squashfs" /etc/aurora-version 2>/dev/null | tr -d ' \t\r\n' || true)"
    [ -n "$VER" ] || VER="${AURORA_VERSION:-}"
    [ -n "$VER" ] || die "could not determine version (no /etc/aurora-version)."
    local MINVER="${AURORA_MIN_VERSION:-0.1}"
    echo "[release] Version: $VER  (min upgradable: $MINVER)"

    local SQ="$WORK/filesystem.squashfs"
    local SIZE SHA RELEASED
    SIZE="$(stat -c %s "$SQ")"
    SHA="$(sha256sum "$SQ" | awk '{print $1}')"
    RELEASED="${RELEASED_DATE:-$(date -u +%Y-%m-%d)}"
    local CHANGELOG="${CHANGELOG:-AuroraOS $VER}"

    local ART_KEY="updates/$VER/filesystem.squashfs"
    local BASE="${UPDATE_BASE_URL:-https://auroraos-download.rob74752.workers.dev/updates}"

    echo "[release] Signing the squashfs..."
    minisign -S -s "$PRIV" -m "$SQ" -x "$WORK/filesystem.squashfs.minisig" \
        -t "AuroraOS $VER squashfs sha256=$SHA"

    echo "[release] Building + signing the manifest..."
    cat > "$WORK/manifest.json" <<JSON
{
  "channel": "$CHANNEL",
  "latest": "$VER",
  "min_version": "$MINVER",
  "released": "$RELEASED",
  "changelog": "$CHANGELOG",
  "filename": "filesystem.squashfs",
  "url": "$BASE/$VER/filesystem.squashfs",
  "sig_url": "$BASE/$VER/filesystem.squashfs.minisig",
  "size": $SIZE,
  "sha256": "$SHA"
}
JSON
    minisign -S -s "$PRIV" -m "$WORK/manifest.json" -x "$WORK/manifest.json.minisig" \
        -t "AuroraOS $CHANNEL manifest latest=$VER"

    echo "[release] Uploading signed channel to R2 bucket '$BUCKET'..."
    AURORA_BUCKET="$BUCKET" python3 - "$WORK" "$VER" "$CHANNEL" <<'PY'
import os, sys, hashlib, boto3
from boto3.s3.transfer import TransferConfig
from botocore.client import Config
work, ver, channel = sys.argv[1], sys.argv[2], sys.argv[3]
akid = os.environ.get("R2_ACCESS_KEY_ID") or os.environ.get("AWS_ACCESS_KEY_ID")
secret = os.environ.get("R2_SECRET_ACCESS_KEY") or os.environ.get("AWS_SECRET_ACCESS_KEY")
account = os.environ.get("R2_ACCOUNT_ID", "19b9b5fbb35ca9dbc69b99d8531f04de")
bucket = os.environ["AURORA_BUCKET"]
if not akid or not secret:
    sys.exit("ERROR: set R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY in the environment.")
s3 = boto3.client("s3", endpoint_url=f"https://{account}.r2.cloudflarestorage.com",
                  aws_access_key_id=akid, aws_secret_access_key=secret,
                  region_name="auto", config=Config(signature_version="s3v4",
                  retries={"max_attempts": 10}))
cfg = TransferConfig(multipart_threshold=200*1024*1024, multipart_chunksize=200*1024*1024,
                     max_concurrency=8)
uploads = [
    (f"{work}/filesystem.squashfs",          f"updates/{ver}/filesystem.squashfs",          "application/octet-stream"),
    (f"{work}/filesystem.squashfs.minisig",  f"updates/{ver}/filesystem.squashfs.minisig",  "text/plain"),
    (f"{work}/manifest.json",                f"updates/{channel}/manifest.json",            "application/json"),
    (f"{work}/manifest.json.minisig",        f"updates/{channel}/manifest.json.minisig",    "text/plain"),
]
for local, key, ctype in uploads:
    extra = {"ContentType": ctype}
    if key.endswith("filesystem.squashfs"):
        with open(local, "rb") as f:
            sha = hashlib.sha256()
            for chunk in iter(lambda: f.read(8*1024*1024), b""):
                sha.update(chunk)
        extra["Metadata"] = {"sha256": sha.hexdigest(), "version": ver}
    print(f"  -> s3://{bucket}/{key}")
    s3.upload_file(local, bucket, key, ExtraArgs=extra, Config=cfg)
print("[release] Upload complete.")
PY

    echo
    echo "[release] Published AuroraOS $VER to channel '$CHANNEL'."
    echo "  Manifest: $BASE/$CHANNEL/manifest.json"
    echo "  Devices on >= $MINVER will see it via aurora-upgrade."
}

case "${1:-}" in
    keygen)  cmd_keygen ;;
    publish) shift; cmd_publish "${1:-}" ;;
    *) echo "Usage: $0 {keygen|publish [ISO]}"; exit 1 ;;
esac
