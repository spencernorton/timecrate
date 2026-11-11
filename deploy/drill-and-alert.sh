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
# Sourced for this script's own use only. `set -a` would also EXPORT every TIMECRATE_* value, and
# the engine treats an exported TIMECRATE_* as the caller's override of BOTH config files -- so the
# system file's TIMECRATE_REMOTE silently beat the per-user one the window writes, and the drill
# fetched from a remote no backup had used for days (2026-11-01). Un-export what the files set; the
# engine reads the same files itself, in its own order. Pre-existing environment is untouched.
_tc_preset="$(compgen -e | grep '^TIMECRATE_' || true)"
for f in /etc/timecrate/timecrate.conf /etc/timecrate.env; do
  # shellcheck disable=SC1090
  [ -r "$f" ] && { set -a; . "$f"; set +a; }
done
for _v in $(compgen -v | grep '^TIMECRATE_' || true); do
  printf '%s\n' "$_tc_preset" | grep -qxF "$_v" || export -n "${_v?}"
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

# The drill proves the NEWEST kit with the escrowed key, then sweeps every other kit on the remote
# -- fetch, decrypt, signature, archive listing -- because GFS retention holds kits for up to three
# years and the one you reach for in a real disaster is whichever predates the damage. Its last
# line says which of the two failed.
if ! { [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'RECOVERY DRILL PASSED'; }; then
  why="$(printf '%s' "$OUT" | sed -n 's/.*RECOVERY DRILL FAILED — \(.*\)\. FIX ESCROW.*/\1/p' | tail -1 | cut -c1-500)"
  critical="the drill FAILED — ${why:-the latest cloud kit did not decrypt and verify}"
fi
printf '%s' "$OUT" | grep -q 'DRILL STALE' \
  && critical="${critical:+$critical; }the newest cloud kit is STALE (daily backups may have stopped)"

# No second pass over the archive here. This used to run `verify --all` after the drill, which
# fetched and decrypted every kit a second time: with long retention that is the whole archive
# downloaded twice a month, under a one-hour limit it would in time stop fitting in. The drill's
# own sweep now checks the archive listing too, so one download per kit covers both.

# Off-box escrow survival: a wipe destroys the on-box key; verify a wipe-surviving copy still
# matches. Skipped on a hardened box (no on-box file left to compare against — the drill above
# already proved the off-box copy instead).
# Target and identity come from the config file (TIMECRATE_ESCROW_SSH*), the same values
# `timecrate harden` checks before it shreds the on-box key. Unset = this check is skipped.
if [ -f "$SEC" ] && [ -n "${TIMECRATE_ESCROW_SSH:-}" ]; then
  ESC_PATH="${TIMECRATE_ESCROW_SSH_PATH:-.timecrate/timecrate-secret.asc}"
  src="$(sudo -u "$TC_USER" sha256sum "$SEC" 2>/dev/null | cut -d' ' -f1)"   # the account's file, read as the account
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
