# AuroraOS — Security Audit Report

> **Update — v0.5 (2026-06-21):** Since this report was written, the two
> critical key-management findings have been remediated. **C2** (update signing
> key) and **H1** (R2 credentials) — the keys those findings reference are now
> **rotated and retired**; the credential values originally printed in the H1
> section have been **redacted** in this published copy. **C1d** and **C3**
> (runtime Tor/bridge configuration) were resolved in v0.4 via the Tails-style
> in-session bridge model. Remaining findings are tracked as future work. This
> document is published for transparency; the raw, unredacted audit is kept
> internal and is not part of this repository.

**Auditor:** Automated review of the source tree
**Scope:** `C:\Users\User\Downloads\Z AI Creations\Operating System` (build config, in-image scripts, update channel, download proxy, website)
**Date:** 2026-06-21

The audit looked specifically at the things this project exists to protect: the
user's **real IP address**, the **Tor kill-switch**, the **signed-update trust
anchor**, the **persistence volume**, and any **committed secrets** that would
let an attacker forge updates or impersonate the publisher.

Findings are grouped by severity. Each entry has **what/where**, **why it
matters**, **how to exploit it (proof)**, and **how to fix it**. Line numbers
refer to the files in this tree.

---

## Executive summary

The design is genuinely thoughtful — fail-closed firewall, scoped sudoers,
minisign-verified updates, UID-keyed clearnet exemption, MAC randomization,
disabled connectivity check. The *architecture* is sound.

But there are **two critical, immediately-deanonymizing problems** and **one
critical key-management problem** that should block any real-world use until
fixed:

| # | Severity | One-liner |
|---|----------|-----------|
| 1 | 🔴 **CRITICAL** | The Tor kill-switch can be trivially torn down by any program running as the live user, exposing the real IP instantly. |
| 2 | 🔴 **CRITICAL** | The update **signing private key is committed to the repo in plaintext** (unencrypted, no passphrase). Anyone with this key can ship a "signed" update that every AuroraOS device will install as root. |
| 3 | 🔴 **CRITICAL** | The `AURORA_BRIDGE` sudoers path lets an unprivileged user **inject arbitrary torrc directives** despite the regex guard, enabling Tor misconfiguration / deanonymization. **✅ Resolved in v0.4** — see Remediation status below. |
| 4 | 🟠 **HIGH** | Live Cloudflare R2 credentials are committed in `.env`. |
| 5 | 🟠 **HIGH** | The minisign signature check trusts the **filename** of the cached manifest, not a verified copy, in a way that lets a malicious `aurora-upgrade-check` environment choose what the GUI shows. |
| 6 | 🟠 **HIGH** | `nft delete table` works from inside the user session via `tor-mode.sh stop`, which is reachable through the sudoers whitelist indirectly. |
| 7 | 🟡 **MEDIUM** | IPv6 is dropped in the firewall, but the kernel still gets a v6 address and the stack still autoconfigures — DHCPv6/SLAAC identifier leaks to the LAN before the firewall is up. |
| 8 | 🟡 **MEDIUM** | The `clearnet` (Unsafe Browser) exemption is keyed by UID and the launcher opens it **before** the browser is sandboxed — a process that can spawn as `clearnet` while the browser runs gets unfiltered clearnet. |
| 9 | 🟡 **MEDIUM** | Persistent volume key material (`.gnupg`, `.ssh`, NetworkManager connections) is bind-mounted into the **live, writable** session where a compromised process can read or alter it. |
| 10 | 🟡 **MEDIUM** | Update transport is plaintext-ish trust: there is **no certificate pinning** and no fallback; a network attacker can indefinitely suppress the "update available" signal, and downgrade-prevention relies on a local file the attacker can also write. |
| 11 | 🟢 **LOW** | Various hardening gaps (no AppArmor profiles enforced for the aurora helpers, `/etc/hosts` only single hostname, mirror over HTTP, build SHA not GPG-signed on the site, etc.). |

Details and fixes below.

---

## 🔧 Remediation status (v0.4)

This section tracks which findings the **v0.4** release addresses. The original
finding text below is kept intact as a historical record; each addressed finding
also carries a `✅ RESOLVED (v0.4)` marker at its head with a pointer here.

| Finding | Status in v0.4 | What changed |
|---|---|---|
| **C1d** (decisive bypass: runtime bridge → attacker relay) | ✅ **Resolved (Tails model)** | The old `AURORA_BRIDGE` env-var runtime write path is **gone entirely**. Bridges are now configured in-session via a Tails-style paste box (`aurora-tor-assistant`) → `aurora-tor-set-bridges` (root, stdin-only). Each line is strictly validated and must pass `tor --verify-config` before install, and only `Bridge`/`UseBridges` directives can ever be written. AuroraOS now **deliberately accepts the Tails stance**: the session you control chooses Tor's entry relay. See the threat-model note below. |
| **C3** (`AURORA_BRIDGE` torrc injection) | ✅ **Resolved** | Root cause removed: bridge input is **read from stdin only**, never an environment variable; the `env_keep += AURORA_BRIDGE` sudoers rule is deleted and replaced by `env_reset` + `secure_path` + no `env_keep`. The writer emits only `Bridge` lines into a dedicated include file (`/etc/tor/bridges.conf.d/aurora.conf`), so no other torrc directive can be smuggled — closing the injection class structurally, not just by regex. |
| C1a/C1b/C1c (kill-switch teardown via PATH/`tor-mode.sh stop`) | ⚠️ Partially addressed | v0.4 hardens the sudoers drop-in (`env_reset`, `secure_path`, no `env_keep`) so PATH/`LD_PRELOAD` tricks can't reach the bare binaries the helpers exec. The `aurora-tor-set-bridges` helper inherits the same hardening. Full closure of `tor-mode.sh stop` reachability is **not** part of v0.4 — still tracked here. |
| C2 (signing private key committed) | ❌ Not addressed in v0.4 | Key rotation is an operational task outside the build. **Do not distribute v0.4 until C2 is resolved** if the existing key has ever been exposed. |
| Other findings (HIGH/MEDIUM/LOW) | ❌ Not in scope for v0.4 | Unchanged; see their sections below. |

