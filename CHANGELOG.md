# Changelog

All notable changes to Timecrate are documented here.

## Unreleased

## 3.2.3 — 2026-11-11

- **`timecrate coverage` classifies the top of the filesystem.** Under the root `/`, which is one
  of the default roots, and under any `--root` given with a trailing slash, every entry was
  reported `UNLISTED`, whatever the include and exclude lists said: `/etc` read as in no kit on a
  machine that backs it up. The window's Coverage dialog showed the same rows under "Not backed
  up", as `//etc`. Only the report was wrong; the kits were built from the lists as before. Roots
  such as a home directory were classified correctly.

## 3.2.2 — 2026-11-11

- **A check for deleted kits that could not list the destination is no longer skipped.** Since
  3.2.0, a backup whose check could not list the destination (an outage at 03:00) said so and
  went on, where it used to report every kit as deleted. The same run then recorded what the
  destination held as the new count, so kits deleted before that night were never reported. The
  check is now made once the run's own upload is there, leaving out the kit it added. If the
  destination still cannot be listed, the run raises a remote alert that says so.
- **The count a backup records follows from what its check saw.** After the upload, the engine
  counted the kits at the destination afresh and recorded that as the number to expect. A kit
  deleted between the check and that count, while the upload ran, was taken into the new number
  and never reported. The number recorded is now the kits the check saw, plus the new kit, less
  the kits retention dropped, so the next backup reports it. When that fresh count failed, 0 was
  recorded, and the next backup's count check passed whatever was there; a count is now taken
  only for a first anchor. Both are older than 3.2.0.
- **Retention reports a kit it could not delete.** A delete that failed (a key without that
  right, an append-only share) was passed over in silence. It is now a warning, the kit keeps
  its checksum and metadata files and is still counted, and it is tried again at the next backup.
- The nightly wrapper's alert says which kind of remote alert it carries (kits deleted or rolled
  back, a check for that which could not be made, an incomplete kit) and whether the backup
  itself completed. It said that kits were deleted or rolled back and that the backup was OK,
  whichever it was. Its subject is now "Timecrate REMOTE alert on <host>".
- The man page says that each machine needs a destination of its own (the README already did).

## 3.2.1 — 2026-11-11

- **The Remote page tells the truth about a Google Drive destination.** With the backups on the
  Google Drive sign-in, the page said "no rclone remote called gdrive yet" and "not signed in"
  next to "Reachable: OK": `remote status --json` looked for the remote in the main rclone
  configuration, and the Drive sign-in keeps its own. It reads the right file now, as the text
  form of `remote status` already did.
- **A name with an ampersand or angle brackets no longer blanks its row.** The window's rows,
  toasts and banners read their text as markup, and text that does not parse was dropped. So the
  Google Drive row was always blank (its text ends in `gdrive:<folder>`), and so was a folder
  called "R&D" in the folder picker, a path like it in the include list, and any message from
  the engine that names `<remote>:<path>`. The text is shown as it is.
- **Signing in to Dropbox never replaces another remote.** The Remote page showed a
  destination on any other rclone remote (S3, SFTP, OneDrive) as "Dropbox", with a
  "Re-authorise…" button, and `remote connect --reauthorize` made the remote in use a Dropbox
  one under the same name, whatever kind it was. The page shows such a destination as "Another
  rclone remote". `remote connect` signs in under the provider's own name when the remote in
  use is another kind or has the Google Drive sign-in's name, the window then asks which
  folder, and a remote of another kind that already has that name is refused.
  `remote disconnect --remove-rclone-remote` removes a Google Drive sign-in from the file it
  is in.

## 3.2.0 — 2026-11-11

- **Root no longer acts on files in the account's home (security).** The engine runs as root
  for one account. Until now it sourced that account's `~/.config/timecrate/timecrate.conf` as
  a shell script, ran rclone and GnuPG as root on the account's own configuration — both can
  name a program to start — and wrote its status files as root inside the account's home. So
  anything able to write those files as the account could run as root at the next scheduled
  backup, or have root read or overwrite a file of its choosing. Now the per-user file is read
  as a list of settings and never executed; rclone, and GnuPG on the account's keyring, run as
  the account; status, history and the anti-rollback anchor are read and written as the account;
  and a kit passes between root's staging directory and those processes as a stream, never as a
  path. Kits are unchanged: every kit already on a remote reads exactly as before.
