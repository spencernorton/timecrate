# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub:
**[Report a vulnerability](https://github.com/spencernorton/timecrate/security/advisories/new)**.
Do not open a public issue, and do not include keys, tokens, kit contents, hostnames or personal
paths in the report — a description and a minimal reproduction are enough.

There is no e-mail address for security reports; the advisory form is the only channel, and it is
the one that is monitored. You will get an acknowledgement within a week. Fixes ship as a tagged
release; the advisory is published once the release is out, and credits you unless you ask
otherwise.

## Supported versions

Only the latest tagged release is supported.

## What Timecrate does, and trusts

- The backup, the restore and the scheduled checks run as root, for one configured account. That
  account is trusted with what is in its own backups and nothing more: it must not be able to
  run anything as root, or have root read or write a file for it. So root does not act on the
  strength of anything in the account's home (3.2.0):
  - rclone, and GnuPG on the account's keyring, run as the account. Their configuration can name
    a program to start, and it starts as the account.
  - `~/.config/timecrate/timecrate.conf` is read as a list of settings, by the account, and is
    never executed. It can set where the backups go and how they are kept; what root runs or
    reads on the strength of a setting (alert and escrow commands, the include and exclude
    lists, paths) is set in `/etc/timecrate/timecrate.conf` only.
  - Status, history and the anti-rollback anchor are read and written as the account. Kits
    cross between root's staging directory, which is root-owned, and the account's processes
    as streams, never as paths.
  - What `/etc/timecrate.env` sets is removed from the environment of those processes, except
    names starting with `RCLONE_`.

  Known limits:
  - A kit holds what the include list names, read as root, and the keys a kit is encrypted to
    and signed with are the account's to hold and to choose. So the account can read whatever
    is in a kit: leave out of the include list what that account must not see.
  - For the same reason `restore --to-root` installs what the account's signing key signed:
    the pinned fingerprint is in the account's home. Where root must not take the account's
    word for it, give the fingerprint from the escrow sheet:
    `sudo TIMECRATE_EXPECT_SIGNER=<fingerprint> timecrate restore <timestamp> --to-root`.
  - The post-quantum key files in the account's home are read by root's `openssl` as key
    material (they cannot name a program).
  - A terminal shared between root and the account is protected from input injection by the
    kernel default (`dev.tty.legacy_tiocsti=0`, Linux 6.2 and later), not by Timecrate.
- Every kit is encrypted to your public key (AES-256) and signed by a separate key. Every path that
  extracts one verifies that signature, against a pinned fingerprint, before writing anything. The
  remote is not trusted: a kit that is unsigned, or signed by another key, is refused.
- The decryption key, its escrow file and the rclone token are excluded from every kit, derived
  from the live configuration so that an edit to the exclude list cannot re-admit them.
- The window runs as the user and asks for administrator approval (polkit, `auth_admin` every
  time) only for the operations that need root, through an allow-list of commands.
- Network: only the rclone remote(s) you configure, and whatever your `TIMECRATE_ALERT_CMD` and
  `TIMECRATE_ESCROW_KEY_CMD` commands reach. Both run as root, with `/etc/timecrate.env` in their
  environment: treat them as part of your trusted base.
