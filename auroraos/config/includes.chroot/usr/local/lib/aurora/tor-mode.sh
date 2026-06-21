#!/bin/sh
# =============================================================================
# AuroraOS — Tor transparent proxy + kill switch
# =============================================================================
# In Tor mode, ALL traffic must go through Tor or be dropped. This script builds
# a single nftables ruleset that:
#   1. Lets ONLY the tor daemon (user debian-tor) talk to the network directly.
#   2. Transparently redirects every other process's TCP to Tor's TransPort.
#   3. Redirects all DNS (udp/tcp :53) to Tor's DNSPort.
#   4. DROPS everything else — non-DNS UDP, ICMP, and anything not torified
#      (the "kill switch"). Default policy is DROP, so it fails CLOSED.
#   5. DROPS all IPv6 (we torify over IPv4 only; unfiltered v6 would leak).
#
# Design notes / why this differs from a naive transproxy:
#   * The tor daemon's OWN outbound connections (to guards/relays) must NOT be
#     redirected back into its own TransPort — that deadlocks bootstrap. We
#     exempt them by matching the debian-tor UID (`meta skuid`).
#   * The firewall is applied BEFORE the daemon is (re)started, so there is no
#     window where traffic escapes un-torified. If tor never comes up, the
#     default-drop policy keeps leaking impossible.
#   * Onion names resolve to a virtual address range (AutomapHostsOnResolve);
#     that range is redirected to the TransPort like any other TCP.
#
# Uses nftables (the modern Debian default). Safe to re-run (idempotent): the
# whole ruleset is replaced atomically with `nft -f`.
# =============================================================================

set -eu

TABLE4="aurora_tor"
TABLE6="aurora_tor6"
TRANS_PORT=9040
DNS_PORT=5353
SOCKS_PORT=9050
# Tor's automapped onion range — MUST match VirtualAddrNetworkIPv4 in torrc.
VIRT_NET="10.192.0.0/10"

# The system user the Debian 'tor' package runs as. Resolve to a numeric UID so
# the nft rule does not depend on name resolution inside the kernel.
tor_uid() {
    id -u debian-tor 2>/dev/null || echo ""
}

# UID of the dedicated, sandboxed Unsafe Browser user (clearnet captive-portal
# browser). Empty if that user doesn't exist.
clearnet_uid() {
    id -u clearnet 2>/dev/null || echo ""
}

start_tor() {
    echo "[aurora-tor] Starting tor daemon..."
    systemctl restart tor@default 2>/dev/null \
        || systemctl restart tor 2>/dev/null \
        || service tor restart 2>/dev/null \
        || { echo "[aurora-tor] ERROR: could not start tor."; return 1; }

    # Wait for a working Tor circuit (through the SOCKS port).
    i=0
    while [ "$i" -lt 30 ]; do
        if curl -s --max-time 5 --socks5-hostname 127.0.0.1:"$SOCKS_PORT" \
                https://check.torproject.org/ >/dev/null 2>&1; then
            echo "[aurora-tor] Tor circuit established."
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    echo "[aurora-tor] WARNING: Tor did not confirm connectivity in 30s."
    echo "[aurora-tor] (Traffic stays BLOCKED by the kill switch until Tor is up.)"
    return 0
}

