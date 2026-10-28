#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Spencer Norton
#
# Quarterly boot-and-verify capstone: a REAL wiped-OS recovery, inside a real booted VM.
#
# This is deliberately not a CI job. CI runners are containers and cannot nest a multipass VM,
# and the thing under test is precisely what a container cannot model: a machine that
# boots, runs systemd and dbus, installs packages from restored apt sources, and keeps the restored
# configuration across a reboot. So it runs where the hardware is — beside the drill, on a timer.
#
# What it proves that the monthly drill does NOT: the drill decrypts and authenticates a kit. This
# rebuilds from one. Between v1.3.0 and v2.8.0 the drill stayed green for twelve releases while the
# documented package replay was silently broken — one selected package with an unavailable i386
# dependency made apt refuse the ENTIRE transaction, so a rebuilt box would restore every file and
# install none of ~3000 packages. Nothing short of this test could see that.
#
# DESIGN RULE, learned the hard way in this very script: verify EFFECTS, never exit codes. The
# first cut chained `transfer A || transfer B || fail`; A pointed at a path that did not exist,
# returned zero anyway, and so the fallback never ran, the guard never fired, and the run died
# inside the VM with "No such file or directory". Every step below asserts the thing it wanted to
# happen actually happened.
#
#   --preflight   check every prerequisite and exit, WITHOUT launching a VM. This is what the
#                 regression suite runs, and what to run by hand after changing anything here.
#
# TIMECRATE_CAPSTONE_SYSCTL (space-separated sysctl keys, optional): after the reboot, each must
# be in effect with the value the restored /etc/sysctl.d sets -- proof that restored configuration
# is applied, not merely present. Without it the check is that every restored file and a marker
# survive the reboot.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TC="$(command -v timecrate 2>/dev/null || echo "$HERE/../timecrate")"
HOST="$(hostname)"
VM="${TIMECRATE_CAPSTONE_VM:-timecrate-capstone-vm}"
IMG="${TIMECRATE_CAPSTONE_IMAGE:-26.04}"
PREFLIGHT=0
[ "${1:-}" = "--preflight" ] && PREFLIGHT=1

for f in /etc/timecrate/timecrate.conf /etc/timecrate.env; do
  # shellcheck disable=SC1090
  [ -r "$f" ] && { set -a; . "$f"; set +a; }
done
TC_USER="${TIMECRATE_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$TC_USER" | cut -d: -f6)"
# The per-user file too, as the engine reads it: the window's Remote page writes the destination
# there, and a capstone that listed kits through the engine but fetched them from the built-in
# default would be rebuilding from nothing.
# shellcheck disable=SC1090
[ -n "$USER_HOME" ] && [ -r "$USER_HOME/.config/timecrate/timecrate.conf" ] \
  && { set -a; . "$USER_HOME/.config/timecrate/timecrate.conf"; set +a; }
CONF="${TIMECRATE_CONF:-$USER_HOME/.config/timecrate}"
RCONF="${TIMECRATE_RCLONE_CONF:-$USER_HOME/.config/rclone/rclone.conf}"
REMOTE="${TIMECRATE_REMOTE-dropbox:TIMECRATE}"   # the engine's own default
if [ "${REMOTE%%:*}" = "${TIMECRATE_DRIVE_REMOTE:-gdrive}" ]; then
  RCONF="${TIMECRATE_DRIVE_CONF:-$CONF/rclone-drive.conf}"
fi
WORK=""

problem=""
fail(){ problem="${problem:+$problem; }$1"; }
# Initialised HERE, not at its one assignment inside the launch-failure path. This script runs
# `set -u`, and the alert block expands "$INFRA" unconditionally — so leaving it unset meant
# every OTHER failure (missing kit, failed transfer, bad checksum, failed restore, dead reboot) died
# on "unbound variable" BEFORE the alert was sent. The alert would have been suppressed in precisely
# the cases where recovery is broken, which is the one thing this job exists to report.
INFRA=0

