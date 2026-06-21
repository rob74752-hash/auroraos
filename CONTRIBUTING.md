# Contributing to AuroraOS

Thanks for your interest! AuroraOS is a Debian `live-build` distribution in the
Tails tradition. Contributions — bug fixes, hardening, app curation, docs — are
welcome.

> Security issues: **do not** open a public issue. See
> [`SECURITY.md`](SECURITY.md) for private reporting.

## Repository layout

| Path | What it is |
|------|------------|
| `auroraos/` | The live-build config tree: `auto/config`, package lists, `config/hooks/`, and `config/includes.chroot/` (the files baked into the image). |
| `build.sh` | One-command build orchestrator (runs in WSL2/Ubuntu). |
| `release.sh` | Builds + minisign-signs the update channel and uploads it. |
| `r2-upload.py` | Uploads the ISO to Cloudflare R2. |
| `download-proxy/` | The Cloudflare Worker that serves the ISO + update channel. |
| `website/` | The static site (Cloudflare Pages). |
| `docs/` | Sanitized security audit and other docs. |

## Building

The build must run inside **WSL2 / Ubuntu** (it targets a native Linux
filesystem; building on `/mnt/c` is slow and breaks on device nodes):

```sh
./build.sh           # full build (first run downloads ~2–3 GB of debs)
./build.sh config    # validate the live-build config only
./build.sh clean     # wipe the build tree and start fresh
```

Notes for the build host:

- Needs `live-build`, `debootstrap`, and standard build tooling.
- Modern Ubuntu defaults to **Rust "uutils" coreutils**, whose `chroot`,
  `cp -a`, and `mktemp -d` misbehave for this workflow. `build.sh` and
  `release.sh` auto-detect this and shim **GNU coreutils** onto `PATH`. If you
  hit odd "empty path" / "chroot failed" errors, install GNU coreutils.
- The output ISO and its `.sha256` land in `build-output/` (gitignored).

## Conventions

- **Line endings: LF only.** Enforced by `.gitattributes` (`* text=auto
  eol=lf`). Shell scripts with CRLF will not run in the image.
- **Shell scripts** target POSIX `sh` (the in-image helpers use `#!/bin/sh`).
  Validate with `sh -n <file>` before committing.
- **nftables** rulesets should pass `nft -c -f <file>`.
- **Python** is for build-host tooling only; keep it `python3` + stdlib/boto3.
- Match the surrounding style: the hooks are heavily commented explaining *why*
  a thing is done (especially security-relevant choices) — keep that up.

## Never commit secrets

The following are gitignored and must stay local/offline — do not add them:

- `.env` (Cloudflare R2 credentials)
- `signing/` and any `*.key` (the update signing private key)
- the **raw** `SECURITY-AUDIT.md` at the repo root (the published copy lives at
  `docs/SECURITY-AUDIT.md`, with credentials redacted)
- `build-output/` (ISOs, logs)

If you're unsure whether something is sensitive, ask in the PR before adding it.

## Submitting changes

1. Fork and create a branch off `main`.
2. Make focused commits with clear messages.
3. If you changed an in-image script or hook, note how you tested it (a build,
   `sh -n`, `nft -c`, or a real boot — boot-testing is especially valued since
   most maintainer testing is static).
4. Open a pull request describing the change and its security implications, if
   any.

## Licensing

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).