- **What that changes on an existing machine.**
  - The per-user file takes only the destination, the second copy, the kit posture, retention,
    the size rails, compression and the git watch list. Anything else there is ignored with a
    warning — set it in `/etc/timecrate/timecrate.conf`. `timecrate config` lists what is taken.
  - What `/etc/timecrate.env` sets no longer reaches rclone, except names starting with
    `RCLONE_`. A credential rclone needs goes in the account's rclone configuration, or in that
    file as `RCLONE_CONFIG_<REMOTE>_<OPTION>`.
  - A key store, a per-user settings file or a state directory that an earlier release left
    owned by root is no use to the account. The state directory is handed back by the first
    command run as root. For the other two the run stops and the error names the command
    (`sudo chown -hR <account>: ~/.config/timecrate`): a settings file passed over in silence
    would send the kit wherever the defaults point.
  - `init`, `import-key`, `export-key`, `pq`, `escrow-doc`, `keys` and `remote` run as the
    account even under `sudo`, so they no longer leave root-owned files behind.
- **A folder is a destination.** `timecrate remote set-path /media/you/drive/TIMECRATE` sends
  the kits to an attached drive, a mounted share or a folder another program syncs. The folder
  must exist and be writable by the account, a drive that is not mounted stops the backup
  instead of being replaced by a directory, and the kits in a destination inside the backed-up
  tree are left out of the next ones (anything else in that folder is backed up as usual).
  `remote list` shows the remotes rclone already has, any of which can be a destination, and
  `remote set-mirror <remote:path>|<folder>|off` sets or clears the second copy.
- **A changed destination is not a deletion.** The anti-rollback anchor records the destination
  it describes. Pointing the backups somewhere else — by command, in the window or by editing
  the file — starts a new count there, where it used to raise a deletion alert at the next
  backup unless the change went through `remote set-path`. A listing that fails is no longer
  read as an empty destination either: the nightly check and the monthly drill say they could
  not look, where a network outage used to raise the deletion alert. A folder that is not there
  is reported as a drive that is not mounted.
- **An upload is checked by content.** The stored copy's hash is compared with the kit's as well
  as its size, on every backend that reports one, and a copy that fails is removed and sent
  again. `RCLONE_IGNORE_CHECKSUM` turns the comparison off, as it does for rclone itself.
- **A folder inside the destination is not a kit.** rclone lists one under any filter, and each
  was counted in the anchor, swept by `verify --all` and the drill (which then failed), and
  taken as proof that the kit just sent had arrived. Listings ask for files only, and a count
  recorded by an earlier release is still read the way it was taken.
- **The account is pinned with a command.** `sudo timecrate config set-user <login>` replaces
  the hand-edit of `/etc/timecrate/timecrate.conf` that a fresh install needed before its
  nightly backup could work. `status` and the window say when no account is pinned, and `init`
  ends by naming the command. `timecrate config get <NAME>` prints one resolved setting.
- **The window.** The Remote page takes a folder or any rclone remote the account has, and sets
  or clears a second copy. The Schedule page takes a daily time of your choosing and a pause of
  1, 3, 7 or 30 days; the main window shows a pause, and warns when scheduled runs are not tied
  to an account, with a button that fixes it. A change to only the schedule is now saved: it
  was dropped when nothing else had changed. A warning from the engine no longer empties a view,
  and when the status cannot be read the window shows the engine's reason.
- **The monthly drill fetches each kit once.** Its sweep now lists each archive after
  authenticating it, and the wrapper's separate `verify --all` pass is gone. With long
  retention that pass downloaded the whole archive a second time every month, under a one-hour
  limit it would eventually have outgrown. A failed drill's alert carries the drill's reason.
- A pause is written and read back as the account, and refused if it cannot be: a pause that
  `status` cannot see is backups stopping behind a healthy screen.
- `timecrate help` lists `backup --force`; the project links point at the current repository.

## 3.1.3 — 2026-11-02

- **The monthly drill checks the remote your backups use.** The drill, capstone and overnight
  wrappers read the system config with `set -a`, which exported its `TIMECRATE_REMOTE` — and the
  engine treats an exported setting as an override of both config files. On a machine whose
  window had set a per-user destination, backups went there while the drill fetched from the
  system file's old remote and reported a deletion that never happened. The wrappers still read
  the files for their own checks but no longer export what they read.
- **The old Time Machine launcher retires itself.** A new transitional `time-machine-gui`
  package replaces the pre-3.0 window with nothing, so an ordinary upgrade leaves one Timecrate
  entry in the applications list instead of two. The command-line `time-machine` package, the
  rollback, is untouched.

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