# multipass authenticates PER CLIENT: its certificate lives in the invoking user's config, so a
# root-run `multipass launch` fails with "client is not authenticated" even though the daemon is
# running and the same command works as TC_USER. Same shape as the rclone config, same answer:
# do the user-context work as the user. Mirrors rc() in the engine.
asuser(){
  if [ "$(id -u)" = 0 ]; then runuser -u "$TC_USER" -- env HOME="$USER_HOME" "$@"
  else "$@"; fi
}
# EVERY multipass call is bounded here rather than at each call site. An unbounded `multipass
# restart` against a guest that never comes back is what produced a THIRTY-HOUR hang once already,
# and it hung again on 2026-08-04 — the instance sat in "Restarting" with the daemon idle while
# the run waited forever. One bound in the shared helper covers every present and future caller.
# Note the argument order: `timeout` execs binaries and cannot run a shell function, so it goes
# INSIDE asuser (asuser timeout N cmd), never around it.
MP_TIMEOUT="${TIMECRATE_CAPSTONE_MP_TIMEOUT:-900}"
mp(){ asuser timeout "$MP_TIMEOUT" multipass "$@"; }
# Readiness probes need their OWN short bound. At the 900s default a 36-iteration reboot poll
# against a wedged daemon would take NINE HOURS — the same unbounded hang this replaced, just
# wearing a loop. A guest that is up answers `true` in well under ten seconds.
mp_probe(){ asuser timeout "${TIMECRATE_CAPSTONE_PROBE_TIMEOUT:-10}" multipass "$@"; }
# Teardown needs its own bound, and a short one. purge_vm runs from the EXIT trap, so at the 900s
# default three stop/delete/list rounds could sit for over an hour — with the alert unsent, because
# the trap runs before the process exits. The failure would be invisible exactly when it matters.
# A stop or delete that has not returned in two minutes is not going to.
mp_tear(){ asuser timeout "${TIMECRATE_CAPSTONE_TEARDOWN_TIMEOUT:-120}" multipass "$@"; }
# The hypervisor was bounded; the REMOTE was not. `timecrate list` and both `rclone copyto` calls
# reach the remote, and the quarterly systemd job runs this script directly with no outer deadline —
# the overnight suite's `timeout "$(budget …)"` only covers the runs IT starts. The unit's
# TimeoutStartSec=90min is a kill, not a report: systemd SIGTERMs the script and the alert at
# the bottom never runs, so a wedged remote produces a failed unit and NO alert. Bounded here so it
# fails while it can still say why.
rem(){ asuser timeout "${TIMECRATE_CAPSTONE_REMOTE_TIMEOUT:-900}" "$@"; }

# `list` is a cheap daemon query, so it takes the probe bound rather than the launch-sized one.
#
# TRI-STATE, deliberately. The version this replaces piped straight into `grep -qx`, which made
# "the VM is gone" and "the daemon did not answer" the same result — and only one of those means
# the escrowed secret key is off the disk. That is the wrong way round precisely when it matters:
# the daemon wedge this job now self-heals from is exactly when a query fails, so a wedged daemon
# would have silently certified the key-bearing VM as destroyed.
#
# The discriminator is the CSV header. VERIFIED 2026-08-04: a host with zero instances
# still prints `Name,State,IPv4,IPv6,Release,AllIPv4` and exits 0; a query that fails prints no
# header at all. Note the status must be captured from multipass itself — in a pipeline `$?` is
# the LAST command's, which is how a failed query reads as rc=0.
#
# rc 0 = query completed (names on stdout, possibly none)   rc 2 = query could not be completed
vm_names(){
  local out
  out="$(mp_probe list --format csv 2>/dev/null)" || return 2
  printf '%s\n' "$out" | head -1 | grep -q '^Name,' || return 2
  printf '%s\n' "$out" | tail -n +2 | cut -d, -f1 | grep . || true
  return 0
}
# rc 0 = present   rc 1 = confirmed absent   rc 2 = unknown, DO NOT read as absent
vm_exists(){
  local names
  names="$(vm_names)" || return 2
  if printf '%s\n' "$names" | grep -qx "$VM"; then
    # Latched the moment the instance is first CONFIRMED present, and never cleared. Cleanup uses
    # it to decide whether an unverified teardown is worth alarming about: if the VM was never
    # created there is no copy of the escrowed key anywhere, and warning about one trains the
    # operator to discount the warning that matters.
    VM_EVER_EXISTED=1
    return 0
  fi
  return 1
}

