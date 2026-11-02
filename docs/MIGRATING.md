# Migrating from the previous package names

Releases before 3.0.0 were packaged as `time-machine` and `time-machine-gui`. Timecrate installs
beside them under new names: installing it overwrites and removes nothing of the old package, and
the kits, the keys and the remote carry over as they are. This page is the one-time move for a
machine that runs the old package. Do it outside the backup window: the timers fire around 03:00,
the drill on the first of the month.

## What carries over, and what changes

- **Kits** already on the remote are named `timemachine-<timestamp>.tar.zst.gpg`. Timecrate lists,
  verifies, restores, drills and prunes them together with its own `timecrate-*` kits, as one
  series ordered by timestamp. Nothing is renamed, and retention counts every kit once.
- **Keys** are the same keys. They move to a new directory, under new file names.
- **The remote** is what you configure. Keep the same path and the old kits stay in view.

| Before 3.0.0 | From 3.0.0 |
|---|---|
| `/etc/time-machine/time-machine.conf` | `/etc/timecrate/timecrate.conf` |
| `/etc/time-machine/include`, `/etc/time-machine/exclude` | `/etc/timecrate/include`, `/etc/timecrate/exclude` |
| `/etc/time-machine.env` | `/etc/timecrate.env` |
| settings named `TIMEMACHINE_<NAME>` | `TIMECRATE_<NAME>` |
| `~/.config/time-machine/` | `~/.config/timecrate/` |
| `timemachine-secret.asc`, `-public.asc`, `-signing-public.asc`, `-ESCROW-DOC.txt` | `timecrate-…`, same contents |
| `~/.local/state/time-machine/` | `~/.local/state/timecrate/` |
| `/var/lib/time-machine/staging` | `/var/lib/timecrate/staging` |
| `time-machine-{backup,drill,capstone}.timer`, installed disabled | `timecrate-{backup,drill,capstone}.timer`, enabled on install |
| alerts through a built-in notification helper | `TIMECRATE_ALERT_CMD`, an executable of your own |
| a built-in secret-store fetch for the drill and `harden` | `TIMECRATE_ESCROW_KEY_CMD`, an executable of your own |
| a few fixed patterns under the home, added to every kit | none; include lines may be globs instead |
| units that also read a second, optional environment file | units that read `/etc/timecrate.env` only |

## 1. Disarm the old timers, and keep the package

```sh
sudo systemctl disable --now time-machine-backup.timer time-machine-drill.timer time-machine-capstone.timer
systemctl is-active time-machine-backup.service time-machine-drill.service time-machine-capstone.service
```

The second command must print `inactive` three times: nothing of the old version is running.
Keep the old package installed until Timecrate has run well for a while — it is the rollback.
From 3.1.3 the archive carries a transitional `time-machine-gui` that replaces the old window
(and its "Time Machine" launcher) with nothing; the rollback below needs only the command-line
`time-machine` package, which is left alone.
Two tools pruning one remote would count each other's kits and delete kits early, so Timecrate
refuses to upload while `time-machine-backup.timer` is armed.

## 2. The configuration

```sh
sudo install -d -m 0755 /etc/timecrate
sudo sed -E -e 's/^([[:space:]#]*(export[[:space:]]+)?)TIMEMACHINE_/\1TIMECRATE_/' \
            -e 's|/etc/time-machine/time-machine\.conf|/etc/timecrate/timecrate.conf|g' \
            -e 's|/etc/time-machine/|/etc/timecrate/|g' \
            /etc/time-machine/time-machine.conf | sudo tee /etc/timecrate/timecrate.conf >/dev/null
sudo cp -p /etc/time-machine/include /etc/time-machine/exclude /etc/timecrate/
sudo sh -c 'umask 077; sed -E "s/^([[:space:]#]*(export[[:space:]]+)?)TIMEMACHINE_/\1TIMECRATE_/" \
            /etc/time-machine.env > /etc/timecrate.env'
sudo diff /etc/time-machine/time-machine.conf /etc/timecrate/timecrate.conf
```

Then look at three things:

- **`TIMECRATE_ESCROW_SSH_PATH`.** Its default is now `.timecrate/timecrate-secret.asc`. If an
  off-box copy is checked over SSH and you never set this, set it to where that copy really is —
  for most machines `.time-machine/timemachine-secret.asc`.
- **Alerts.** The old notification settings in `/etc/timecrate.env` are no longer read by
  Timecrate itself. Until `TIMECRATE_ALERT_CMD` names an executable, a failure reaches the system
  journal only (ALERTS in `timecrate(1)`); the old settings can stay if your command uses them.
- **The off-box key for the drill.** If the old drill fetched the escrowed key from a secret store,
  set `TIMECRATE_ESCROW_KEY_CMD` to a command that prints it. Unset, the drill uses the on-box copy.

## 3. The include and exclude lists

