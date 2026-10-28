<h1 align="center">Timecrate</h1>

<p align="center">
  <strong>The part of a machine you cannot reinstall, encrypted, signed and off-site — and proof that it restores.</strong><br>
  A disaster-recovery backup for Ubuntu that ships configuration, secrets and hand-tuned state to any rclone remote as one small signed archive, and checks on a schedule that the archive really brings a machine back.
</p>

<p align="center">
  <a href="https://github.com/spencernorton/timecrate/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/spencernorton/timecrate/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/spencernorton/timecrate/tags"><img alt="Latest release" src="https://img.shields.io/github/v/tag/spencercnorton/timecrate?label=release&sort=semver"></a>
  <a href="#install"><img alt="Install on Ubuntu 26.04" src="https://img.shields.io/badge/install-Ubuntu%2026.04-e95420.svg"></a>
  <a href="LICENSE"><img alt="Licence" src="https://img.shields.io/badge/licence-GPL--2.0--or--later-blue.svg"></a>
  <a href="https://buy.stripe.com/8x26oH2U44f65TRe574wM04"><img alt="Donate" src="https://img.shields.io/badge/donate-Stripe-635bff.svg?logo=stripe&logoColor=white"></a>
</p>

Timecrate does not image a disk. It backs up the slice of a machine that a package manager cannot
give back — `/etc`, your keys and dotfiles, settings, documents, the software under `/usr/local` —
usually a few hundred megabytes, together with a manifest of everything that *can* be reinstalled.
A rebuilt machine gets its packages from the manifest and the rest from the kit.

## What it does

**One small kit a night.** `tar` over the paths you list, `zstd` with a long window on every core,
then GnuPG: encrypted to your key with AES-256 and signed by a separate key. The kit goes to any
rclone remote — Dropbox, Google Drive, B2, S3, SFTP, a local disk — and, if you want 3-2-1, is
mirrored to a second provider.

**Restores check before they write.** Every path that extracts a kit verifies its signature before
a single byte lands on disk, so someone with write access to your remote cannot plant an archive
that a restore would unpack as root. Restoring a kit older than the newest one recorded needs
`--force`, because an old kit carries a perfectly valid signature.

**Recovery needs nothing from this project.** A kit opens with `gpg`, `zstd` and `tar`, and the
steps are on a printable sheet together with the key ([BREAK-GLASS.md](docs/BREAK-GLASS.md)).
Since 3.1.0 the sheet also downloads as a PDF, and Google Drive is a direct sign-in
destination (`remote connect --provider drive`, with the folder picked in the window).

**Post-quantum hybrid kits (3.1.0).** With `TIMECRATE_CRYPTO=hybrid`, each new kit is the
ordinary signed GPG kit wrapped in an ML-KEM-1024 envelope (OpenSSL), so breaking RSA-4096
one day still does not open it. Opening a hybrid kit needs both secret keys; both are on the
escrow sheet, and classic kits — including every kit already on a remote — stay readable.