# Destroy the VM and PROVE it is gone. It holds a copy of the escrowed secret key, so "probably
# deleted" is not good enough; a delete during a restart has been observed to leave the instance
# behind. Retries, then says so loudly rather than leaving key material lying around silently.
# Returns success ONLY on confirmed absence: an unknown answer is a cleanup failure, because an
# unverified key-bearing VM is the thing this function exists to prevent.
purge_vm(){
  local attempt
  for attempt in 1 2 3; do
    vm_exists; case $? in 1) return 0 ;; 2) : ;; esac
    mp_tear stop "$VM" >/dev/null 2>&1 || true
    mp_tear delete "$VM" --purge >/dev/null 2>&1 || true
    vm_exists; [ $? -eq 1 ] && return 0
    [ "$attempt" -lt 3 ] && sleep 5
  done
  vm_exists; [ $? -eq 1 ]
}

CLEANED=0
PURGE_FAILED=0
# Whether a VM was ever confirmed to EXIST. Without this, a run that failed before the instance
# was ever created still reported "could not confirm the recovery VM was destroyed — it holds a
# copy of the escrowed secret key", because a wedged daemon answers "unknown" rather than "absent".
# OBSERVED 2026-08-05: exactly that, on a run where multipass never created anything and no
# instance existed. A false key-exposure alarm teaches operators to discount a real one.
VM_EVER_EXISTED=0
cleanup(){
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  [ -n "$WORK" ] && rm -rf -- "$WORK"
  if [ "$VM_EVER_EXISTED" = 0 ]; then
    :   # nothing was ever created, so there is nothing holding key material to warn about
  elif ! purge_vm; then
    PURGE_FAILED=1
    # Say WHICH failure it is. "Still present" and "the daemon cannot tell me" need the same manual
    # follow-up but describe different hosts, and an operator who reads "could not destroy" on a box
    # where the VM is actually gone learns to ignore the warning.
    vm_exists && state="it is still present" || state="the daemon could not confirm it is gone"
    echo "WARNING: could not destroy VM '$VM' — $state. It holds a copy of the ESCROWED SECRET KEY." >&2
    echo "         Check and remove by hand:  multipass list; multipass delete $VM --purge" >&2
  fi
}
# A plain `trap cleanup EXIT INT TERM` does NOT stop this script when the caller's `timeout` fires:
# bash runs the handler and then RESUMES the script, so the run continues past its own deadline and
# cleanup executes twice. VERIFIED 2026-08-04 — the old shape printed "STILL RUNNING past the
# timeout" and ran cleanup twice; this shape exits after one cleanup. That mattered here because the
# overnight suite bounds each capstone with `timeout "$(budget 3600)"` specifically so a test cannot
# still hold the engine flock when the 03:00 backup wants it.
#
# Cleanup is allowed to overrun the deadline a little: at worst three purge attempts at the 120s
# teardown bound plus two 5s waits, about twelve minutes from a 02:30 stop — still clear of 03:00,
# and the VM it is deleting holds a copy of the escrowed secret key, so finishing wins over exiting.
on_signal(){ cleanup; trap - EXIT INT TERM; kill -"$1" $$; }
trap cleanup EXIT
trap 'on_signal INT'  INT
trap 'on_signal TERM' TERM

# Every [FAIL] line of a run, joined: the first one alone is often a consequence, not the cause.
fail_lines(){ printf '%s\n' "$1" | awk '/\[FAIL\]/{sub(/^ *\[FAIL\] /, ""); printf "%s%s", s, $0; s="; "}'; }

# Copy into the VM and verify by SIZE at the destination. `multipass transfer` has returned zero
# for a source that does not exist, so its exit code proves nothing.
vm_put(){
  local src="$1" dst="$2" want got
  want="$(stat -c %s "$src" 2>/dev/null || echo -1)"
  mp transfer "$src" "$VM:$dst" >/dev/null 2>&1 || true
  got="$(mp exec "$VM" -- stat -c %s "$dst" 2>/dev/null | tr -d '\r' | head -1)"
  [ -n "$got" ] && [ "$got" = "$want" ]
}

# ---- preflight: everything that can be checked without spending a VM ----------------------------
[ -x "$TC" ] || fail "timecrate not executable at $TC"
command -v multipass >/dev/null 2>&1 || fail "multipass not installed"
command -v runuser   >/dev/null 2>&1 || fail "runuser not available (needed to drop to $TC_USER)"
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || fail "cannot resolve a home for TC_USER=$TC_USER"
[ -r "$CONF/timecrate-secret.asc" ] || fail "no escrowed secret key at $CONF/timecrate-secret.asc"
[ -r "$RCONF" ] || fail "no rclone config at $RCONF"