apply_firewall() {
    TOR_UID="$(tor_uid)"
    if [ -z "$TOR_UID" ]; then
        echo "[aurora-tor] ERROR: debian-tor user not found; refusing to apply"
        echo "[aurora-tor]        a transparent-proxy firewall without it (would"
        echo "[aurora-tor]        either deadlock Tor or fail open). Is 'tor' installed?"
        return 1
    fi

    echo "[aurora-tor] Applying Tor kill-switch firewall (fail-closed)..."

    # Defense-in-depth (audit M1): disable the IPv6 stack entirely in Tor mode so
    # NO v6 address (SLAAC/DHCPv6) is ever assigned or advertised on the LAN —
    # closing the pre-firewall SLAAC window and any v6 IID leak. We torify over
    # IPv4 only, so nothing legitimate needs v6 here.
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true

    # Build the entire ruleset in one file and load it atomically. If anything
    # in here is malformed, nft rejects the WHOLE file and the previous state is
    # kept — we never end up half-applied / fail-open.
    nft -f - <<NFT
# ---- wipe any previous Aurora tables (add-then-delete = no error if absent) ----
add table ip ${TABLE4}
delete table ip ${TABLE4}
add table ip6 ${TABLE6}
delete table ip6 ${TABLE6}

# ============================ IPv4: torify ============================
table ip ${TABLE4} {
    # NAT redirect for locally-generated packets.
    chain nat_output {
        type nat hook output priority -100; policy accept;

        # The tor daemon itself reaches the network directly — never redirect it.
        meta skuid ${TOR_UID} return

        # Don't touch loopback (Tor's own ports live there).
        oifname "lo" return

        # Unsafe Browser exemption (chain is EMPTY by default = no effect). Filled
        # only while the Unsafe Browser runs (clearnet-open), so its 'clearnet' user
        # goes DIRECT to the network (no Tor redirect); flushed the instant it exits.
        jump clearnet_nat

        # DNS -> Tor's DNSPort.
        meta l4proto udp udp dport 53 redirect to :${DNS_PORT}
        meta l4proto tcp tcp dport 53 redirect to :${DNS_PORT}

        # Onion virtual range -> TransPort.
        ip daddr ${VIRT_NET} meta l4proto tcp redirect to :${TRANS_PORT}

        # Everything else TCP -> TransPort.
        meta l4proto tcp redirect to :${TRANS_PORT}
    }

    # Kill switch: default DROP. Only torified / essential traffic survives.
    chain filter_output {
        type filter hook output priority 0; policy drop;

        ct state established,related accept
        oifname "lo" accept

        # Unsafe Browser exemption (EMPTY by default). Only while the Unsafe
        # Browser is running is its 'clearnet' user allowed straight out; otherwise
        # this chain is empty and the kill-switch blocks it like everything else.
        jump clearnet_filter

        # Tor daemon's own traffic to guards/relays.
        meta skuid ${TOR_UID} accept

        # Redirected DNS/TCP now target loopback ports — allow reaching them.
        ip daddr 127.0.0.0/8 accept

        # DHCP so we can actually obtain an IP / connect to the network.
        meta l4proto udp udp sport 68 udp dport 67 accept

        # Onion virtual range is redirected above; allow the redirected path.
        ip daddr ${VIRT_NET} accept

        # Anything else (non-DNS UDP, QUIC, ICMP, untorified TCP) is dropped.
        reject with icmp type admin-prohibited
    }

    # ---- Unsafe Browser exemption chains (EMPTY until the browser launches) ----
    # Regular (jump-target) chains, empty by default so nothing is exempted. The
    # Unsafe Browser launcher fills them (clearnet-open) for its lifetime only and
    # flushes them on exit (clearnet-close); when it is not running there is NO
    # path out for clearnet traffic at all — it is dropped like everything else.
    chain clearnet_nat { }
    chain clearnet_filter { }

    # ---- Inbound: default DROP. The machine offers no services to the LAN; only
    #      loopback, return traffic for our own connections, and DHCP replies live.
    chain filter_input {
        type filter hook input priority 0; policy drop;
        iifname "lo" accept
        ct state established,related accept
        meta l4proto udp udp sport 67 udp dport 68 accept
    }
    # ---- Not a router: drop all forwarding. ----
    chain filter_forward {
        type filter hook forward priority 0; policy drop;
    }
}

# ============================ IPv6: drop all =========================
# AuroraOS torifies over IPv4 only. Leaving IPv6 unfiltered would let traffic
# escape the kill switch entirely, so we drop everything except loopback.
table ip6 ${TABLE6} {
    chain filter_output {
        type filter hook output priority 0; policy drop;
        oifname "lo" accept
        ip6 daddr ::1 accept
        ct state established,related accept
    }
    chain filter_input {
        type filter hook input priority 0; policy drop;
        iifname "lo" accept
        ip6 saddr ::1 accept
        ct state established,related accept
    }
    chain filter_forward {
        type filter hook forward priority 0; policy drop;
    }
}
NFT

    echo "[aurora-tor] Kill switch active. All non-Tor traffic is blocked."
}