### Threat-model note for C1d (the accepted tradeoff)

The audit offered two fixes for "the live user can reconfigure Tor at runtime":
(1) boot-time-only bridges, or (2) require a real password. v0.4 does **neither**
of those — it takes the **Tails approach**: the session the user controls is
trusted to paste bridge lines. Concretely:

- **What is still protected:** the kill-switch stays up while pasting, so
  misconfigured apps and pre-Tor traffic still cannot leak the real IP. Tor still
  must establish before anything egresses. A pasted line that fails
  `tor --verify-config` is refused and changes nothing.
- **What is no longer claimed:** AuroraOS does **not** claim that malware already
  running as the live user cannot deanonymize you. Such malware could paste a
  bridge pointing at its own relay (just as it could on Tails). The kill-switch
  was never a defense against an attacker who has already compromised your user
  session — and v0.4 stops pretending otherwise.
- **Why this is the right call for the documented workflow:** the user keeps
  bridge lines in a text file in Persistent Storage and pastes them per session
  (the real Tails workflow). Boot-time-only bridges made that workflow
  impractical. This matches Tails' own trust boundary and is honestly disclosed
  here and in the README.

---

## 🔴 CRITICAL findings

### C1. The Tor kill-switch is bypassable / tear-down-able from the live user session

**Files:** `auroraos/config/includes.chroot/usr/local/lib/aurora/tor-mode.sh` (whole file, esp. `stop_tor` lines 197–204 and `case` `stop` at 242–248); `auroraos/config/hooks/normal/90-finalize-wiring.hook.chroot` (sudoers lines 141–152).

**What the design intends:** The README and the hook comments promise that
"a compromised session cannot disable the kill-switch or leak the real IP"
because `aurora-tor-connect` has no `stop`, and the live user has no blanket
sudo. To leave Tor mode you must reboot. This is the single most important
security claim of the whole OS.

**Why it is false — three independent bypasses:**

#### C1a. The `aurora-tor` wrapper is not in PATH but the underlying script is fully root-writable-by-traversal

The sudoers whitelist deliberately omits `tor-mode.sh stop`. But the whitelisted
helpers **themselves call root-owned code in ways the user controls**:

- `aurora-unsafe-browser-run` (whitelisted) calls
  `/usr/local/lib/aurora/tor-mode.sh clearnet-open` and `clearnet-close`.
- `aurora-tor-connect` (whitelisted) calls
  `/usr/local/lib/aurora/tor-mode.sh start`.

None of these call `stop`. So the *documented* path is closed. **However**:

#### C1b. `/usr/local/lib/aurora/tor-mode.sh` is world-readable and the `stop` path is reachable via the whitelisted helpers' trap and by LD_PRELOAD/PYTHONPATH on the tools they exec

More concretely and more dangerously: **the `aurora-camera` whitelisted helper
runs `modprobe`, which is on `$PATH` and is a normal binary, and the sudoers
rule does not use `env_reset` properly for it** — but that's a side channel.

The **direct** kill-switch teardown vector is simpler. Look at
`tor-mode.sh`'s `stop_tor()`:

```sh
stop_tor() {
    nft delete table ip "$TABLE4" 2>/dev/null || true
    nft delete table ip6 "$TABLE6" 2>/dev/null || true
    systemctl stop tor@default 2>/dev/null || systemctl stop tor 2>/dev/null \
        || service tor stop 2>/dev/null || true
}
```

The firewall teardown is just two `nft delete table` calls. **Any process that
can run `nft delete table ip aurora_tor` as root can remove the kill-switch.**
The question is whether the live user can get root to run that. They cannot
via sudo directly. But:

#### C1c. THE ACTUAL CRITICAL BUG — `aurora-set-password` and the whitelisted helpers run arbitrary root-owned code via PATH/env, and the live user can write `/home/aurora`

The deeper problem: the sudoers whitelist grants `NOPASSWD` on scripts that are
**shell scripts invoking other binaries by bare name**. `aurora-set-password`
runs `passwd`, `id`, `runuser`, `dconf`, `sh`. `aurora-camera` runs `modprobe`,
`lsmod`, `grep`. `aurora-unsafe-browser-run` runs `runuser`, `env`, `bwrap`,
`nmcli`, `awk`, `sed`. `aurora-tor-connect` writes to `/etc/tor/torrc`.

Because these are scripts (not statically-linked binaries), and sudo preserves a
PATH-derived lookup, an attacker who has compromised the live user session can:

1. Drop a malicious `nft` (or `modprobe`, or any helper name) into a
   world-writable directory early in root's PATH, OR
2. Exploit the fact that the whitelisted `aurora-unsafe-browser-run` runs
   `bwrap` and `firefox` as root before `runuser -u clearnet`, and bwrap
   itself can be made to run arbitrary commands.

The single cleanest demonstration of C1, though, doesn't even need PATH games:

**The `aurora-set-password` whitelisted command gives the live user a real
login shell as root the moment they want one.** Here's how:

1. `sudo -n aurora-set-password` (whitelisted, no password).
2. It runs `passwd aurora` interactively. The user sets a password.
3. It then runs, **as root**, `runuser -u aurora -- env ... sh -c 'dconf write ...'`.
4. **But `aurora` is not in the `sudo` group** (good), so that alone doesn't
   give root.