# Resolve the in-VM script ONCE, from a candidate list, and require it to exist. The previous
# version chained transfers and trusted their exit codes; this decides the source up front so a
# missing file is a preflight failure rather than a mystery inside the VM.
RECOVER_SRC=""
# Beside this script in a source checkout; in /usr/share when packaged, because it is data to this
# host -- it runs inside the guest.
for c in "$HERE/recover-in-vm.sh" /usr/share/timecrate/recover-in-vm.sh; do
  [ -r "$c" ] && { RECOVER_SRC="$c"; break; }
done
[ -n "$RECOVER_SRC" ] || fail "recover-in-vm.sh not found (looked beside this script and in /usr/share/timecrate)"

if [ "$PREFLIGHT" = 1 ]; then
  if [ -n "$problem" ]; then echo "PREFLIGHT FAILED on $HOST: $problem" >&2; exit 1; fi
  echo "PREFLIGHT OK on $HOST — engine=$TC user=$TC_USER recover=$RECOVER_SRC vm=$VM image=$IMG"
  exit 0
fi
[ -z "$problem" ] || { echo "CAPSTONE FAILED on $HOST: $problem" >&2; exit 1; }

# ---- stage the inputs a rebuilt machine would actually have -------------------------------------
# Staging MUST live under TC_USER's real $HOME, and must not be hidden. `multipass` is a strictly
# confined snap with its own private /tmp, so a `mktemp -d` dir is invisible to it: `transfer`
# reports "[sftp] cannot access <path>: No such file or directory" for a file that plainly exists,
# and every staged input silently fails to land. Snap's `home` interface also excludes dotfiles,
# so ~/.timecrate-capstone-work.XXXX fails identically — the name must not start with a dot.
# Created BY TC_USER rather than chowned to them: rclone needs to write here with that user's
# OAuth token, and root must not open a config under their home (see rc() in the engine).
# Verified 2026-08-04 by transferring the same file from /tmp (rc=2, "cannot access") and from
# $HOME (rc=0, landed) into a live instance.
WORK="$(asuser mktemp -d "$USER_HOME/timecrate-capstone-work.XXXXXX")" && [ -d "$WORK" ] \
  || { echo "CAPSTONE FAILED on $HOST: could not create a staging dir under $USER_HOME" >&2; exit 1; }
# NO root operation on this path — not even chmod. It lives inside TC_USER's home, so that user
# can rename or replace it between any check and any use, and a root chmod/cp/chown through it is
# a privilege-escalation primitive (the same shape review rejected in v2.5.2). `mktemp -d` already
# creates 0700, and created it AS that user, so there is nothing for root to do here.
# TIMECRATE_CAPSTONE_KIT picks which kit to rebuild from: newest (default), oldest, or an exact name.
# `list` is sorted oldest-first, so newest is `tail -1` and oldest is `head -1`. Until 2026-08-04
# this variable was READ NOWHERE while overnight-suite.sh set it for its cross-version test, so
# "rebuild from the OLDEST kit" silently rebuilt the newest one on every run it ever made — the
# one assurance that older retained kits are still restorable never actually executed.
KIT_SEL="${TIMECRATE_CAPSTONE_KIT:-newest}"
KIT_LIST="$(rem "$TC" list 2>/dev/null)" || fail "could not list kits on $REMOTE within the remote timeout"
case "$KIT_SEL" in
  newest) KIT="$(printf '%s\n' "$KIT_LIST" | tail -1)" ;;
  oldest) KIT="$(printf '%s\n' "$KIT_LIST" | head -1)" ;;
  *)      if printf '%s\n' "$KIT_LIST" | grep -Fxq "$KIT_SEL"; then KIT="$KIT_SEL"
          else KIT=""; fail "TIMECRATE_CAPSTONE_KIT=$KIT_SEL is not a kit on $REMOTE"; fi ;;
esac
if [ -z "$KIT" ]; then
  fail "no kit on $REMOTE to rebuild from"
