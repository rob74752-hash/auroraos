# Security Policy

AuroraOS is a privacy- and anonymity-focused live OS. Security reports are
welcome and taken seriously — but please read the scope note below first.

## Project status & scope

AuroraOS is an **independent, unaudited personal project**, not a certified
security product. It borrows ideas from [Tails](https://tails.net) (amnesia,
Tor routing, signed updates) but has **not** undergone professional review or
real-hardware traffic-leak testing. For genuinely high-risk anonymity needs,
use Tails.

A historical, automated source audit (with several findings and their
remediation status) is published, sanitized, at
[`docs/SECURITY-AUDIT.md`](docs/SECURITY-AUDIT.md).

## Supported versions

Only the latest release receives security fixes. Updates are delivered as a
**minisign-signed** full system image (see the FAQ on the website); older
images must be re-flashed.

| Version | Supported |
|---------|-----------|
| v0.55 (current) | ✅ |
| < v0.55 | ❌ (re-flash to the latest) |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Use GitHub's private vulnerability reporting:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe the issue, the affected version, and a reproduction if you have one.

This keeps the report private until a fix is available. You'll get a response
through the same private thread.

### What's most valuable to report

- Any path that lets an **unprivileged live session disable the Tor
  kill-switch** or leak the real IP without a reboot.
- **Update-trust** weaknesses (signature bypass, downgrade, channel tampering).
- **Persistence / LUKS** weaknesses that expose key material.
- Build-time supply-chain issues (e.g. a hook that fetches something
  unverified).

### Out of scope / known limitations

- Malware **already running as the live `aurora` user** can configure Tor
  bridges (the Tails trust model — documented, not a bug).
- The "Unsafe Browser" is, by design, a clearnet hole for its lifetime.
- No certificate pinning on the update channel (signatures are the integrity
  control); see `docs/SECURITY-AUDIT.md`.

## Credential / key handling

This repository ships **no** secrets. The update **signing private key**, the
R2 credentials (`.env`), and the raw internal audit are intentionally
gitignored and kept offline. If you believe a secret was ever committed, report
it privately as above.