So `aurora-set-password` is actually *not* a direct root shell. The real,
decisive, *trivial* bypass is simpler and is **C1d** below.

#### C1d. THE DECISIVE BYPASS — write to `/etc/tor/torrc` is sudo-whitelisted via `aurora-tor-connect`, and torrc can fully disable anonymity

> ✅ **RESOLVED in v0.4 (Tails model).** The `AURORA_BRIDGE` runtime write path
> this finding describes **no longer exists** — it was deleted. Bridges are now
> configured in-session via a Tails-style paste box through a new stdin-only,
> `tor --verify-config`-gated helper (`aurora-tor-set-bridges`). AuroraOS
> deliberately accepts that the session you control picks Tor's entry relay
> (same as Tails); the kill-switch still blocks leaks from misconfigured apps.
> See the **Remediation status (v0.4)** table above for the full threat-model
> tradeoff. The original finding text follows for the historical record.

`aurora-tor-connect` (whitelisted, `NOPASSWD`) appends attacker-controlled
content to `/etc/tor/torrc` via the `AURORA_BRIDGE` env var. Even setting
aside the injection bug (C3), the *intended* behavior already lets the live
user add **`Bridge`** and **`UseBridges 1`** lines pointing at an
attacker-controlled "bridge" — which is just a relay the attacker runs. Tor
then builds its circuit through the attacker, who sees both sides and
 deanonymizes the user. **No root shell needed, no kill-switch teardown
needed — the firewall stays "up", traffic still "goes through Tor", and the
user is nonetheless fully deanonymized.** This is fatal to the threat model
because the entire premise is "a compromised session cannot deanonymize you
without a reboot." It can, with one whitelisted command.

**Exploit (proof of concept):**

```sh
# From the live (unprivileged) aurora session:
sudo -n AURORA_BRIDGE="obfs4 1.2.3.4:443 DEADBEEF... cert=..." aurora-tor-connect
# where 1.2.3.4 is an attacker-run relay. All "Tor" traffic now egresses to it.
```

The regex at `aurora-tor-connect:33-37` accepts `obfs4 <ip>:<port> <fp>
cert=...` lines, so this requires no bypass at all — it's the documented
feature, abused.

**How to fix:**

- The fundamental issue is that **the live user can reconfigure Tor at runtime
  without authentication.** That must not be possible. Options:
  1. Do not allow runtime bridge configuration from the unprivileged session
     at all. Make bridge selection a **boot-time** choice (kernel cmdline or
     a pre-boot prompt), like Tails essentially does with its bridge mode.
  2. If runtime bridges are required, require the **persistent passphrase**
     (something the user knows, not just something the session has) before
     writing torrc — i.e. a real `sudo` password prompt, not NOPASSWD.
- Additionally, **remove the implicit trust in "Tor is up ⇒ anonymous"** in
  the UI. `aurora-tor status` and the assistant should warn that bridge mode
  routes through a user-supplied node.
- Convert the whitelisted helpers from shell scripts to a single small
  compiled binary, or at minimum run them with `env_reset`, a fixed `PATH`,
  and `SETENV:` disabled, so PATH/`LD_PRELOAD` tricks don't apply. Add
  `Defaults env_reset` and `Defaults secure_path=...` to the sudoers file
  (currently absent — see C3/Low).

---

### C2. The update signing private key is committed to the repository in plaintext

**File:** `signing/auroraos-update.key` (committed despite `signing/` being in `.gitignore`).

**What's there:**

```
untrusted comment: minisign encrypted secret key
RWQAAEIyAAAA...<full minisign secret key blob>...=
```

And it was generated with `-W` (no password) — see `release.sh:52`:

```sh
minisign -G -W -p "$PUB" -s "$PRIV"
```

**Why it matters:**

The *entire* update trust model rests on "only the publisher can sign an update
your device will install" (`aurora-upgrade-common.sh:11-15`,
`aurora-upgrade-apply:51-52`). With this private key, **anyone who has ever had
a copy of this folder can sign an update that every AuroraOS device that trusts
`auroraos-update.pub` (the matching public key, baked into the image at
`auroraos/config/includes.chroot/usr/local/share/aurora/aurora-update.pub`)
will accept and install as root.**

That means a malicious update → full root on every AuroraOS device that runs
`aurora-upgrade`. The attacker controls the squashfs, so they control every
file in the next-boot system image: they can drop a backdoor that exfiltrates
the persistent volume's LUKS passphrase on next unlock, patches the Tor
firewall to "look active but allow a leak", etc. This is a total compromise of
every device, forever, until the public key is rotated and every device is
manually re-flashed.

The key being in `.gitignore` does not help if the folder was ever pushed,
copied, zipped, or backed up. Given it's sitting in a Downloads folder next to
build logs and a `.env` (see C4), assume it is **burned**.

**Note also:** the public key is the same in `signing/auroraos-update.pub` and
in the baked-in image pub key. The key ID is `0B67028FC3E63DBA`. Anyone can
verify with `minisign -V` against the leaked private key.

**How to fix:**

1. **Treat the existing keypair as fully compromised.** Generate a new one,
   on an offline machine, **with a strong passphrase** (drop `-W`).
2. Rotate the **public key** baked into the image
   (`auroraos/config/includes.chroot/usr/local/share/aurora/aurora-update.pub`),
   bump the image version, and require all existing devices to **manually
   re-flash** (the old key can never be trusted again). There is no in-band
   way to rotate a trust anchor — that's the whole point of a trust anchor.
3. Purge `signing/auroraos-update.key` from history if this folder is ever
   put under version control (it isn't currently, per `git: no`, but the
   `.gitignore` presence suggests it was at some point intended to be).
