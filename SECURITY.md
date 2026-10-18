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

- The backup, the restore and the scheduled checks run as root, and read the configured user's
  keyring and rclone configuration. Root never writes through a path that user controls: staging
  is root-owned, and the rclone token is read and written back as the user.
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