else
  rem rclone --config "$RCONF" copyto "$REMOTE/$KIT" "$WORK/kit.tar.zst.gpg" 2>/dev/null || true
  [ -s "$WORK/kit.tar.zst.gpg" ] || fail "could not fetch $KIT"
  rem rclone --config "$RCONF" copyto "$REMOTE/$KIT.sha256" "$WORK/kit.sha256" 2>/dev/null || true
  if [ -s "$WORK/kit.sha256" ]; then
    # The kit is fetched under a fixed local name, so the checksum file has to name that instead of
    # the remote one for `sha256sum -c` to work in the guest. Rewritten AS TC_USER: as a root shell
    # redirection — which is what this was — TC_USER could plant kit.sha256.new as a symlink to any
    # root-writable path between the mktemp and the write, and root would truncate the target for
    # them. Reading the file as root is no safer: the same symlink makes root copy the first token
    # of a root-only file into a directory the user owns.
    asuser sh -c 'sed -E "s|[[:space:]]+.*$|  kit.tar.zst.gpg|" "$1/kit.sha256" > "$1/kit.sha256.new" \
                    && mv "$1/kit.sha256.new" "$1/kit.sha256"' _ "$WORK" \
      || fail "could not rewrite the kit checksum for local verification"
  fi
  # Every copy runs AS TC_USER, so root NEVER writes into a directory TC_USER owns. A root `cp`
  # into a user-owned staging dir follows a destination symlink the user can plant between the
  # mktemp and the copy, and a wildcard `chown` without -h would then hand them the target — a
  # privilege boundary crossed for no gain, since TC_USER already owns the keyring, already runs
  # rclone into this directory, and is who the files are being handed to anyway.
  asuser cp "$CONF/timecrate-secret.asc" "$WORK/escrow-key.asc" \
    || fail "could not stage the escrowed key (is $CONF readable by $TC_USER?)"
  asuser cp "$CONF/timecrate-signing-public.asc" "$WORK/signing-pub.asc" 2>/dev/null || true
  # Hybrid recovery needs its separate escrowed PQ secret in the guest.
  if asuser head -c 13 "$WORK/kit.tar.zst.gpg" | grep -q '^TIMECRATE-PQ1'; then
    asuser cp "${TIMECRATE_PQ_SECRET:-$CONF/pq-secret.pem}" "$WORK/pq-secret.pem" \
      || fail "could not stage the PQ secret for hybrid recovery"
  fi
  # recover-in-vm.sh normally lives in /opt or /usr/share — OUTSIDE $HOME, where the confined snap
  # cannot see it at all. Copy it in and transfer from here like everything else.
  asuser cp "$RECOVER_SRC" "$WORK/recover-in-vm.sh" || fail "could not stage recover-in-vm.sh"
fi