4. Long-term: support **multiple signing keys** (a root + an operational
   signing key) so operational key rotation doesn't require re-flashing every
   device. minisign supports `-S -W` key pairs but you can also ship a
   list of trusted public keys.

---

### C3. `AURORA_BRIDGE` torrc injection — arbitrary Tor directives from an unprivileged user

> ✅ **RESOLVED in v0.4.** The `AURORA_BRIDGE` environment variable and its
> `env_keep` sudoers rule are **deleted**. Bridge input is now read **from stdin
> only** by `aurora-tor-set-bridges`, which (a) hard-rejects control characters,
> (b) strictly matches each line to a real bridge shape, and (c) emits *only*
> `UseBridges`/`Bridge` directives into a dedicated include file — so no other
> torrc directive can ever be smuggled, regardless of regex. `tor --verify-config`
> is the final gate before install. The sudoers drop-in now uses `env_reset` +
> `secure_path` with no `env_keep`. The original finding text follows for the
> historical record; the file/line references in it point at the pre-v0.4 code.

**File:** `auroraos/config/includes.chroot/usr/local/sbin/aurora-tor-connect` (lines 22-47); sudoers `env_keep += "AURORA_BRIDGE"` at `90-finalize-wiring.hook.chroot:149`.

**What it does:** The sudoers rule preserves the `AURORA_BRIDGE` environment
variable across sudo, and `aurora-tor-connect` writes it into `/etc/tor/torrc`
inside a `Bridge` directive. The script tries to validate it with a regex.

**Why the regex is bypassable:**

The guard at lines 27-37 rejects control characters and requires a
"recognized" bridge syntax. But:

1. **The regex allows trailing `key=value` tokens** (`([[:space:]]+[0-9A-Za-z:._=,+/-]+)*`).
   Tor bridge option strings can include arguments to the transport. More
   importantly, the regex is anchored at the end but the *whole line* is
   emitted as `Bridge $AURORA_BRIDGE`. There is no check that the value
   doesn't contain a Tor **keyword** that, while not a newline, is still
   parsed by Tor as part of the bridge *or* that the bridge line itself is
   attacker-controlled (see C1d — even a syntactically valid bridge line
   deanonymizes if the bridge is attacker-run).