**It proves itself on a schedule.** A monthly drill imports only the escrowed key into an empty
keyring and decrypts a real kit from the remote, then authenticates every other kit there. A
quarterly capstone rebuilds a machine from a kit inside a real virtual machine — packages, desktop
settings, a reboot — where [multipass](https://canonical.com/multipass) is installed.

**It refuses to fail quietly.** A kit too big or too small for its size rails is not shipped; a kit
missing a manifest the restore needs raises an alert; a remote that lost kits, or went back in time,
raises one the same night. `timecrate coverage` shows what no kit contains. Alerts go to the system
journal, and to any command you name.

**Retention keeps history.** The newest 14 kits, plus the first kit of each of the last 12 months
and of each of the last 3 years, per remote.

## Install

### Ubuntu 26.04 — the release packages

Download `timecrate_*_all.deb`, `timecrate-gui_*_all.deb` and `SHA256SUMS.txt` from the
[latest release](https://github.com/spencernorton/timecrate/releases/latest), then:

```bash
sha256sum --check --ignore-missing SHA256SUMS.txt
sudo apt install ./timecrate_*_all.deb ./timecrate-gui_*_all.deb
```

`timecrate-gui` is the optional desktop window; a server needs only `timecrate`. Installing
enables the daily backup, the monthly drill and the quarterly capstone timers, and an upgrade
keeps them as they are.

Upgrading a machine that runs the packages from before 3.0.0? Follow
[MIGRATING.md](docs/MIGRATING.md): the kits already on your remote are read as they are.

## Set it up

1. **Say whose machine it is.** In `/etc/timecrate/timecrate.conf` set `TIMECRATE_USER` to the
   account whose home is backed up, and look over `/etc/timecrate/include` — the default is a
   starting point, not a survey of your machine. `sudo timecrate backup --dry-run` shows what a kit
   would hold, and `timecrate coverage` what nothing covers.
2. **Connect a remote**, as that user: `timecrate remote connect` (Dropbox by default; any rclone
   backend with `--provider`), then `timecrate remote set-path <remote:path>`.
3. **Make the keys**, as that user: `timecrate init`. Then escrow the secret key **off this machine**
   — `timecrate escrow-doc` writes a printable sheet with a QR code, `timecrate export-key` a file.
   It is deliberately not in the backups: without an escrowed copy, the kits are unrecoverable.
4. **Prove it**: `sudo timecrate backup`, then `sudo timecrate recovery-drill`, then
   `sudo timecrate escrow-confirm`.
5. **Hear about failures**: set `TIMECRATE_ALERT_CMD` (below) and run `sudo timecrate alerts test`.

The window (`timecrate-gui`) does all of this too, and every button runs the same command-line
tool, so a machine without a desktop loses nothing.

## Alerts

A failed backup, drill or capstone is always written to the journal. To be told anywhere else, put
an executable in `TIMECRATE_ALERT_CMD` (in `/etc/timecrate/timecrate.conf`, or in the root-only
`/etc/timecrate.env` if it needs a token). Every alert runs it as

```
<command> <severity> <title> <key>        # the message on standard input
```

with severity `critical`, `warn` or `info`, and a key naming the kind of alert (`backup`, `remote`,
`drill`, `capstone`, `overnight`, `unit-<name>`, `test`) so a receiver can update one message
instead of adding another. Exit 0 means delivered. For example, to mail yourself:

```sh
#!/bin/sh
mail -s "[$1] $2" you@example.com
```

`TIMECRATE_ESCROW_KEY_CMD` works the same way for the escrowed key: a command that prints it from
your password manager or secret store lets the drill prove the off-box copy, and lets
`timecrate harden` check it before removing the on-box one.

## Documentation

- [docs/RESTORE.md](docs/RESTORE.md): rebuilding a machine from a kit, in order
- [docs/BREAK-GLASS.md](docs/BREAK-GLASS.md): recovery with nothing but gpg, zstd and tar
- [docs/MIGRATING.md](docs/MIGRATING.md): moving from the packages before 3.0.0
- `man timecrate`, `man timecrate-gui`: every command, setting and file
- [CHANGELOG.md](CHANGELOG.md): one entry per release
- [NOTICE](NOTICE): provenance and licence

## Where your data lives

| Path | Purpose |
|---|---|
| `/etc/timecrate/timecrate.conf` | Settings (world-readable: never credentials) |
| `/etc/timecrate/include`, `/etc/timecrate/exclude` | What goes into a kit, and what is pruned from it |
| `/etc/timecrate.env` | Root-only secrets, mode 0600, for your alert or escrow-key command |
| `~/.config/timecrate/` | The keyring, the escrow file and the pinned signing fingerprint — never in a kit |
| `~/.config/rclone/rclone.conf` | rclone's own configuration and token — never in a kit |
| `~/.local/state/timecrate/` | History, status and the anti-rollback anchor |
| `/var/lib/timecrate/staging` | Root-only working space while a kit is built or restored |

Timecrate talks to nothing but your remote, and to whatever your alert and escrow-key commands
reach.

## Contributing and support

- Bugs and feature requests: [open an issue](https://github.com/spencernorton/timecrate/issues/new/choose). Questions: [Discussions](https://github.com/spencernorton/timecrate/discussions).
- Security reports: [private vulnerability reporting](https://github.com/spencernorton/timecrate/security/advisories/new). See [SECURITY.md](SECURITY.md). There is no e-mail address; that is deliberate.
- Pull requests are welcome; read [CONTRIBUTING.md](CONTRIBUTING.md) first. Changes are reviewed and merged on GitHub, then shipped in tagged releases.
- If this saves you time, you can [support its development](https://buy.stripe.com/8x26oH2U44f65TRe574wM04).

## Development

The suites install packages and replace rclone with fakes, so they run as root in a throwaway
container:

```bash
docker run --rm -v "$PWD":/repo:ro ubuntu:26.04 bash /repo/tests/checks.sh
docker run --rm -v "$PWD":/repo:ro ubuntu:26.04 bash /repo/tests/gui-smoke.sh
tests/package.sh                     # installs and upgrades the packages under systemd
scripts/build.sh                     # both .deb packages, into dist/
```

## Licence

[GPL-2.0-or-later](LICENSE) © Spencer Norton

Timecrate was developed alongside a fork of [Timeshift](https://github.com/linuxmint/timeshift)
and shares no code with it; it is not affiliated with Linux Mint.
