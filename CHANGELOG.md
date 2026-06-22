# AuroraOS changelog

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