OUT=""
if [ -z "$problem" ]; then
  purge_vm >/dev/null 2>&1 || true
  # MEASURED 2026-08-04: the multipass daemon wedges after repeated instance churn. A
  # launch then hangs until its timeout and creates nothing, with ZERO qemu processes and ZERO
  # instances present — pure daemon state, not a busy host and not a crash. `snap restart multipass`
  # cleared it and the same launch completed in 31 seconds.
  #
  # So a first failure is not evidence that recovery is broken; it is evidence the daemon needs a
  # kick. Restart it and try once more. Guarded on there being no OTHER instances, because the
  # restart would disrupt anyone else's VM and this job does not own the host.
  if ! mp launch "$IMG" --name "$VM" --memory 2G --disk 12G >/dev/null 2>&1 || ! vm_exists; then
    # Restart ONLY on a query that actually completed. `... | grep -c . || true` returns 0 when the
    # list fails, so the old guard read "the daemon did not answer" as "no other VMs are running"
    # and would restart the daemon out from under someone else's instance — most likely exactly
    # here, since an unhealthy daemon is why this branch runs at all.
    all_names="$(vm_names)"; names_rc=$?
    others="$(printf '%s\n' "$all_names" | grep -vx "$VM" | grep -c . || true)"
    # Re-checked immediately before the restart to keep the window small. It cannot be made atomic:
    # multipass has no host lock this script could take, and an unrelated client can create an
    # instance between any query and the restart. Narrowing is the honest ceiling — if that is not
    # acceptable on a given host, set TIMECRATE_CAPSTONE_NO_DAEMON_RESTART=1 and the self-heal is skipped.
    still_alone=0
    if [ "$names_rc" -eq 0 ] && [ "$others" -eq 0 ] && recheck="$(vm_names)"; then
      [ "$(printf '%s\n' "$recheck" | grep -vx "$VM" | grep -c . || true)" = 0 ] && still_alone=1
    fi
    if [ "${TIMECRATE_CAPSTONE_NO_DAEMON_RESTART:-0}" != 1 ] && [ "$still_alone" = 1 ] \
       && command -v snap >/dev/null 2>&1; then
      echo "  [warn] launch produced no instance; the multipass daemon looks wedged — restarting it and retrying once" >&2
      timeout 180 snap restart multipass >/dev/null 2>&1 || true
      # Wait for the daemon to actually ANSWER, rather than sleeping a guess. MEASURED
      # 2026-08-05: the restart itself logged `Failed with result 'timeout'` and the daemon was
      # not usable within 20s, so the retry launched into a daemon that was still coming up and
      # the run was reported as a hypervisor failure. The daemon answered normally minutes later.
      # A fixed sleep cannot express "ready"; a query that succeeds can.
      for _ in $(seq 1 "${TIMECRATE_CAPSTONE_DAEMON_READY_TRIES:-30}"); do
        vm_names >/dev/null 2>&1 && break
        sleep 5
      done
      purge_vm >/dev/null 2>&1 || true
      mp launch "$IMG" --name "$VM" --memory 2G --disk 12G >/dev/null 2>&1 || true
    fi
  fi
  if ! vm_exists; then
    INFRA=1
    fail "multipass could not launch $IMG as $VM even after restarting the daemon (hypervisor/daemon on this host, NOT a recovery failure)"
  else
    mp exec "$VM" -- mkdir -p /home/ubuntu/timecrate-in >/dev/null 2>&1
    for f in kit.tar.zst.gpg kit.sha256 escrow-key.asc signing-pub.asc pq-secret.pem; do
      [ -s "$WORK/$f" ] || continue
      vm_put "$WORK/$f" "/home/ubuntu/timecrate-in/$f" || fail "staging $f into the VM did not land"
    done
    vm_put "$WORK/recover-in-vm.sh" /home/ubuntu/recover-in-vm.sh || fail "staging recover-in-vm.sh did not land"
  fi
fi

if [ -z "$problem" ]; then
  OUT="$(mp exec "$VM" -- sudo bash /home/ubuntu/recover-in-vm.sh 2>&1)"
  printf '%s\n' "$OUT"
  printf '%s' "$OUT" | grep -qE '^==== IN-VM RESULT: [0-9]+ PASS / 0 FAIL' \
    || fail "in-VM recovery FAILED ($(printf '%s' "$OUT" | grep -c '\[FAIL\]') checks): $(fail_lines "$OUT")"
fi

