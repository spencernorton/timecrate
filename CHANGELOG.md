# Changelog

All notable changes to Timecrate are documented here.

## Unreleased

## 3.1.2 — 2026-10-30

- Refresh the application icon with an orange recovery-and-snapshots design,
  keeping transparent corners and a clear silhouette at dock sizes.

## 3.1.1 — 2026-10-28

- New application icon: a blue crate with a clock-and-arrow emblem, shipped as PNG at
  512/256/128 px in place of the previous scalable SVG.

## 3.1.0 — 2026-10-28

- **Google Drive is a direct sign-in destination.** `timecrate remote connect --provider drive`
  runs Google's OAuth flow in the browser and stores the token in a dedicated rclone config
  (`~/.config/timecrate/rclone-drive.conf`), so a password-encrypted main rclone config can
  neither block it nor be unlocked by it. The window's Remote page offers Google Drive
  alongside Dropbox, shows the signed-in account, and the existing folder picker chooses the
  backup folder (`gdrive:<folder>`). Everything downstream — upload, retention, drill,
  restore — is the existing rclone path unchanged.
- **Post-quantum hybrid kits.** With `TIMECRATE_CRYPTO=hybrid`, each new kit is the ordinary
  signed GPG kit wrapped in an ML-KEM-1024 envelope: an OpenSSL encapsulation whose shared
  secret keys a symmetric AES-256 layer around the whole kit, so an attacker who one day
  breaks RSA-4096 still faces the KEM. Opening a hybrid kit needs both secrets; the Settings
  window chooses the posture, `timecrate pq init` makes the keypair (init runs it too), and
  every read path unwraps transparently after checking the envelope was made for the key on
  the box. Classic kits — including every kit already on a remote — stay readable exactly as
  before, and `demo`/break-glass document the two extra commands a hybrid kit needs.
- **The escrow sheet downloads as TXT or PDF.** `timecrate escrow-doc --format txt|pdf`
  renders the same sheet either way, now including the PQ secret and public key (with the
  manual unwrap steps) whenever a PQ key exists. A sheet issued while the posture is hybrid
  refuses to be written without the PQ secret it would need to be complete. The window's
  Keys page offers both formats as downloads.
- `timecrate config`, `status` and `keys` report the crypto posture and PQ fingerprint;
  kit `meta.json` records it per kit.

## 3.0.1 — 2026-10-04

- **The capstone decrypts on disk, and fails closed.** It decrypted the kit into `/tmp`, which on
  Ubuntu 26.04 is a tmpfs of half the RAM: under 1 GiB in the capstone's VM, smaller than a kit.
  The decrypt ran out of space without a signature record, and the run took that for a kit made
  before signing and carried on. The kit is now decrypted beside itself on the VM's disk and
  deleted once verified; a clean decryption with a valid signature from the staged signing key is
  required before anything is extracted; zstd and tar must both exit cleanly and the manifests must
  come out, or the run stops there.
- **Nothing absent counts as a pass.** An empty package sample, a kit without package selections,
  and desktop settings that read back no keys are failures. The settings read-back loaded a path
  that did not exist; it now loads the restored file.
- **The capstone's reboot is the guest's own.** `multipass restart` could wait out its whole bound
  while the guest had booted normally. The guest now reboots itself and only an answer from a new
  boot counts; if none comes, one forced stop and start follows, and the alert carries what the
  boot before it logged and which units failed, so a guest that cannot boot reads differently from
  a hypervisor that lost track of it. The reboot follows only a recovery that passed, so a failed
  one is not reported a second time as a reboot failure.
- A capstone alert lists every failed check, not only the first.
- **`verify` and `recovery-drill` work on disk too.** The recovery drill fetched and decrypted a
  kit under a bare `mktemp -d`, which is the same tmpfs `/tmp`; on a host with little RAM it would
  fail exactly as the capstone did. Both commands now share one disk-backed work-dir helper.
- [docs/BREAK-GLASS.md](docs/BREAK-GLASS.md): decrypt where there is room for about twice the kit,
  not in a tmpfs `/tmp`; a decrypt that runs out of space shows no signature, which is not a sign
  of tampering.

## 3.0.0 — 2026-09-30

The first public release, and a new name: releases before it were packaged as `time-machine` and
`time-machine-gui`. [docs/MIGRATING.md](docs/MIGRATING.md) moves a machine across.

- **Kits written before 3.0.0 are the same series.** `timemachine-*` kits already on a remote are
  listed, verified, restored, drilled and pruned together with new `timecrate-*` kits, ordered by
  timestamp; retention counts each kit once, and an anti-rollback anchor written by an earlier
  version is read correctly.
- **The timers are armed on install and stay armed across upgrades.** The backup, drill and
  capstone timers are enabled when the package is installed; an upgrade no longer stops them, and
  a timer you disabled stays disabled. The capstone is skipped on a machine without multipass.
- **Alerts go to a command you choose.** `TIMECRATE_ALERT_CMD` is run with the severity, a title
  and a key, and the message on standard input. Without it, alerts are written to the journal.
- **The off-box escrow copy is reached through a command you choose.** `TIMECRATE_ESCROW_KEY_CMD`
  gives the monthly drill the escrowed key to prove, and lets `harden` check it by fingerprint.
- **Include lines may be globs.** Nothing is added to a kit that the include list does not name.
- **Upload is refused while the previous package's backup timer is armed**, so the two versions
  cannot prune one remote at once.
- rclone's own notices are no longer read as kits: listings are parsed from rclone's output alone,
  so a `NOTICE:` line no longer shows up in `list`, counts in `verify --all` or fails the drill.
- `init` works as the user on a fresh install; it no longer needs the root-owned staging directory.
- Include entries under `~/` are no longer reported missing when they exist.
- The capstone's reboot check is generic: every restored file must survive the reboot, and each
  sysctl key named in `TIMECRATE_CAPSTONE_SYSCTL` must be in effect with its restored value.
- The capstone reads the per-user configuration, as the engine does.
- The About window names the licence correctly, GPL-2.0-or-later.
- A new icon, a crate.