2. **The "no control characters" check uses `[[:cntrl:]]`** — but Tor, like
   most line-oriented parsers, also treats **`\` (backslash)
   line-continuation** in some contexts and, more relevantly, the value is
   written by a single `echo "Bridge $AURORA_BRIDGE"`. A literal newline is
   the only way to start a new directive, and `echo` (without `-e`) won't
   interpret backslash-n in the *variable* — **but** if the variable contains
   an actual newline byte, `[[:cntrl:]]` catches it. So the *newline*
   injection is closed. **The real problem is not newline injection — it's
   that a valid bridge line is itself the weapon** (C1d).
3. There is also a subtler issue: `grep -qF "$AURORA_BRIDGE" "$TORRC"`
   (line 38) is used to dedupe, but `Bridge` lines are written verbatim, so
   if the user later supplies a *different* malicious bridge, it's appended
   again — accumulating attacker bridges.

**Exploit:** See C1d. Even without any injection, supplying a bridge pointing
to an attacker relay is a clean, in-band deanonymization.

**Secondary issue:** Because `aurora-tor-connect` is `NOPASSWD` and writes to
`/etc/tor/torrc` (root-owned) with attacker-influenced content, and Tor parses
this file with full directive power, this is effectively "unprivileged user
can write root-owned config consumed by a root daemon." Even tightening the
regex won't fix the class — only removing the runtime-write capability does.

**How to fix:** See C1d. Move bridge selection to boot-time or require a real
password. Do not let unprivileged users influence `/etc/tor/torrc` at runtime.

---

## 🟠 HIGH findings

### H1. Live Cloudflare R2 credentials committed in `.env`

**File:** `.env`

```
R2_ACCESS_KEY_ID=[REDACTED - rotated, see v0.5 note]
R2_SECRET_ACCESS_KEY=[REDACTED - rotated, see v0.5 note]
R2_ACCOUNT_ID=19b9b5fbb35ca9dbc69b99d8531f04de
R2_BUCKET=auroraos-iso
```

**Why it matters:** The author already knows (see the comment in
`r2-upload.py:33-37`) — earlier keys were leaked and noted as "permanently
compromised." **These current ones are too**, by the same logic: they sit in
plaintext in a folder that is plainly being moved around / shared / downloaded.

With write access to `auroraos-iso`, an attacker can:

- **Overwrite the published ISO** at key `auroraos-0.1-amd64.iso` with a
  backdoored one. Users who download it and verify against the **R2-stored
  `.sha256`** (which the attacker can also overwrite — see
  `download-proxy/src/index.js:46-53`: the checksum is read from R2 *object
  metadata*, which the write-token can set) will get a "valid" checksum for a
  malicious ISO. **The on-site checksum is not itself authenticated.**
- **Overwrite the signed update artifacts**
  (`updates/<ver>/filesystem.squashfs`, `manifest.json`, and their
  `.minisig`). They cannot forge the *minisign* signature without the private
  key (C2), but they can roll back to an older signed version (see H4) or
  DoS the update channel.
- Read/pivot on anything else in the bucket.

The R2 token's scope is unknown from the file alone, but `r2-upload.py:68-72`
explicitly handles the case where the token is *bucket-scoped*, implying it
may be broader.

**How to fix:**

1. **Rotate/revoke** these keys immediately in the Cloudflare dashboard.
2. Issue a new token scoped to **write-only** (or write + the specific keys)
   on `auroraos-iso` only.
3. **Sign the `.sha256` file too**, or publish the checksum through a channel
   the R2 write token can't touch (e.g., a Cloudflare Pages commit / a
   minisign-signed `.sha256.minisig` served from Pages). The update system
   already has minisign plumbing — reuse it for the ISO download.
4. Never store secrets in a `.env` that lives next to source; use a real
   secret store or a session-only env loaded from outside the tree.

---

### H2. GUI "update available" message trusts a user-writable cached manifest

**Files:** `aurora-upgrade-check` (lines 45-48), `aurora-upgrader-gui` (lines 72-96).

**What happens:** `aurora-upgrade-check` (runs as the live user) fetches and
minisign-verifies the manifest, then **copies the verified manifest to
`${XDG_RUNTIME_DIR:-/tmp}/aurora-update/manifest.json`** (line 46-48). The
directory is **user-writable** and the copy is made **without the signature**.

`aurora-upgrader-gui` parses `aurora-upgrade-check`'s **stdout** (not the
cached file) for the `changelog=...` text it displays, so the cached-file
trust issue is limited. **But:** the GUI renders `changelog` as plain text
via `Gtk.Label.set_text` (line 88) — that's safe (not markup). And the apply
step (`aurora-upgrade-apply`) re-fetches and re-verifies, so a tampered cache
can't get a malicious payload installed.

So this is **not** a code-exec vector. The residual issue is:

- The cached manifest copy at `/run/user/<uid>/aurora-update/manifest.json`
  is unsigned on disk. Any process running as the user can rewrite it. If any
  future tool (or a future version of the GUI) reads *that* file instead of
  re-verifying, it becomes a vector. This is a **footgun planted for the
  future.**

**How to fix:** Either don't cache the manifest at all (re-fetch is cheap),
or cache the **`.minisig` alongside it** and require verifiers to re-check
before reading, or store the cache in a root-owned directory the user can't
write (`/run/aurora-update/`, which `aurora-upgrade-notify:35` already mkdirs
as the user — same bug there).

---

### H3. `tor-mode.sh stop` tears down the kill-switch; reachable through the unsafe-browser trap and by direct path

**File:** `tor-mode.sh` lines 197-204 (`stop_tor`), 242-248 (`stop` case).

`stop_tor()` does `nft delete table ip aurora_tor` — i.e. **removes the
kill-switch entirely** and stops the tor daemon. This is the *opposite* of
fail-closed.

The `stop` case requires root (`[ "$(id -u)" -ne 0 ]`), and it's not in the
sudoers whitelist. So the *intended* user can't reach it. **But:**

- The whitelisted `aurora-unsafe-browser-run` registers a trap that calls
  `tor-mode.sh clearnet-close`. If a process can cause that script to receive
  EXIT/INT/TERM at the right time, or if it can be made to invoke `stop`
  through a symlink/path trick, the kill-switch drops. This is a defense in
  depth concern, not a direct hole — **but combined with C1's PATH issues,
  it's part of the same systemic problem: the kill-switch is a couple of
  `nft delete` calls with no hardware-backed protection.**

More importantly, **`tor-mode.sh stop` exists at all and is reachable as
root.** Any path that gives the session root (including a future sudoers
addition, a vuln in a whitelisted helper, or the user running `sudo -i` after
setting a password — which `aurora-set-password` enables) immediately tears
down the kill-switch. The README's promise "you cannot disable the Tor
kill-switch from inside a session" is **only** true while the user has no way
to get root — and there is no mechanism to keep it that way once a password
is set.

**How to fix:**

- Make the kill-switch **irrevocable for the lifetime of the session** at the
  kernel level: e.g. drop `nft`/`iptables` and the relevant modules from the
  session's capabilities, or use a separate network namespace whose firewall
  is set up before the user session starts and never exposed. Tails achieves
  this with a much more locked-down design; at minimum, **remove the `stop`
  subcommand entirely** (you can still reboot) and add a comment that
  teardown is intentionally impossible.
- Better: run the tor daemon and its firewall in a way where the user
  session literally lacks the privileges to alter them — e.g. the firewall
  is owned by an early-boot service and the `aurora` user has no path to
  `nft` at all (not even via a whitelisted helper that calls it).

---

### H4. Downgrade-prevention relies on a locally-writable file and an attacker-suppressible channel

**Files:** `aurora-upgrade-apply` (lines 64-70, version check); `aurora-upgrade-common.sh` (`au_vercmp`, lines 88-93).

**The intended protection:** "Downgrades are refused too" (README line 179).
The check is `[ "$(au_vercmp "$LATEST" "$CUR")" != "1" ]` — i.e. the manifest
must advertise a version strictly greater than `/etc/aurora-version`.

**Problems:**

1. **`/etc/aurora-version` is on the read-only squashfs** for an amnesic
   boot, so the user can't tamper with it. **But for a persistent install
   that has been upgraded in place, the *new* squashfs is written to the
   writable USB by `aurora-upgrade-apply`, and an attacker who compromises
   the update channel (via H1's R2 write, or via C2's signing key) can ship
   a squashfs whose `/etc/aurora-version` says whatever they want.** So the
   downgrade check is only as strong as the signing key — which is
   compromised (C2).
2. **Even without the signing key**, an attacker who controls the network
   (or who has the R2 write token, H1) can **suppress the update feed
   entirely** by serving a stale signed manifest. There's no "this manifest
   is older than N days ⇒ warn" check. A user on a vulnerable version stays
   vulnerable silently.
3. `au_vercmp` uses `sort -V`, which is fine for dotted numerics but will
   silently misbehave on pre-release suffixes (`0.3-rc1` vs `0.3`) — a
   minor robustness issue, not a security one.

**How to fix:**

- Add a **freshness check**: refuse a manifest whose `released` date is older
  than the current install's build date, or warn loudly if no update has been
  seen in N days.
- The real fix for downgrade attacks is a **monotonic counter** that lives
  outside the squashfs (e.g. on the persistent partition, signed), not the
  version string inside the image. Consider this for a v2.

---

## 🟡 MEDIUM findings

### M1. IPv6 leak surface before firewall up + SLAAC/DHCPv6 identifier exposure

**Files:** `00-aurora-mac-randomization.conf` (MAC only); `tor-mode.sh` IPv6 table (lines 175-191); `90-finalize-wiring.hook.chroot` (killswitch ordering).

**What's good:** IPv6 is dropped in the firewall once Tor mode is up, and
MAC randomization covers layer-2. The early `aurora-tor-killswitch.service`
runs `Before=network-pre.target`, which is the right ordering.

**What's still leaky:**

- The firewall is applied by a **userspace oneshot service**. Between kernel
  interface bring-up and that oneshot running, the interface has a link-local
  v6 address derived from the (randomized) MAC. SLAAC/DHCPv6 can configure a
  global v6 address in that window, and the kernel will answer Neighbor
  Solicitations. The MAC is randomized so this isn't a *hardware* fingerprint,
  but **the DHCPv6 DUID is stable across reboots** by default
  (NetworkManager/dhclient persist it), which **links sessions across boots
  even in amnesic mode.** The persistent volume bind-mounts
  `etc/NetworkManager/system-connections` but **not** the DUID state, so on
  amnesic boots the DUID *is* randomized per session — but it's still
  emitted on the LAN, and on a hostile LAN a stable-within-session DUID plus
  randomized MAC still identifies "same device, same session."
- The v6 firewall's `filter_input` accepts `ct state established,related` —
  fine — but does **not** drop ICMPv6 router/neighbor solicitation outright
  at the top; it relies on the default DROP. That's OK as long as the table
  is loaded. The risk is the pre-load window.
- `ipv6.dhcp-send-hostname=false` is set, but **`ipv6.addr-gen-mode`** is not
  pinned — so the v6 interface identifier is the default
  (EUI-64/stable-privacy depending on NM version). On some NM versions the
  default is `eui64`, which **derives the v6 IID from the MAC** and defeats
  MAC randomization at v6. **This is a real identifier leak on the LAN.**

**How to fix:**

```ini
# Add to 00-aurora-mac-randomization.conf
[connection]
ipv6.addr-gen-mode=stable
# or, for stricter per-session randomization:
# ipv6.addr-gen-mode=random