# There is deliberately NO stop_tor / "stop" action. Tearing the kill-switch
# down (an `nft delete table`) from a running session must be IMPOSSIBLE — the
# ONLY way to leave Tor mode is to REBOOT. (Security audit C1/H3: a reachable
# teardown path is the opposite of fail-closed.)

status_tor() {
    if nft list table ip "$TABLE4" >/dev/null 2>&1; then
        echo "Tor kill-switch: ACTIVE (IPv4 redirect + IPv6 drop)"
    else
        echo "Tor kill-switch: inactive"
    fi
    if systemctl is-active --quiet tor@default 2>/dev/null \
        || systemctl is-active --quiet tor 2>/dev/null; then
        echo "Tor daemon     : running"
    else
        echo "Tor daemon     : stopped"
    fi
}

case "${1:-start}" in
    firewall)
        # Apply ONLY the kill switch (fail-closed) — do NOT start Tor. Used at
        # early boot so all non-Tor traffic is blocked BEFORE the network comes
        # up, and Tor is only started later when the user explicitly connects.
        # Idempotent (the whole ruleset is replaced atomically).
        if [ "$(id -u)" -ne 0 ]; then
            echo "aurora-tor firewall must run as root"
            exit 1
        fi
        apply_firewall
        ;;
    start)
        if [ "$(id -u)" -ne 0 ]; then
            echo "aurora-tor start must run as root (try: sudo aurora-tor start)"
            exit 1
        fi
        # Fail CLOSED: install the kill switch FIRST, then bring Tor up. If the
        # firewall can't be applied we abort rather than leak.
        apply_firewall
        start_tor || echo "[aurora-tor] Tor did not start cleanly; kill switch remains active."
        ;;
    status)
        status_tor
        ;;
    clearnet-open)
        # Open the clearnet exemption for the Unsafe Browser's 'clearnet' user —
        # for the LIFETIME of the browser only (called by aurora-unsafe-browser).
        # No-op outside Tor mode (no kill-switch table => clearnet already open).
        if [ "$(id -u)" -ne 0 ]; then echo "must be root"; exit 1; fi
        CUID="$(clearnet_uid)"
        [ -n "$CUID" ] || { echo "[aurora-tor] no 'clearnet' user; refusing."; exit 1; }
        if nft list table ip "$TABLE4" >/dev/null 2>&1; then
            nft add rule ip "$TABLE4" clearnet_nat meta skuid "$CUID" accept
            # Isolate from LOCAL services first: the Unsafe Browser must NEVER reach
            # Tor's ports or any loopback service (matches Tails' design — "cannot
            # contact local services, like Tor"). Rule order matters: drop loopback
            # BEFORE the blanket accept below.
            nft add rule ip "$TABLE4" clearnet_filter ip daddr 127.0.0.0/8 meta skuid "$CUID" drop
            nft add rule ip "$TABLE4" clearnet_filter meta skuid "$CUID" accept
            echo "[aurora-tor] Clearnet exemption OPEN for uid $CUID (Unsafe Browser)."
        fi
        ;;
    clearnet-close)
        # Flush the exemption so NOTHING clearnet can leave once the browser exits.
        if [ "$(id -u)" -ne 0 ]; then echo "must be root"; exit 1; fi
        if nft list table ip "$TABLE4" >/dev/null 2>&1; then
            nft flush chain ip "$TABLE4" clearnet_nat 2>/dev/null || true
            nft flush chain ip "$TABLE4" clearnet_filter 2>/dev/null || true
            echo "[aurora-tor] Clearnet exemption CLOSED."
        fi
        ;;
    *)
        echo "Usage: $0 {start|status|firewall|clearnet-open|clearnet-close}  (no 'stop' — reboot to leave Tor mode)"
        exit 1
        ;;
esac
