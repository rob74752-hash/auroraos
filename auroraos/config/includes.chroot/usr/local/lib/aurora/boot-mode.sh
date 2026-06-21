#!/bin/sh
# =============================================================================
# AuroraOS — boot mode runtime selector (runs early at boot)
# =============================================================================
# Reads the kernel command line (set by the boot menu) and configures the
# session. Persistence and Tor are INDEPENDENT flags, so they can be combined:
#
#   aurora.persistent  -> unlock + mount the encrypted Persistent volume
#   aurora.tor         -> route everything through Tor (kill switch applied
#                         later, once the network is up, by aurora-tor-mode)
#   (neither)          -> amnesic (pure RAM, leaves no trace)
#
# Examples: "aurora.amnesic" (default), "aurora.persistent", "aurora.tor",
# and "aurora.persistent aurora.tor" (Persistent + Tor).
#
# Writes the effective mode to /run/aurora-mode. When Tor is requested the mode
# string is "tor" (so the Tor checks elsewhere match) even if persistence is
# also on; persistence is reported separately via the /mnt/persistent mount.
#
# IMPORTANT: never abort the boot. No `set -e`; every step tolerates failure.
# =============================================================================

RUNTIME_MODE_FILE="/run/aurora-mode"
CMDLINE="/proc/cmdline"

has_token() { grep -qw "$1" "$CMDLINE" 2>/dev/null; }

# Disable swap so plaintext memory can never be written to a disk we don't
# control. No-op if there is no swap.
disable_swap() { swapoff -a 2>/dev/null || true; }

WANT_PERSIST=0; WANT_TOR=0
has_token aurora.persistent && WANT_PERSIST=1
has_token aurora.tor && WANT_TOR=1

# Effective mode string for display + for the Tor-aware checks elsewhere.
if [ "$WANT_TOR" -eq 1 ]; then
    mode="tor"
elif [ "$WANT_PERSIST" -eq 1 ]; then
    mode="persistent"
else
    mode="amnesic"
fi
echo "[aurora] Boot mode: persistent=$WANT_PERSIST tor=$WANT_TOR (mode=$mode)"
printf '%s\n' "$mode" > "$RUNTIME_MODE_FILE" 2>/dev/null || true

disable_swap

if [ "$WANT_PERSIST" -eq 1 ]; then
    if /usr/local/lib/aurora/mount-persistent.sh; then
        echo "[aurora] Persistent volume active."
    else
        echo "[aurora] No Persistent volume unlocked — files will NOT be saved this session."
    fi
fi

if [ "$WANT_TOR" -eq 1 ]; then
    # NOTE on bridges: boot-time bridge setting (aurora.bridge=) has been REMOVED.
    # Bridges are now configured in-session via the Tails-style paste box in
    # aurora-tor-assistant, validated by aurora-tor-set-bridges (see audit
    # C1d/C3 resolved). Nothing to do here at boot — the kill-switch applies
    # before the network comes up, and the user pastes a bridge (if needed) once
    # the desktop is up.
    echo "[aurora] Tor mode — kill switch will activate once the network is up."
fi

echo "[aurora] Boot mode setup complete."
exit 0
