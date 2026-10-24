#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Spencer Norton
#
# Monthly proof that the backups are still decryptable AND the escrow survives.
#
# Drill key: the OFF-box escrow copy when TIMECRATE_ESCROW_KEY_CMD is set -- the copy a wiped OS
# cannot destroy, and the only one left after `harden`. Otherwise the on-box escrow file.
#
# Alert severity is split: drill failure, a stale kit or escrow divergence are critical; "escrow
# host unreachable" and "the off-box key could not be fetched" are warnings -- a sleeping laptop
# is not an incident, but a drill that quietly stopped using the off-box copy should not be silent.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TC="$(command -v timecrate 2>/dev/null || echo "$HERE/../timecrate")"
[ -x "$TC" ] || { echo "timecrate not found on PATH" >&2; exit 1; }
HOST="$(hostname)"
# systemd hands us /etc/timecrate.env via EnvironmentFile=, but not the 0644 config file the
# tool itself reads -- and the escrow-verification target lives there.
for f in /etc/timecrate/timecrate.conf /etc/timecrate.env; do
  # shellcheck disable=SC1090
  [ -r "$f" ] && { set -a; . "$f"; set +a; }
done
TC_USER="${TIMECRATE_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$TC_USER" | cut -d: -f6)"
SEC="${TIMECRATE_CONF:-$USER_HOME/.config/timecrate}/timecrate-secret.asc"

TMPKEY=""
cleanup(){ [ -n "$TMPKEY" ] && rm -f -- "$TMPKEY"; }
trap cleanup EXIT
trap 'exit 130' INT TERM   # EXIT trap does not fire on untrapped signals -- a ^C'd manual run must still purge the fetched key

critical=""; warning=""
KEYFILE=""
if [ -n "${TIMECRATE_ESCROW_KEY_CMD:-}" ]; then
  TMPKEY="$(mktemp)"        # 0600: this is the disaster-recovery master key
  "$TIMECRATE_ESCROW_KEY_CMD" > "$TMPKEY" 2>/dev/null || true
  if grep -q 'BEGIN PGP PRIVATE KEY BLOCK' "$TMPKEY" 2>/dev/null; then
    KEYFILE="$TMPKEY"
    echo "[drill] using the OFF-box escrow key (TIMECRATE_ESCROW_KEY_CMD)"
  else
    echo "[drill] TIMECRATE_ESCROW_KEY_CMD returned no secret key — falling back to the on-box escrow file"
    warning="the off-box escrow key could not be fetched (TIMECRATE_ESCROW_KEY_CMD), so this drill used the on-box copy"
  fi
fi

OUT="$("$TC" recovery-drill ${KEYFILE:+"$KEYFILE"} 2>&1)"; RC=$?
printf '%s\n' "$OUT"

{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'RECOVERY DRILL PASSED'; } \
  || critical="the drill FAILED to decrypt the latest cloud kit"
printf '%s' "$OUT" | grep -q 'DRILL STALE' \
  && critical="${critical:+$critical; }the newest cloud kit is STALE (daily backups may have stopped)"

# The drill above proves the NEWEST kit decrypts. But GFS retention holds kits for up to three
# years, and the one you reach for in a real disaster is whichever predates the damage — so the
# tip being good says nothing about the kit you will actually need. Verify every kit on the
# remote. `verify --all` dies on any failure, so its exit code is the whole check; measured at
# ~3s/kit (45s for 15) against a cloud remote, which is noise beside the drill this runs next to.
# Unprivileged on purpose: verify stages into the caller's own cache, and the keyring is the
# user's. HOME is passed explicitly rather than trusted from sudo's env policy. The rclone
# settings must cross explicitly too: sudo's env_reset drops them, so an encrypted rclone
# config (RCLONE_PASSWORD_COMMAND from the service environment) otherwise leaves the
# unprivileged verify at a password prompt with no stdin — the drill dies on EOF while the
# root-run backup works. Only the two rclone variables are forwarded, and only when set.
VEN=(HOME="$USER_HOME")
[ -n "${RCLONE_CONFIG:-}" ] && VEN+=(RCLONE_CONFIG="$RCLONE_CONFIG")
[ -n "${RCLONE_PASSWORD_COMMAND:-}" ] && VEN+=(RCLONE_PASSWORD_COMMAND="$RCLONE_PASSWORD_COMMAND")
VOUT="$(sudo -u "$TC_USER" env "${VEN[@]}" timeout 3600 "$TC" verify --all 2>&1)"; VRC=$?
printf '%s\n' "$VOUT" | tail -3
if [ "$VRC" -eq 124 ]; then
  critical="${critical:+$critical; }verify --all TIMED OUT — the archive could not be checked this run"
elif [ "$VRC" -ne 0 ]; then
  critical="${critical:+$critical; }$(printf '%s' "$VOUT" | grep -E 'VERIFY FAILED' | tail -1 \
    || echo 'not every cloud kit verifies')"
fi

# Off-box escrow survival: a wipe destroys the on-box key; verify a wipe-surviving copy still
# matches. Skipped on a hardened box (no on-box file left to compare against — the drill above
# already proved the off-box copy instead).
# Target and identity come from the config file (TIMECRATE_ESCROW_SSH*), the same values
# `timecrate harden` checks before it shreds the on-box key. Unset = this check is skipped.
if [ -f "$SEC" ] && [ -n "${TIMECRATE_ESCROW_SSH:-}" ]; then
  ESC_PATH="${TIMECRATE_ESCROW_SSH_PATH:-.timecrate/timecrate-secret.asc}"
  src="$(sha256sum "$SEC" 2>/dev/null | cut -d' ' -f1)"   # service runs as root; $SEC is root-readable
  idargs=(); [ -n "${TIMECRATE_ESCROW_SSH_KEY:-}" ] && idargs=(-i "$TIMECRATE_ESCROW_SSH_KEY")
  off="$(timeout 15 sudo -u "$TC_USER" ssh "${idargs[@]}" -o BatchMode=yes -o ConnectTimeout=8 \
          "$TIMECRATE_ESCROW_SSH" \
          "if [ -f '$ESC_PATH' ]; then sha256sum '$ESC_PATH' | cut -d' ' -f1; else echo MISSING; fi" \
          2>/dev/null)"
  if [ -z "$off" ]; then
    # unreachable is NOT divergence — a sleeping laptop must not page as critical
    warning="${warning:+$warning; }$TIMECRATE_ESCROW_SSH unreachable — could not verify the off-box escrow copy this run"
  elif [ "$off" = "MISSING" ] || { [ -n "$src" ] && [ "$off" != "$src" ]; }; then
    critical="${critical:+$critical; }the off-box escrow copy on $TIMECRATE_ESCROW_SSH is missing or no longer matches — wiped-OS recovery is at risk"
  fi
fi

[ -z "$critical" ] && [ -z "$warning" ] && exit 0
if [ -n "$critical" ]; then SEV=critical; PROBLEM="$critical${warning:+; $warning}"; WHAT=PROBLEM
else SEV=warn; PROBLEM="$warning"; WHAT=warning; fi

printf 'Timecrate monthly check on %s: %s. Investigate the drill, the key escrow, the cloud kit or rclone.\n\n%s\n' \
  "$HOST" "$PROBLEM" "$(printf '%s' "$OUT" | tail -4)" \
  | "$HERE/alert.sh" "$SEV" "Timecrate recovery drill $WHAT on $HOST" drill
if [ "$SEV" = critical ]; then exit 1; else exit 0; fi
