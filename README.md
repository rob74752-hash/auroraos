# AuroraOS

**A private operating system on a stick.** AuroraOS is a Tails-inspired, bootable-from-USB Linux distribution that boots into the mode you choose at startup:

| Mode | What it does |
|------|--------------|
| **Amnesic** | Runs entirely in RAM. The moment you shut down, everything is wiped. Leaves no trace on the host computer (the Tails philosophy). |
| **Persistent** | Your files, settings, and apps are saved to an encrypted partition on the USB and survive reboot. A real daily-use OS you carry in your pocket. |
| **Tor** | Amnesic session plus Tor routing. Forces **all** network traffic through the Tor network, with a firewall kill-switch that blocks anything that can't be torified. |
| **Persistent + Tor** | Mounts encrypted persistence and routes traffic through Tor in the same session. Useful, but less forgetful by definition. |

It is built on **Debian (bookworm)** with a **GNOME** desktop — the same foundation Tails itself uses.

---

## ⚠️ Honest expectations (read this first)

This project was built end-to-end and the ISO assembles correctly, but:

- **I (the assistant) cannot test that it boots on your real hardware.** Only you can flash the USB and try it. I'll be explicit about what's verified vs. assumed throughout.
- AuroraOS is a **personal/learning project**, not a hardened security product. For genuinely high-risk anonymity needs, use the real **Tails** (https://tails.net). AuroraOS borrows Tails' *ideas* but has not had its threat model audited.
- Tor mode uses a fail-closed transparent proxy + kill switch: the firewall is applied **before** Tor starts, only the `debian-tor` daemon may reach the network directly, **IPv6 is dropped** entirely, and **non-DNS UDP/ICMP is dropped** (so it can't leak past Tor). DNS resolves over Tor. This closes the common leak vectors, but it has **not** been independently traffic-leak audited on real hardware — treat it as "much better than nothing," not "guaranteed anonymous." For high-stakes anonymity use Tails.
- The live user has **scoped passwordless sudo**, not a blanket root shell. It can run the Aurora helpers needed for persistence, password setup, and signed updates, but it cannot stop the Tor kill-switch from a compromised desktop session. To leave Tor mode, reboot into a non-Tor mode.
- Updates and the bundled Tor Browser are **cryptographically verified** (signed manifests/artifacts; the Tor Browser tarball is GPG-checked against the pinned Tor Project key at build time). An unsigned or tampered update/browser is refused, not installed.

---

## Quick start

### 1. Get the ISO

**Option A — Download the prebuilt image (easiest).**

The latest signed release is hosted on the project website — no build required:

- **Website:** https://auroraos.pages.dev → click **Download ISO**
- **Direct link:** https://auroraos-download.rob74752.workers.dev/auroraos-0.1-amd64.iso (~2.4 GB; your browser saves it as `auroraos-<version>-amd64.iso`)
- **GitHub release:** https://github.com/rob74752-hash/auroraos/releases/latest (release notes + the `.sha256` checksum)

**Verify the download before flashing** against the SHA-256 published on the website and in the GitHub release:

```bash
sha256sum auroraos-*-amd64.iso                       # Linux / macOS
# Windows PowerShell:
#   Get-FileHash auroraos-*-amd64.iso -Algorithm SHA256
```

Then jump to **2. Flash to a USB stick** below.

**Option B — Build it yourself.**

Requires **WSL2 + Ubuntu** on Windows (or any Debian/Ubuntu Linux). One-time setup of build tools:

```bash
# Inside Ubuntu:
sudo apt-get update
sudo apt-get install -y live-build squashfs-tools grub-pc-bin grub-efi-amd64-bin \
                        xorriso dosfstools parted debootstrap
```

Then, from the project root (in WSL):

```bash
./build.sh
```

- **First run downloads ~2–3 GB** of packages and takes **30–90 minutes**.
- The finished ISO lands in `build-output/` along with a `.sha256` checksum.
- Re-running `./build.sh` reuses the apt cache and is much faster.
- `./build.sh clean` wipes the build tree to start over.
- `./build.sh config` runs only the config step (fast sanity check).

> **Why the build copies files to `/home/user/auroraos-build`:** live-build needs a real Linux filesystem (ext4). Building on the Windows mount (`/mnt/c`) is ~10× slower and breaks on symlinks/device nodes. `build.sh` handles the copy automatically — you keep editing files in your Windows folder.

### 2. Flash to a USB stick

You need a **USB drive of at least 8 GB** (16 GB+ recommended if you'll use Persistent mode). Flashing **wipes the entire USB**.

**Option A — Rufus (Windows, recommended):**
1. Download Rufus from https://rufus.ie
2. Select your USB drive
3. Select the AuroraOS ISO (your download, or from `build-output/` if you built it)
4. Partition scheme: **GPT**, target system: **UEFI (non-CSM)** (or MBR/BIOS for older PCs)
5. Click **Start**. If prompted about hybrid ISO / DD mode, choose **DD mode**.

**Option B — balenaEtcher (Windows/macOS/Linux):**
1. Download from https://etcher.balena.io
2. Flash from file → pick the ISO → select the USB → Flash.

**Option C — from Linux/WSL directly (find your device letter first!):**
```bash
# Find the USB device (e.g. /dev/sdX) — be VERY careful, wrong device = data loss:
lsblk
sudo cp build-output/auroraos-*.iso /dev/sdX bs=4M status=progress && sync
```

### 3. Boot it

1. Shut down the host PC. Plug in the USB.
2. Power on and enter the **boot menu** (usually F12, F10, Esc, or F2 — varies by manufacturer). Select the USB.
3. You'll see the **AuroraOS boot menu**. Pick a mode:
   - **Amnesic** (default) — wipes on shutdown, leaves no trace
   - **Persistent** — saves files to an encrypted partition
   - **Tor** — anonymous routing, no saved files
   - **Persistent + Tor** — encrypted saved files plus Tor routing
   - **Failsafe** — verbose, for troubleshooting
4. GNOME desktop loads. Default user is **`aurora`** (auto-login, no password).
   The account has **no login password** (a baked-in password would be a
   universal credential on every device). Screen auto-lock is disabled so the
   live session cannot lock you out. If you want locking, open **Set a Password**
   from the app grid first.

### 4. Enable Persistent storage (one-time, optional)

Persistent mode only saves files **after** you've created the encrypted volume. Boot once (any mode), open a terminal, and run:

```bash
sudo aurora-persistent-setup
```

This carves out a new partition on the USB and formats it as a **LUKS2** container (`AES-256-XTS`, key derived from your passphrase with **Argon2id**). The script **prompts you to choose a passphrase** — choose a long, random one (16+ chars). **There is no recovery if you forget it.**

On the next **Persistent-mode** boot, you'll be prompted for that passphrase at the console to unlock the volume. Once unlocked, your `~/Documents`, `~/Downloads`, app settings, and saved Wi-Fi networks are bind-mounted back over the live system and survive reboot.

> **Passphrase strength is your only line of defense.** A strong passphrase makes the volume practically unbreakable; a weak one can be brute-forced offline. This caveat applies to all disk encryption (including Tails).

---

## Using the boot modes

### Persistent mode
- Choose **Persistent** at the boot menu.
- These survive reboot: `~/Documents`, `~/Downloads`, `~/Persistent`, app
  settings (`~/.config`, `~/.local`), and your keys (`~/.gnupg`, `~/.ssh`).
- Saved Wi-Fi networks persist.
- The volume is **LUKS2 / AES-256-XTS** with an **Argon2id** passphrase KDF — no
  key is stored anywhere; your passphrase is the only key.
- Run `aurora-status` in a terminal to confirm persistence is active.

### Amnesic mode
- Choose **Amnesic** at the boot menu (or do nothing — it's the safe default).
- The whole OS runs from RAM. **Shut down → everything is gone.**
- Nothing is written to the host computer's disk. Pull the USB and no trace remains.
- ⚠️ Don't save anything you can't afford to lose — there is no undo.

### Tor mode
- Choose **Tor** at the boot menu.
- This is an **amnesic** Tor session: files are not saved unless you chose **Persistent + Tor** instead.
- On boot, the Tor daemon starts and a firewall kill-switch is applied: **all non-Tor traffic is dropped.**
- Use the **Tor Browser** (`tor-browser` command, or find it in the app grid) for web access. In Tor mode it is launched for you.
- Any SOCKS-aware app can use the proxy at `127.0.0.1:9050`.
- To leave Tor mode, **reboot** and choose Amnesic or Persistent. Runtime Tor stop is intentionally not a user workflow; that prevents a compromised session from dropping the kill-switch and exposing your real IP.
- Verify you're anonymous: open Tor Browser → it shows "Congratulations" from `check.torproject.org`.

#### Using a bridge (when Tor is blocked/censored)
If Tor can't connect on your network, use a **bridge** — an unlisted entry relay that hides Tor traffic. AuroraOS configures bridges the **Tails way**:

1. **Get a bridge line** (on another connection/device), e.g. from `https://bridges.torproject.org`, or email `bridges@torproject.org` from a Gmail/Riseup address. The email reply contains your bridge lines **and a QR code** that encodes them. A line looks like:
   `obfs4 192.0.2.1:443 <FINGERPRINT> cert=... iat-mode=0`
2. Open **Connect to Tor** from the app grid and choose **Configure a bridge**.
3. Pick how to enter the line(s):
   - **Scan a QR code with the webcam** (Tails-style) — hold the QR code from the bridges email up to the camera. AuroraOS turns the webcam **on only for the scan** and **off again** the instant a code is read (the camera is disabled by default). The decoded lines are dropped into the box for you to review.
   - **Paste bridge line(s) as text** — type or paste them in.
4. Apply. AuroraOS strictly validates each line and runs `tor --verify-config` before installing anything — a malformed or rejected line changes nothing. (Scanning is just another way to enter a line; the *same* validation runs either way, so a QR carries no extra trust.)
5. Connect. The kill-switch stays up the whole time, so nothing leaks while you configure.
6. **Bridges are amnesic** — gone on reboot, just like Tails. Keep your lines in a text file in `~/Persistent` (or `~/Documents`) and re-enter them next session.

> **Threat-model note:** configuring a bridge from the session means AuroraOS trusts *your session* to pick Tor's entry relay — the same stance Tails takes. The kill-switch still prevents leaks from misconfigured apps; it does not claim to stop malware already running as you from choosing a bad bridge. See [`docs/SECURITY-AUDIT.md`](docs/SECURITY-AUDIT.md).

### Persistent + Tor mode
- Choose **Persistent + Tor** at the boot menu.
- You'll unlock the encrypted Persistent volume, then AuroraOS applies the Tor kill-switch.
- Your files and app settings survive reboot, but your network traffic is routed through Tor.
- This mode trades some amnesia for convenience. Anything saved to persistence is deliberately kept.

### Screen lock and passwords
- The live `aurora` user starts with **no password**, and automatic screen locking is disabled.
- If you want to use screen lock, open **Set a Password** from the app grid or run:

```bash
sudo aurora-set-password
```

After that, your password can unlock the screen for the current session.

---

## AuroraOS commands

| Command | What it does |
|---------|--------------|
| `aurora-status` | Show current boot mode, persistence, and Tor kill-switch state |
| `aurora-tor status` | Show whether the Tor daemon and kill-switch are active |
| `sudo aurora-persistent-setup` | Create the encrypted Persistent volume (one-time) |
| `sudo aurora-set-password` | Set a password for the live user so screen lock can be used |
| `aurora-upgrade` | Check for and install a cryptographically-signed update |

---

## Updating AuroraOS

AuroraOS updates the **Tails way** — not with `apt upgrade`, but by replacing the
whole system image with a **cryptographically signed** one. You click a button (or
run `aurora-upgrade`); the system fetches a signed manifest, **verifies its
signature** against a key baked into the image, downloads the new system image,
**verifies its signature and SHA-256**, and atomically swaps it on the USB —
keeping the previous image as a rollback. In Tor mode the download goes over Tor.

**As a user:**
- An **"AuroraOS Upgrader"** notification appears at login when an update exists.
- Open **AuroraOS Upgrader** (app grid) and click **Install update**, or run
  `aurora-upgrade` in a terminal. Reboot to use the new version.
- The signature is the trust anchor: an update that isn't signed by the AuroraOS
  Update key is **refused**, even over HTTPS. Downgrades are refused too.
- In-place upgrades require a **writable** install. A plain dd-flashed ISO is
  read-only, so the upgrader will tell you to re-flash the latest ISO instead
  (your encrypted Persistent partition is separate and carries over).

**As the publisher (you, if you host your own channel):**

```bash
# 1. One-time: generate YOUR signing keypair (private key stays secret/offline;
#    the public key is auto-copied into the image source so builds trust it).
./release.sh keygen

# 2. Build the ISO so the public key is baked in.
./build.sh

# 3. Publish a signed update channel to R2 (needs R2_ACCESS_KEY_ID /
#    R2_SECRET_ACCESS_KEY in your environment):
./release.sh publish
```

> Until you run `release.sh keygen`, the image ships a **placeholder** key and
> the updater is **disabled** (fails closed) — it will never fetch or apply an
> unauthenticated update. Keep `signing/auroraos-update.key` secret; anyone with
> it can sign updates your devices will install. It is in `.gitignore`.

---

## How it works (architecture)

```
auroraos/
├── auto/config                          # live-build master config (the build "recipe")
├── config/
│   ├── package-lists/                   # what gets installed
│   │   ├── aurora-core.list.chroot      # kernel, firmware, base tools
│   │   ├── aurora-desktop.list.chroot   # GNOME, LibreOffice, GIMP, Firefox, codecs
│   │   └── aurora-privacy.list.chroot   # Tor, KeePassXC, MAT2, firewall
│   ├── hooks/normal/                    # scripts run during build
│   │   ├── 05-tor-browser.hook.chroot   # GPG-verified Tor Browser install
│   │   ├── 10-branding.hook.chroot      # hostname, user, os-release, version
│   │   ├── 20-boot-menu.hook.binary     # generates the Amnesic/Persistent/Tor/Persistent+Tor menu
│   │   └── 90-finalize-wiring.hook.chroot  # systemd units, autologin, sudo
│   └── includes.chroot/                 # files overlaid onto the live system
│       ├── usr/local/lib/aurora/        # boot-mode.sh, mount-persistent.sh, tor-mode.sh
│       ├── usr/local/lib/aurora/upgrade/  # signed-update check/apply backend
│       ├── usr/local/bin/aurora-*       # user-facing commands + Upgrader GUI
│       ├── usr/local/share/aurora/      # update public key + channel config
│       └── etc/tor/aurora-torrc.append  # Tor transparent-proxy config
├── build.sh                             # orchestrator: sync → config → build → copy ISO
└── release.sh                           # keygen + sign + publish the update channel
```

**The boot-mode system** is the heart of AuroraOS. The boot menu passes kernel tokens (`aurora.persistent`, `aurora.amnesic`, and/or `aurora.tor`). A systemd service runs `boot-mode.sh` early in boot, which reads the tokens from `/proc/cmdline`, writes the effective mode to `/run/aurora-mode`, and triggers mode-specific setup (mount the persistent volume, apply the Tor firewall, etc.). Persistence and Tor are independent flags, so **Persistent + Tor** is just `aurora.persistent aurora.tor`.

---

## Troubleshooting

**"Need root privileges" during build**
→ `lb build` must run as root. `build.sh` already calls it via `sudo`. If you're invoking `lb build` manually, prefix it with `sudo`.

**Build fails / hangs on package download**
→ Usually a network or mirror issue. Re-run `./build.sh` (it resumes from cache). For a truly clean start: `./build.sh clean && ./build.sh`.

**USB won't boot**
- Make sure you selected the USB in the **boot menu** (F12/F10/Esc), not just plugged it in.
- AuroraOS includes the UEFI Secure Boot path, but firmware is messy. If boot fails, test with **Secure Boot disabled**, then try both **UEFI** and **Legacy/CSM** modes.
- On very new PCs, you may need to disable **Fast Boot**.
- Try the **Failsafe** boot entry (no graphics, verbose) — it shows kernel messages that pinpoint the problem.

**The custom boot menu (AuroraOS mode choices) doesn't appear**
- If you only see a generic "Live" / "Installer" menu instead of the AuroraOS modes, the custom entries weren't merged into the image. As a workaround you can pass the mode token manually at the boot prompt: type `e` to edit an entry, append `aurora.persistent`, `aurora.amnesic`, `aurora.tor`, or `aurora.persistent aurora.tor` to the `linux` line, and press F10/Ctrl-X to boot.

**Black screen after GRUB / display issues**
→ Common with NVIDIA/Intel hybrid GPUs. Boot **Failsafe** mode, then from the desktop install the matching driver (`sudo apt install nvidia-driver` or similar) — note this won't persist unless you're in Persistent mode.

**Tor Browser not installed**
→ The build hook downloads it from torproject.org and verifies the Tor Project signature; if that failed at build time, the ISO still has the `tor` proxy (SOCKS on `127.0.0.1:9050`). Install Tor Browser manually from https://torproject.org, or point a SOCKS-aware app at the proxy.

**Persistent mode shows "running amnesic this session"**
→ You haven't run `sudo aurora-persistent-setup` yet, or the USB was reflashed. Run the setup tool once to create the encrypted volume.

**Can't connect to Wi-Fi in Tor mode**
→ Expected until Tor establishes a circuit (can take 30–60s). The kill switch blocks all traffic until then. Run `aurora-tor status` to check. If it never connects, your network may block Tor — use the **Connect to Tor** assistant's "Configure a bridge" option and either **scan the QR code** from the bridges email or **paste a bridge line** (see *Using a bridge* above). Don't edit `/etc/tor/torrc` by hand; the assistant validates and verifies each line through `aurora-tor-set-bridges`.

---

## Advanced usage

**Persistent + Tor together:** Choose **Persistent + Tor** at the boot menu. Your saved files persist *and* your traffic is torified for that session. (Be aware this weakens the amnesia property of Tor mode — see the threat-model caveat above.)

**Changing the default boot mode:** The boot menu is generated at build time by `auroraos/config/hooks/normal/20-boot-menu.hook.binary` (it patches the real syslinux/GRUB configs). Edit the entries / `set default` there, and/or change `aurora.amnesic` to another mode in the `--bootappend-live` line of `auroraos/auto/config`, then rebuild.

**Adding packages:** Append package names to the relevant `*.list.chroot` file under `config/package-lists/`, then rebuild.

**Verifying the ISO integrity:** Compare against the `.sha256` file:
```bash
cd build-output
sha256sum -c auroraos-*.iso.sha256
```

---

## Project layout / where to change things

- Want a different desktop (KDE, XFCE)? Edit `aurora-desktop.list.chroot`.
- Want different default apps? Same file.
- Want to change branding (name, hostname, MOTD)? Edit `10-branding.hook.chroot`.
- Want different boot-menu entries? Edit `20-boot-menu.hook.binary`.
- Want to change what persists? Edit the bind-mount list in `mount-persistent.sh`.

---

## License & attribution

AuroraOS is a project that assembles free/open-source software (Debian, GNOME, Tor, etc.) using Debian's `live-build`. Each component retains its own license. The AuroraOS-specific build configuration in this repo is provided as-is for personal and educational use.

This project is **not affiliated with Tails**. It borrows Tails' excellent ideas (amnesia, Tor routing) but is an independent, unaudited personal OS. For real high-stakes anonymity, use Tails: https://tails.net.
