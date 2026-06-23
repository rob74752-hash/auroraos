# AuroraOS changelog

## v0.58 — 2026-06-22

**Fixes**
- **Tor bridges from a QR code / "copy bridges" button now work.** The Tor bridges
  service hands out bridges as a JSON array — `["webtunnel […]:443 … ver=0.0.4", …]`
  — and AuroraOS was feeding that raw to the validator, which (correctly) rejected
  the `[`, `]`, and `"` characters as not part of a bridge line. The connection
  assistant now parses that JSON array itself (for both the webcam QR scan and
  pasted text), extracting clean bridge lines while preserving the `[...]` of an
  IPv6 bridge. Tor's own parser already accepted the underlying lines.
- **Unsafe Browser loads its profile.** It runs as the sandboxed `clearnet` user
  (a different uid), but the Tor Browser data directory is owner-only (the v0.56
  privacy lockdown), so Tor Browser died with "Your Tor Browser profile cannot be
  loaded. It may be missing or inaccessible." The Unsafe Browser now gets its own
  writable copy of that data dir, bind-mounted only inside its sandbox — aurora's
  real Tor Browser data stays private and untouched.
- **Clipboard copy of the bridges URL works on GNOME.** The assistant tested only
  whether `wl-copy` *exists*, then ran it — but on GNOME `wl-copy` exists yet fails
  (its compositor protocol is unsupported), and the `if/elif` never fell through to
  `xclip`. It now tries each tool until one succeeds, so the "copied to clipboard"
  message actually appears.

## v0.57 — 2026-06-22

**Fixes**
- **Unsafe Browser now actually opens a window.** With v0.56's execute-permission
  fix in place, the browser got far enough to crash during graphics init
  (`RenderCompositorSWGL failed mapping default framebuffer`): the bubblewrap
  sandbox built a fresh `/dev` with **no `/dev/shm`**, and Firefox needs
  `/dev/shm` for its software compositor's framebuffers. The sandbox now mounts a
  private `/dev/shm` tmpfs.
- **Tor bridges with a `url=` value are accepted again** (webtunnel / snowflake).
  The bridge-line validator's allowed-character set for arguments didn't include
  `/`, so every bridge carrying a `url=https://…` (i.e. essentially every
  webtunnel and snowflake bridge) was rejected as "invalid" — which is why *every*
  bridge appeared to fail. The set now permits URL punctuation. The validator also
  now accepts a leading `Bridge ` keyword and hostname-based (non-IP) bridges.
  Injection protection and `tor --verify-config` as the final authority are
  unchanged.
- **Bridge flow announces the clipboard copy.** When the bridges website address
  is copied to the clipboard, the dialog now says so (only when the copy actually
  succeeded), instead of copying silently.

## v0.56 — 2026-06-22

**Fixes**
- **Unsafe Browser now launches.** The Tor Project ships the Tor Browser bundle
  mode `0700`, so the sandboxed `clearnet` user that runs the Unsafe Browser
  could not execute Firefox (`bwrap: execvp … Permission denied`) — clicking
  "Start Unsafe Browser" did nothing. The program tree is now made
  world-executable, while the Tor Browser profile dir is re-locked to its owner
  so the non-anonymous clearnet user still can't read it. The launcher also
  nudges XWayland up and now shows a real error dialog instead of failing
  silently.
- **Updater messaging / persistence honesty.** A read-only (balenaEtcher/dd)
  stick can't update in place — the message now says this is *expected* and
  warns to **back up Persistent before re-flashing**, because re-flashing
  rewrites the partition table and can detach the encrypted Persistent
  partition. Corrected the misleading README claim that persistence "carries
  over" a re-flash, and added a backup procedure.

## v0.55 — 2026-06-21

**New**
- **Scan a QR code to configure a bridge.** In *Connect to Tor → Configure a
  bridge* you can now scan the QR code from the Tor bridges email
  (`bridges@torproject.org`) with the webcam instead of typing the bridge line.
  The camera is enabled only for the scan and disabled again immediately
  afterwards, and the decoded lines go through the same strict validator
  (`aurora-tor-set-bridges` + `tor --verify-config`) as a pasted line — a QR
  carries no extra trust. Adds the `zbar-tools` package.

**Fixes & improvements**
- **Wizard:** removed the "Connect your online accounts" page from the first-boot
  setup wizard — signing into a personal account is inherently de-anonymising.
- **Tor assistant timing:** the "Connect to Tor" assistant now waits for the
  setup wizard to finish before appearing, instead of popping up on top of it.
- **Set a Password:** a mismatch no longer slams the terminal shut (which looked
  like a crash) — it explains "the two passwords did not match" and re-prompts.
  Also fixed the app-grid launcher's non-portable `read -p`.
- **Lock button:** clicking *Lock* with no password set now sets a password,
  clearly confirms success, pauses so you can read it, and **then** locks the
  screen. The app-grid "Set a Password" still does not auto-lock.
- **Stray dialog:** purged the PackageKit update viewer (`gnome-packagekit`) and
  masked its background service, removing the unrelated "All updates are
  complete." dialog. AuroraOS only updates via its own signed image-swap.

## v0.5 — 2026-06-21

- Initial public release.