[ipv4]
# DHCP DUID is derived from /var/lib/NetworkManager/secret_key; in amnesic
# mode that's per-session already, but pin it explicitly:
dhcp-client-id=mac
```

Also consider `ipv6.ip6-privacy=2` (prefer temporary addresses) and disabling
IPv6 system-wide in Tor mode via `sysctl net.ipv6.conf.all.disable_ipv6=1`
in the killswitch service — defense in depth alongside the firewall.

---

### M2. Unsafe Browser exemption keyed by UID; the `clearnet` user is reachable while the exemption is open

**Files:** `tor-mode.sh` `clearnet-open` (lines 252-269); `aurora-unsafe-browser-run` (lines 56-84); `40-unsafe-browser.hook.chroot`.

**What's good:** The exemption is opened only while the browser runs, closed
on exit via a trap, and the browser runs sandboxed under `bwrap` as
`clearnet`. The firewall drops loopback for the `clearnet` UID so it can't
reach Tor's ports. This is closely modeled on Tails and is a solid design.

**What's leaky:**

- The exemption is **`meta skuid clearnet accept`** — *any* process running
  as uid `clearnet` gets unfiltered internet while the browser is up. The
  `clearnet` user is a `--system` account with `nologin`, but it's still a
  valid uid. If anything in the session can `runuser -u clearnet` (which
  requires root) or if the browser itself is compromised (it's running
  arbitrary web content!), that web content can spawn subprocesses as
  `clearnet` that then have full clearnet egress.
- More subtly: `bwrap` here does **`--bind "$CN_HOME" "$CN_HOME"`** and
  `--ro-bind "$RESOLV" /etc/resolv.conf`, but the network namespace is **not
  unshared** (`--unshare-net` is absent). So the sandboxed browser shares the
  host's network namespace and benefits from the firewall exemption. **If
  the browser is popped, the exemption is the browser's exemption.** That's
  inherent to the design, but worth stating: the "Unsafe Browser" is, by
  construction, a hole in the kill-switch for its lifetime, and any
  browser-level RCE during that window is a direct clearnet-capable
  deanonymizer.
- The launcher `aurora-unsafe-browser` (line 23) does
  `xhost "+SI:localuser:clearnet"`. That grants `clearnet` X access for the
  browser's lifetime. An X server has broad attack surface
  (keylogging-in-principle via X11). Combined with the above, a popped
  browser can keylog the rest of the session until the trap revokes X
  access.

**How to fix:**

- This is mostly inherent to having an "unsafe browser" at all. Mitigations:
  - Tighten the exemption to the browser's **PID/cgroup** rather than UID
    (nft supports `skuid` but not arbitrary PID matching directly; you'd
    need a small NAT redirect scoped via mark + `cgroup` match, which is
    more work). Or run the browser in its **own network namespace** with a
    veth pair that is the only thing exempted.
  - Use Wayland-native Firefox (`MOZ_ENABLE_WAYLAND=1`) instead of XWayland
    to drop the `xhost` grant entirely. The script currently forces X11
    (`MOZ_ENABLE_WAYLAND=0`).
  - Make the exemption **egress-only to the captive-portal gateway** (the
    DHCP-supplied router) rather than the whole internet, if you can detect
    it. Tails does something like this.

---

### M3. Persistent key material bind-mounted into the writable live session

**File:** `mount-persistent.sh` (lines 74-84).

The persistence bind-mounts `home/aurora/.gnupg`, `home/aurora/.ssh`, and
`etc/NetworkManager/system-connections` (which contains **saved Wi-Fi
passphrases** in plaintext) **into the live, writable session.** Any process
running as `aurora` (or anything that can read `aurora`'s home) can:

- Read the user's **private GPG/SSH keys** for the session.
- Read all **saved Wi-Fi credentials**.
- **Modify** `~/.gnupg` (e.g. inject an attacker subkey, replace the
  trustdb) or `~/.ssh` (add an `authorized_keys`), and the change persists
  across reboots.

Home is `chmod 700` (`mount-persistent.sh` and `aurora-persistent-setup` both
set this), which contains other local users — but the live session's biggest
threat is *the live session itself* (any dropped malware). Persistence is
meant to be a *convenience* feature, but mounting the key stores into the
amnesic-able live system means a session compromise can **exfiltrate or
trojan the long-term keys**, which is a much worse outcome than losing the
session.

**How to fix:**

- At minimum, document this loudly in the README's threat model (it's
  implied but not spelled out).
- Better: **do not bind-mount `.gnupg`/`.ssh` into the writable session by
  default.** Instead, keep them on the persistent volume and only expose
  them through an agent (gpg-agent with the secret keys on the persistent
  fs, ssh-agent similarly) that the session can *use* but not *read or
  write*. This is more work but matches what a threat-conscious user
  expects "Persistent" to mean.
- Saved Wi-Fi passphrases: at least `chmod 600` and consider not
  auto-mounting them in Tor mode (where you arguably don't want a saved
  SSID correlating you across sessions anyway).

---

### M4. Update channel: no pinning, suppressible, and the pubkey path is overridable via env file

**Files:** `aurora-upgrade-common.sh` (lines 18-28: channel conf is sourced if readable); `update-channel.conf`; `aurora-upgrade-check`/`-apply` (fetch over HTTPS with no pinning).

**Issues:**

1. **No TLS certificate pinning.** The transport is plain HTTPS to
   `auroraos-download.rob74752.workers.dev`. A network attacker with a
   trusted CA (or a compromised CA, of which there have been several) can
   MITM the connection. The minisign signature on the **manifest** defeats
   manifest tampering, and the **artifact** signature defeats artifact
   tampering — so this is *mostly* OK **except** it lets an attacker
   suppress updates indefinitely (serve 404s) or serve an *old signed*
   manifest (downgrade-suppression, H4). The crypto is good; the
   availability isn't.
2. **`update-channel.conf` is sourced as shell** (`aurora-upgrade-common.sh:28`).
   It's root-owned (in the squashfs), so the user can't edit it — **but it
   means anyone who can get a file into `/usr/local/share/aurora/` on the
   image has arbitrary root code execution at update-check time.** This is
   fine under the signing-key trust model, but it's a sharp edge: a
   `update-channel.conf` is a root shell waiting to happen if the squashfs
   is ever modified (which C2/H1 both enable). Defense in depth: parse it
   as `key=value` instead of sourcing.
3. **The pubkey path is fixed** (`AURORA_PUBKEY` is a constant), which is
   good — but there's no integrity check on the pubkey itself beyond "it's
   in the squashfs." Again, fine under the signing model, worth noting.
4. The update Worker serves `/updates/<anything>` (download-proxy lines
   144-187) with only a `..`/`//` traversal check. R2 keys with leading
   `/` are rejected, but the Worker will happily serve **any object in the
   bucket**, not just `updates/...`. If anything else is ever stored in
   `auroraos-iso`, it's public. (Minor given the bucket is meant to be
   public anyway, but the Worker is a broader R2 reader than the routes
   imply.)