Add the new tool's paths, so a kit still carries the tool that opens it:

```sh
printf '%s\n' usr/bin/timecrate usr/bin/timecrate-gui usr/libexec/timecrate usr/share/timecrate \
  | sudo tee -a /etc/timecrate/include >/dev/null
```

Earlier releases added a few fixed patterns under the configured user's home to every kit,
whatever the lists said. Timecrate adds nothing the lists do not name. If you relied on files that
arrived in kits without being listed, name them now — lines may be globs, such as `~/*.sh` — or
they will be missing from every kit from the first Timecrate backup on. To see what the next kit
will hold: `sudo timecrate backup --dry-run`.

The old key directory never rides in a kit: Timecrate excludes `~/.config/time-machine` by itself.
If you had moved it with `TIMEMACHINE_CONF`, add that path to `/etc/timecrate/exclude`.

## 4. Keys and state

As the configured user — the keyring is theirs. Only the copy needs root: the backups run gpg as
root in this keyring, and gpg leaves files there that only root can read.

```sh
sudo cp -a ~/.config/time-machine ~/.config/timecrate
sudo chown -R "$(id -un):" ~/.config/timecrate
cd ~/.config/timecrate
for f in timemachine-*; do [ -e "$f" ] && mv -- "$f" "timecrate-${f#timemachine-}"; done
if [ -f time-machine.conf ]; then
  sed -E 's/^([[:space:]#]*(export[[:space:]]+)?)TIMEMACHINE_/\1TIMECRATE_/' time-machine.conf > timecrate.conf
  rm time-machine.conf
fi
rm -f gnupg/S.*                      # agent sockets copied along with the keyring
cmp timecrate-secret.asc ../time-machine/timemachine-secret.asc && echo "escrow copy identical"
```

Then the history and the anti-rollback anchor, which root wrote:

```sh
sudo cp -a ~/.local/state/time-machine ~/.local/state/timecrate
```

Both copies expect the `timecrate` directories not to exist yet: after an earlier attempt, move
them aside first, or `cp -a` copies into them. The anchor records the newest old kit and the count
on the remote. Timecrate reads it as the same series, so its first backup checks the remote
against it exactly as the old version would have.

## 5. Install Timecrate

```sh
sudo apt install -o Dpkg::Options::=--force-confold ./timecrate_*_all.deb ./timecrate-gui_*_all.deb
```

`--force-confold` keeps the files you wrote in step 2, and puts the package's own versions beside
them as `*.dpkg-dist`. Installing enables and starts the backup, drill and capstone timers.

## 6. Check it before the first scheduled run

```sh
timecrate config                  # every value, and the file it came from
timecrate keys                    # the same fingerprints as before, escrow confirmed
timecrate list                    # the old kits, oldest first
timecrate verify --remote         # fetches the newest kit and proves this machine can read it
sudo timecrate backup --dry-run   # what the next kit will hold
sudo timecrate alerts test        # once TIMECRATE_ALERT_CMD is set
systemctl list-timers 'timecrate-*'
```

A real run now, if you like: `sudo systemctl start timecrate-backup.service`. Afterwards
`timecrate list` shows the first `timecrate-*` kit as the newest, after every old one.

## Rollback

```sh
sudo systemctl disable --now timecrate-backup.timer timecrate-drill.timer timecrate-capstone.timer
sudo rm -f ~/.local/state/time-machine/expected ~/.local/state/time-machine/expected2
sudo systemctl enable --now time-machine-backup.timer time-machine-drill.timer time-machine-capstone.timer
```

The old anchor predates the kits Timecrate wrote and the old ones it pruned; left in place, the old
version's first backup would report as a deletion what is only retention. The old version neither
lists nor prunes `timecrate-*` kits; restore one of those with
`sudo time-machine restore --local <file>` or [BREAK-GLASS.md](BREAK-GLASS.md). To remove Timecrate
as well: `sudo apt remove timecrate timecrate-gui`.

## When you are sure

After a week or two of good runs:

```sh
sudo ls /var/lib/time-machine/staging   # a timemachine-*.tar.zst.gpg here is a kit whose upload
                                        # failed and exists nowhere else: upload it first
sudo apt purge time-machine time-machine-gui
sudo rm -f /etc/time-machine.env
sudo rm -rf /var/lib/time-machine ~/.local/state/time-machine
rm -rf ~/.config/time-machine           # a copy of the secret key; your escrowed copies remain
```

Then take the old tool's paths out of `/etc/timecrate/include`, if you carried them over.

## Why the packages do not conflict

The two packages share no file, so they can be installed side by side, and that is what keeps the
rollback to three commands: the old package stays installed but disarmed, instead of having to be
fetched again from an archive that may no longer carry it. The one thing a `Conflicts:` would have
prevented — both tools running at once — Timecrate prevents itself, by refusing to upload while the
old backup timer is armed.