# Only after a clean in-VM run: a recovery that stopped early wrote no marker, so the reboot would
# cost minutes and add a second, false cause to an alert that already has the real one.
if [ -z "$problem" ]; then
  # reboot survival: restored config that does not outlive a boot has not been restored
  #
  # The guest reboots itself; `multipass restart` is not used. Its wait for the daemon's own SSH
  # session has run to the full bound while the guest booted normally and kept time, and before
  # the bound existed it hung for thirty hours. The session drops as the guest goes down, so the
  # exit status of the request means nothing: what counts is a guest answering from a NEW boot.
  # Only a well-formed id counts, so stray output from multipass can never pass for a new boot.
  boot_id(){ mp_probe exec "$VM" -- cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' \
               | grep -m1 -xE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}'; }
  # 36 x (probe + 5s), well past a normal cloud-image boot. Tunable only so the suite can drive the
  # never-answers path in seconds instead of minutes. A probe has its own short bound: at the 900s
  # mp() default the same loop against a wedged daemon would take nine hours.
  await_boot(){
    for _ in $(seq 1 "${TIMECRATE_CAPSTONE_REBOOT_TRIES:-36}"); do
      now="$(boot_id)"
      [ -n "$now" ] && [ "$now" != "$1" ] && return 0
      sleep 5
    done
    return 1
  }
  # A few tries: one dropped probe here would otherwise read as a failed capstone.
  for _ in 1 2 3; do before="$(boot_id)"; [ -n "$before" ] && break; sleep 5; done
  [ -n "$before" ] && mp_probe exec "$VM" -- sudo systemctl reboot >/dev/null 2>&1
  if [ -z "$before" ]; then
    fail "the VM did not report its boot id before the reboot, so a reboot could not be told from no reboot"
  elif ! await_boot "$before"; then
    # One forced power cycle, to tell the two causes apart: a guest the restored configuration
    # will not let boot, and a guest that booted while multipass lost its way back in. Only a
    # short-bounded read follows, and only if the guest answers from a new boot.
    mp_tear stop --force "$VM" >/dev/null 2>&1
    mp_tear start "$VM" >/dev/null 2>&1
    if await_boot "$before"; then
      warns="$(mp_probe exec "$VM" -- sudo journalctl -b -1 -p warning -n 15 -q --no-pager 2>&1 | tr -d '\r' | paste -sd'|' -)"
      failed="$(mp_probe exec "$VM" -- systemctl --failed --no-legend --plain 2>&1 | tr -d '\r' | paste -sd'|' -)"
      fail "the VM never answered after its reboot, but did after a forced stop and start, so it boots; the boot before that logged: ${warns:-no warnings}; failed units now: ${failed:-none}"
    else
      fail "the VM never answered after its reboot, nor after a forced stop and start: it did not boot, or multipass cannot reach it, and which cannot be told from here"
    fi
  else
    # recover-in-vm.sh left a marker and a list of what it restored; after the boot it checks they
    # survived, and that every key in TIMECRATE_CAPSTONE_SYSCTL is in effect as restored.
    after="$(mp exec "$VM" -- sudo env TIMECRATE_CAPSTONE_SYSCTL="${TIMECRATE_CAPSTONE_SYSCTL:-}" \
               bash /home/ubuntu/recover-in-vm.sh --after-reboot 2>&1)"
    printf '%s\n' "$after"
    printf '%s' "$after" | grep -qE '^==== AFTER-REBOOT RESULT: [0-9]+ PASS / 0 FAIL' \
      || fail "restored configuration did not survive the reboot: $(fail_lines "$after")"
  fi
fi

# Tear down BEFORE deciding the verdict. The VM holds a copy of the escrowed secret key, so
# "the rebuild worked, but I could not confirm the key-bearing VM was destroyed" is not a pass.
# Left to the EXIT trap this ran AFTER `exit 0` had already been chosen: cleanup wrote a warning to
# stderr that changed no status and reached no alert, so a standalone quarterly run could report
# success and page nobody while the key sat in a surviving instance. cleanup() is idempotent, so
# calling it here makes the trap a no-op on every path.
cleanup
[ "$PURGE_FAILED" = 0 ] \
  || fail "could not confirm the recovery VM was destroyed — it holds a copy of the escrowed secret key"
# Only meaningful once something existed; see VM_EVER_EXISTED above.

if [ -z "$problem" ]; then
  echo "CAPSTONE PASSED on $HOST — a real wiped-OS rebuild from $KIT ($KIT_SEL), including a reboot."
  exit 0
fi

# stdout FIRST, and always. This runs as a systemd unit: if the only description of the failure
# goes to the alert gateway, `journalctl -u timecrate-capstone` shows a failed unit and nothing
# else — and whoever is debugging at that point has already lost the machine.
echo "CAPSTONE FAILED on $HOST: $problem" >&2

# ---- the alert: every variable below is initialised at the top, so `set -u` cannot swallow it --
# A hypervisor that will not start a VM is NOT "your backups are unrecoverable". Sending the same
# critical alert for both teaches the reader to discount it, and then the real one is discounted
# too — the specific way a disaster-recovery alarm becomes worthless.
if [ "$INFRA" = 1 ]; then SEV=warn; TITLE="Timecrate capstone could not run on $HOST (host or hypervisor)"
else SEV=critical; TITLE="Timecrate CAPSTONE FAILED on $HOST"; fi
printf 'Timecrate quarterly capstone on %s: %s.\n\n%s\n\n%s\n' "$HOST" "$problem" \
  "This is the boot-and-verify rebuild, not the monthly drill: the drill proves a kit decrypts, this proves a machine can be rebuilt from one. A failure here means the documented restore path is broken even if backups and drills are green." \
  "$(printf '%s' "$OUT" | tail -6)" \
  | "$HERE/alert.sh" "$SEV" "$TITLE" capstone
exit 1
