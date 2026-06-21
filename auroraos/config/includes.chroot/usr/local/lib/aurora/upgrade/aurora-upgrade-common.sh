#!/bin/sh
# =============================================================================
# AuroraOS — shared helpers for the signed update system
# =============================================================================
# Sourced by aurora-upgrade-check and aurora-upgrade-apply. Provides:
#   * configuration (channel URL, public key, paths)
#   * Tor-aware downloading (routes over Tor when in Tor mode)
#   * cryptographic verification (minisign Ed25519 — the trust anchor)
#   * dotted version comparison
#
# SECURITY MODEL: the OpenPGP/HTTPS transport is NOT trusted. The only thing
# that authorises an update is a valid minisign signature, made by the AuroraOS
# Update Signing Key, over BOTH the manifest and the artifact. If the public key
# has not been provisioned (still the placeholder), updates are DISABLED — we
# fail closed rather than fetch anything unauthenticated.
# =============================================================================

AURORA_VERSION_FILE="/etc/aurora-version"
AURORA_PUBKEY="/usr/local/share/aurora/aurora-update.pub"
AURORA_CHANNEL_CONF="/usr/local/share/aurora/update-channel.conf"
AURORA_MODE_FILE="/run/aurora-mode"
AURORA_PLACEHOLDER="REPLACE_WITH_YOUR_MINISIGN_PUBLIC_KEY"

# Defaults (overridable by /usr/local/share/aurora/update-channel.conf).
UPDATE_BASE_URL="https://auroraos-download.rob74752.workers.dev/updates"
UPDATE_CHANNEL="stable"
# shellcheck source=/dev/null
[ -r "$AURORA_CHANNEL_CONF" ] && . "$AURORA_CHANNEL_CONF"

au_log()  { printf '[aurora-upgrade] %s\n' "$*" >&2; }
au_die()  { au_log "ERROR: $*"; exit 1; }

# Current installed version.
au_current_version() {
    if [ -r "$AURORA_VERSION_FILE" ]; then
        tr -d ' \t\n\r' < "$AURORA_VERSION_FILE"
    else
        echo "0"
    fi
}

# Refuse to do anything unless the signing key has been provisioned.
au_require_pubkey() {
    [ -r "$AURORA_PUBKEY" ] || au_die "no update public key at $AURORA_PUBKEY (updates disabled)."
    if grep -q "$AURORA_PLACEHOLDER" "$AURORA_PUBKEY" 2>/dev/null; then
        au_die "update signing key not provisioned (still the placeholder). Updates are disabled."
    fi
    command -v minisign >/dev/null 2>&1 || au_die "minisign not installed; cannot verify updates."
}

# Are we routing through Tor this session?
au_is_tor() {
    [ -r "$AURORA_MODE_FILE" ] && [ "$(cat "$AURORA_MODE_FILE" 2>/dev/null)" = "tor" ] && return 0
    nft list table ip aurora_tor >/dev/null 2>&1 && return 0
    return 1
}

# Download $1 -> $2. Over Tor in Tor mode; direct otherwise. Resumable.
au_fetch() {
    _url="$1"; _out="$2"
    if au_is_tor; then
        curl -fSL --socks5-hostname 127.0.0.1:9050 --connect-timeout 30 \
             --retry 3 -C - -o "$_out" "$_url"
    else
        curl -fSL --connect-timeout 30 --retry 3 -C - -o "$_out" "$_url"
    fi
}

# Verify a minisign detached signature: au_verify_sig <file> <sigfile>
au_verify_sig() {
    minisign -Q -V -p "$AURORA_PUBKEY" -m "$1" -x "$2" >/dev/null 2>&1
}

# sha256 of a file (just the hex digest).
au_sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# Extract a top-level string field from a (simple, flat) JSON object.
# Usage: au_json_str <file> <key>
au_json_str() {
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}
# Extract a numeric field.
au_json_num() {
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" | head -1
}

# Compare dotted versions. Echoes: -1 (a<b), 0 (a==b), 1 (a>b).
au_vercmp() {
    _a="$1"; _b="$2"
    [ "$_a" = "$_b" ] && { echo 0; return; }
    _hi=$(printf '%s\n%s\n' "$_a" "$_b" | sort -V | tail -1)
    if [ "$_hi" = "$_a" ]; then echo 1; else echo -1; fi
}