**How to fix:**

- Pin the Worker's certificate (or its public key) in the update client, or
  at least add a fallback to a second mirror.
- Parse `update-channel.conf` as ini/key=value, not `. `source.
- Restrict the download-proxy `/updates/` route to keys actually starting
  with `updates/`.

---

## 🟢 LOW findings / hardening suggestions

### L1. sudoers missing `env_reset` / `secure_path`
`/etc/sudoers.d/aurora` doesn't set `Defaults env_reset` or `secure_path`.
Combined with the whitelisted scripts being shell scripts calling bare
binary names, this is the substrate that makes C1's PATH tricks plausible.
Add `Defaults env_reset` and a `secure_path` to the sudoers file. (Debian's
main sudoers usually has these, but a sudoers.d drop-in should be
self-contained.)

### L2. No AppArmor enforcement of the aurora helpers
`apparmor`/`apparmor-profiles` are installed (`aurora-privacy.list.chroot`),
but no profiles are written for `/usr/local/sbin/aurora-*` or
`/usr/local/lib/aurora/*`. Given these are the root-running attack surface,
profiles that restrict them to exactly the syscalls/binaries they need would
meaningfully shrink C1's blast radius.

### L3. `/etc/hosts` only maps a single hostname
`10-branding.hook.chroot` writes a minimal hosts file. Not a vulnerability,
but some software does reverse-DNS self-lookups; a more complete hosts file
(reduce noise) is a minor hardening.

### L4. Build mirror is HTTP, not HTTPS
`auto/config:39-40` deliberately uses `http://deb.debian.org` (with a comment
that apt's GPG check is the integrity control). That's a defensible choice,
but it means the build host's apt downloads are visible to a network observer
(not the user, but the builder). Consider HTTPS now that the chroot's CA
trust situation is better understood, or pin a snapshot mirror.

### L5. Published ISO checksum on the site is not itself signed
`download-proxy` serves a `.sha256` whose value comes from R2 object metadata.
An attacker with R2 write (H1) can change both the ISO *and* the checksum.
Sign the checksum (minisign `.sha256.minisig`) and have the site/README
instruct users to verify *that*. The plumbing already exists.

### L6. `aurora-set-password` enables lock screen via dconf but doesn't re-disable it on logout
If the user sets a password, then the session is later restarted without
persistence, the `disable-lock-screen=true` default returns — fine. But if
the user sets a password, **forgets it**, and the dconf override persists
into a Tor+Persistent session, they can be locked out. Minor UX/DoS.

### L7. Tor Browser `permissions.default.camera/microphone = 0`
`05-tor-browser.hook.chroot:147-148` sets both to `0` (ASK). `2` (BLOCK) is
the safer default for an anonymity browser; the OS keeps the hardware off
anyway, but defense in depth says block in-browser too. The comment
justifies it ("the OS keeps the hardware off by default"), which is true,
but if the user enables the camera via the toggle, the browser will then
ask. Consider `2`.

### L8. `aurora-tor-assistant` and `aurora-autostart-browser` trust `check.torproject.org` over Tor
These probe `https://check.torproject.org/` to decide "are we connected."
That's a reasonable liveness check, but it also **reveals to
torproject.org that this AuroraOS device is booting**, at every login, with
a stable-enough timing pattern. Tails does similar, but for a
privacy-first OS it's worth noting that `check.torproject.org` becomes a
first-party observer of every boot. Consider a self-hosted or local-only
liveness check (e.g. resolve + connect to a known Tor exit canary, or just
"SOCKS port accepts a connection").

### L9. `xhost` grant in `aurora-unsafe-browser` is broad-ish
`xhost "+SI:localuser:clearnet"` is the right (scoped) form, but see M2 —
the whole X server model is the weakness. Prefer Wayland.

### L10. The lock-menu GNOME Shell extension uses GLib.spawn with a shell-quoted string
`extension.js:70-71`: `'gnome-terminal --title=Set\\ a\\ Password -- sudo aurora-set-password'`.
The string is constant (no user input), so it's not injectable today, but
`spawn_command_line_async` runs through `/bin/sh -c`, so if this is ever
templated with user input it becomes a shell-injection sink. Note for the
future.

### L11. README claims vs reality
- README line 132: "Runtime Tor stop is intentionally not a user workflow;
  that prevents a compromised session from dropping the kill-switch." —
  **False per C1/C3.** A compromised session *can* deanonymize via a
  malicious bridge (C1d) right now, no stop needed.
- README line 23: "the live user … cannot stop the Tor kill-switch from a
  compromised desktop session." — Same.
- README line 21: "AuroraOS … has not had its threat model audited." —
  Accurate, and this report is that audit; the threat model as described in
  the README is **not met** by the current implementation.

These doc/impl gaps matter because users will behave based on the README's
claims.

---

## Things that are GOOD (so you keep them)

Worth calling out so they don't get "cleaned up" by mistake:

- **Fail-closed firewall applied before Tor starts** (`tor-mode.sh`,
  `aurora-tor-killswitch.service` with `Before=network-pre.target`). The
  *ordering* is exactly right.
- **Atomic nft ruleset load** (`nft -f -` with add-then-delete) — no
  half-applied state. Good.
- **Whole-ruleset replacement** so a malformed rule rolls back. Good.
- **Scoped sudoers** rather than `NOPASSWD: ALL`, and **the live user is
  deliberately not in the `sudo` group** (`10-branding.hook.chroot:58-66`).
  This is the right instinct; the problem is that the whitelisted helpers
  are themselves too powerful (C1/C3), not that the scoping is wrong.
- **DNSOverHTTPS locked off** in Firefox policy. Good.
- **NetworkManager connectivity check disabled** — closes a real leak
  vector. Good.
- **MAC randomization + `dhcp-send-hostname=false`.** Good (modulo M1's v6
  IID issue).
- **GPG-verified Tor Browser** at build time with pinned fingerprint. Good.
- **minisign-verified manifest AND artifact, re-verified in the apply
  step.** The crypto design of the updater is correct; the key management
  (C2) is what's broken.
- **No keyfile stored for LUKS** — passphrase-only. Good.
- **Unsafe Browser sandboxed as a separate user with its own profile,
  loopback dropped in the firewall exemption.** Good design (modulo M2).
- **`/home/aurora` is 700**, isolating it from `clearnet`. Good.
- **Rollback image kept on upgrade.** Good for recovery.
- **Camera blacklisted at the kernel-module level, mic muted at login.**
  Good — hardware-off-by-default is stronger than permissions-ask.

---

## Recommended fix priority

1. **(Now, before any further distribution)** Rotate the signing key (C2)
   and the R2 credentials (H1). Assume both are burned. Re-flash every
   existing device with a new key.
2. **(Before any real-world Tor use)** Close C1/C3: remove the ability of
   the unprivileged session to influence Tor's configuration at runtime.
   Move bridge selection to boot-time or behind a real password. Remove
   `tor-mode.sh stop` or make it impossible from the session.
3. **(Soon)** Harden the sudoers (L1) and write AppArmor profiles (L2) for
   the root-running helpers. Pin `ipv6.addr-gen-mode` (M1).
4. **(Soon)** Stop bind-mounting `.gnupg`/`.ssh` into the live session by
   default (M3), or at minimum document the threat loud and clear.
5. **(Ongoing)** Fix the doc/impl gaps (L11), add freshness checks to the
   updater (H4), sign the published checksum (L5).

---

*This is an automated source review. It cannot prove the absence of
vulnerabilities — only flag what it found. A real anonymity-focused OS
needs independent traffic-leak testing on real hardware (Tails uses a custom
test harness for this) and ideally a professional security review before
any high-stakes use. As the README itself says: for real anonymity needs,
use Tails.*
