#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Spencer Norton
#
# Overnight assurance run. Answers the questions the per-commit suite structurally cannot, because
# they need the real remote, real kits and real booted machines:
#
#   T1  every kit on the remote decrypts, authenticates and lists — not just the newest
#   T2  a rebuild from the OLDEST kit, which GFS retention means was often written by an older
#       version of this tool. That is the actual fallback when the newest kit is the suspect one.
#   T3  three consecutive capstone runs, because "it passed once" is not "it is dependable on a
#       timer" — VM orchestration is exactly where flakiness hides
#   T4  the GUI against the REAL engine and the REAL remote. Until now it has only ever been
#       smoke-tested against a stub CLI, so every assertion about it has been about the stub.
#   T5  the alert path end to end, since T1-T4 running unattended are worthless if a failure
#       cannot reach anyone
#
# SAFETY, because this runs while nobody is watching:
#   * READ-ONLY against the remote. It never uploads, never prunes, never writes a kit.
#   * Finishes before the nightly backup. The engine holds a flock, so an overrun would make the
#     BACKUP fail — the one outcome that must never be caused by a test.
#   * Every VM is destroyed and every staged copy of the escrowed key is shredded, with the same
#     proven-teardown logic as the capstone: re-checked, retried, and reported if it survives.
#   * Per-test timeouts, so one hang cannot consume the night.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TC="$(command -v timecrate 2>/dev/null || echo "$HERE/../timecrate")"
# Beside this script (a source checkout, or the package's libexec directory), else the packaged
# path. A bare default that pointed at nothing would make every VM test fail with "No such file"
# and be reported as a capstone failure — blaming recovery for a path.
CAPSTONE="${TIMECRATE_CAPSTONE_SH:-}"
if [ -z "$CAPSTONE" ]; then
  for c in "$HERE/capstone-and-alert.sh" /usr/libexec/timecrate/capstone-and-alert.sh; do
    [ -x "$c" ] && { CAPSTONE="$c"; break; }
  done
fi
CAPSTONE="${CAPSTONE:-/usr/libexec/timecrate/capstone-and-alert.sh}"
HOST="$(hostname)"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
REPORT="${TIMECRATE_OVERNIGHT_REPORT:-/var/log/timecrate-overnight-$STAMP.log}"
DEADLINE_HHMM="${TIMECRATE_OVERNIGHT_DEADLINE:-02:30}"   # hard stop, comfortably before the 03:00 backup
BACKUP_HHMM="${TIMECRATE_OVERNIGHT_BACKUP:-03:00}"        # the nightly backup this must never contend with
BACKUP_MARGIN="${TIMECRATE_OVERNIGHT_BACKUP_MARGIN:-1800}"
# Resolve the deadline to an absolute instant ONCE, at start, rather than comparing HHMM strings.
# The version this replaces read "now >= 02:30 AND hour < 12", which is also true at 05:00 — so a
# hand-run in the morning silently SKIPPED every VM test as "past the deadline". A test that never
# runs must not look like a deadline that worked.
next_epoch(){ e="$(date -d "$1" +%s)"; [ "$e" -gt "$(date +%s)" ] || e=$((e + 86400)); echo "$e"; }
DEADLINE_EPOCH="$(next_epoch "$DEADLINE_HHMM")"
# ...and clamp it to the backup window. Rolling the cutoff to "tomorrow" is right for a 23:30 start
# and WRONG at 02:45, where it would license hour-long VM tests to begin fifteen minutes before the
# 03:00 backup. The engine holds a flock, so a contended backup is the one outcome a test must
# never cause — the deadline is whichever comes first.
BACKUP_GUARD=$(( $(next_epoch "$BACKUP_HHMM") - BACKUP_MARGIN ))
[ "$DEADLINE_EPOCH" -le "$BACKUP_GUARD" ] || DEADLINE_EPOCH="$BACKUP_GUARD"
# Checking the deadline only BETWEEN tests still lets a test started at 02:29 run an hour past it.
# Give each test the smaller of its own cap and the time actually left.
# Never returns less than 1: GNU `timeout 0` means NO LIMIT, so a deadline already in the past
# would have silently REMOVED the bound instead of tightening it. The floor is a backstop — the
# real protection is the past_deadline guard on each test, which skips rather than running.
budget(){ r=$(( DEADLINE_EPOCH - $(date +%s) )); [ "$r" -lt 1 ] && r=1
          [ "$r" -lt "$1" ] && echo "$r" || echo "$1"; }

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

PASS=0; FAIL=0; SKIP=0
say(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
ok(){   say "  [PASS] $*"; PASS=$((PASS+1)); }
no(){   say "  [FAIL] $*"; FAIL=$((FAIL+1)); }
skip(){ say "  [SKIP] $*"; SKIP=$((SKIP+1)); }
# NOTE: `timeout` is a binary and cannot execute a shell function, so it must be passed THROUGH
# this helper (asuser timeout N cmd), never wrapped around it (timeout N asuser cmd) — the latter
# fails with "timeout: failed to execute process", which is how T1 and T4 first "failed".
asuser(){ if [ "$(id -u)" = 0 ]; then runuser -u "$TC_USER" -- env HOME="$USER_HOME" "$@"; else "$@"; fi; }

# Stop starting new work once we are close to the backup window. Checked BETWEEN tests, so a long
# test that already began is allowed to finish rather than being killed halfway through a VM.
past_deadline(){ [ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]; }

mkdir -p "$(dirname "$REPORT")" 2>/dev/null || true
say "=== Timecrate overnight assurance — $HOST — $(date -Is) ==="
# Print the RESOLVED deadline, not the requested one: when the backup guard clamps it, the operator
# needs to see the instant actually in force rather than the string they asked for.
say "engine: $($TC version 2>/dev/null | head -1)   deadline: $(date -d "@$DEADLINE_EPOCH" '+%F %H:%M') (requested $DEADLINE_HHMM, backup $BACKUP_HHMM)"
say ""

# ---- T1: every kit on the remote, not just the newest -------------------------------------------
say "T1: verify EVERY kit on the remote (decrypt + signature + archive listing)"
# Guarded like every other test: T1 touches the engine too, and a late manual run must not start
# work that could still be holding the flock when the backup wants it.
# A pass needs BOTH a clean exit and a summary that accounts for every kit. The version this
# replaces treated only rc=124 as failure and accepted the OK marker on any other status, so a run
# that verified some kits, printed its summary and then died on a later remote or integrity error
# was reported as a pass — the suite's own silent-success pattern, at the verification boundary.
# Split into a function so it can be driven directly by the check suite rather than by inspection.
verify_verdict(){   # <rc> <output>   → 0 only if the run exited clean and verified == total > 0
  [ "$1" = 0 ] || return 1
  local sum v t
  sum="$(printf '%s' "$2" | grep -oE 'VERIFY OK: [0-9]+/[0-9]+ kit.*' | head -1)"
  [ -n "$sum" ] || return 1
  v="$(printf '%s' "$sum" | sed -nE 's|VERIFY OK: ([0-9]+)/.*|\1|p')"
  t="$(printf '%s' "$sum" | sed -nE 's|VERIFY OK: [0-9]+/([0-9]+).*|\1|p')"
  [ -n "$v" ] && [ "$v" = "$t" ] && [ "$v" -gt 0 ]
}
if past_deadline; then skip "T1 — past the deadline"; else
t1out="$(asuser timeout "$(budget 3600)" "$TC" verify --all 2>&1)"
t1rc=$?
printf '%s\n' "$t1out" | tail -25 >> "$REPORT"
if [ $t1rc -eq 124 ]; then no "verify --all hit its time budget before finishing"
elif verify_verdict "$t1rc" "$t1out"; then
  ok "$(printf '%s' "$t1out" | grep -oE 'VERIFY OK: [0-9]+/[0-9]+ kit.*' | head -1)"
else
  no "not every kit verified (rc=$t1rc) — $(printf '%s' "$t1out" | grep -E 'FAILED|VERIFY' | tail -1)"
fi
fi
say ""

# ---- T2: rebuild from the OLDEST kit (cross-version recovery) ------------------------------------
say "T2: full VM rebuild from the OLDEST kit on the remote (often written by an older version)"
if [ "${TIMECRATE_OVERNIGHT_SKIP_VM:-0}" = 1 ]; then
  skip "T2 — VM tests disabled (TIMECRATE_OVERNIGHT_SKIP_VM=1)"
elif past_deadline; then skip "T2 — past the deadline"; else
  # Name the kit we expect BEFORE the run, then assert the run actually used it. Asking for the
  # oldest and accepting any pass is how this test spent its whole life rebuilding the newest kit:
  # capstone-and-alert.sh ignored TIMECRATE_CAPSTONE_KIT entirely and nothing here checked.
  # Bounded like everything else. `list` reaches the remote, so a hung provider or a wedged engine
  # would block here BEFORE the budgeted capstone starts — outside the deadline, defeating it, and
  # potentially still holding on when the backup wants the flock. The one call in this file that
  # was not timeout-wrapped, which is exactly where the next hang would have been.
  oldest="$(asuser timeout "$(budget 120)" "$TC" list 2>/dev/null | head -1)"
  t2out="$(TIMECRATE_CAPSTONE_KIT=oldest TIMECRATE_CAPSTONE_VM=timecrate-overnight-old timeout "$(budget 3600)" bash "$CAPSTONE" 2>&1)"
  printf '%s\n' "$t2out" | tail -30 >> "$REPORT"
  if ! printf '%s' "$t2out" | grep -q 'CAPSTONE PASSED'; then
    no "oldest-kit rebuild FAILED: $(printf '%s' "$t2out" | grep -E 'CAPSTONE FAILED|\[FAIL\]' | head -1)"
  elif [ -z "$oldest" ]; then
    no "could not determine the oldest kit, so T2 proves nothing about cross-version recovery"
  elif ! printf '%s' "$t2out" | grep -qF "$oldest"; then
    no "T2 passed but did NOT rebuild the oldest kit ($oldest) — is TIMECRATE_CAPSTONE_KIT honoured?"
  else
    ok "rebuilt from the oldest kit ($oldest)"
  fi
fi
say ""

# ---- T3: is the scheduled job dependable, or was it lucky once? -----------------------------------
say "T3: three consecutive capstone runs on the newest kit (flakiness, not correctness)"
# Count what actually RAN separately from what passed. Judging "3/3" against runs the deadline
# skipped turns an incomplete night into a critical "the job is FLAKY" page — blaming the code for
# a clock, and contradicting the rule one section down that skips are warn, not fail.
t3pass=0; t3ran=0
for run in 1 2 3; do
  if [ "${TIMECRATE_OVERNIGHT_SKIP_VM:-0}" = 1 ]; then skip "T3 run $run — VM tests disabled"; continue; fi
  if past_deadline; then skip "T3 run $run — past the deadline"; continue; fi
  t3ran=$((t3ran+1))
  t3out="$(TIMECRATE_CAPSTONE_VM="timecrate-overnight-$run" timeout "$(budget 3600)" bash "$CAPSTONE" 2>&1)"
  if printf '%s' "$t3out" | grep -q 'CAPSTONE PASSED'; then
    t3pass=$((t3pass+1)); say "    run $run: PASSED"
  else
    say "    run $run: FAILED — $(printf '%s' "$t3out" | grep -E 'CAPSTONE FAILED|\[FAIL\]' | head -1)"
    printf '%s\n' "$t3out" | tail -20 >> "$REPORT"
  fi
done
if [ "$t3ran" = 0 ]; then
  say "    (T3 not run — no capstone executed this pass; the skips above carry it)"
elif [ "$t3pass" = "$t3ran" ]; then
  ok "$t3pass/$t3ran capstone runs passed — the timer job is repeatable"
else
  no "only $t3pass/$t3ran EXECUTED capstone runs passed — the scheduled job is FLAKY"
fi
say ""

# ---- T4: the GUI against the real engine, not a stub ----------------------------------------------
say "T4: GUI constructed against the REAL engine and the REAL remote (never done before)"
if past_deadline; then skip "T4 — past the deadline"
elif ! command -v xvfb-run >/dev/null 2>&1; then skip "T4 — xvfb-run not installed"; else
  # This script runs as ROOT, so a fixed /tmp name is a symlink target any local user can plant:
  # root would follow it and truncate whatever it points at. Private dir, restrictive mode, and
  # readable by TC_USER because the probe itself is executed through asuser.
  # The directory stays ROOT-owned. TC_USER only needs to READ the probe: the output redirection
  # below is performed by this (root) shell, not by the probe, so TC_USER never writes here.
  # Handing the directory over — as the first cut of this did — would recreate exactly the
  # root-writes-into-a-user-owned-dir symlink hole that was just closed in the capstone.
  T4DIR="$(mktemp -d)"; chmod 0755 "$T4DIR"
  T4PY="$T4DIR/tm-gui-real.py"; T4OUT="$T4DIR/tm-gui-real.out"
  cat > "$T4PY" <<'PY'
import importlib.util, importlib.machinery, os, sys
from gi.repository import Adw, GLib
spec = importlib.util.spec_from_loader("tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bad = []
class P(Adw.Application):
    def do_activate(self):
        w = m.Window(self); w.present(); st = {"n": 0}
        def step():
            st["n"] += 1
            if not w.status and st["n"] < 25: return True
            if not w.status: bad.append("window never read status from the real engine")
            else:
                # against the real remote these must be REAL values, not the stub's
                if not str(w.status.get("cloud_kits", "")).isdigit(): bad.append("cloud_kits not numeric: %r" % w.status.get("cloud_kits"))
                if not w.status.get("remote"): bad.append("no remote reported")
                if w.p_cloud.get_label() in ("UNREADABLE", "NO BACKUPS"): bad.append("cloud pill says %s against a live remote" % w.p_cloud.get_label())
                if len(w.kit_names) < 1: bad.append("kit list empty against a live remote")
                buf = w.logview.get_buffer()
                pane = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
                for s in ("BEGIN PGP PRIVATE", "access_token", "refresh_token"):
                    if s in pane: bad.append("activity pane leaked %s" % s)
            self.quit(); return False
        GLib.timeout_add(700, step)
P(application_id="dev.norvi.TimecrateRealProbe").run([])
for b in bad: print("ASSERT " + b)
sys.exit(1 if bad else 0)
PY
  chmod 0644 "$T4PY"   # root wrote it; the probe runs as TC_USER and must be able to read it
  if asuser timeout "$(budget 300)" env GUI="$(command -v timecrate-gui || echo /usr/bin/timecrate-gui)" \
       xvfb-run -a python3 "$T4PY" >"$T4OUT" 2>&1; then
    ok "the GUI renders live values from the real engine (kits, remote, no key material in the log pane)"
  else
    no "GUI against the real engine: $(grep ASSERT "$T4OUT" | head -1 || tail -2 "$T4OUT" | head -1)"
  fi
  rm -rf "$T4DIR"
fi
say ""

# ---- T5: can a failure actually reach anyone? ------------------------------------------------------
say "T5: alert path end to end (everything above is worthless if a failure cannot be delivered)"
if past_deadline; then skip "T5 — past the deadline"; else
# Require the EXIT STATUS to be zero and match the engine's actual delivery line. The version this
# replaces ignored the exit code and grepped case-insensitively for 'sent|delivered|ok' — where a
# bare, unanchored `ok` also matches "token", "broken" and, worst of all, "not ok". The one test
# whose whole purpose is to prove failures can be reported could therefore report its own failure
# as a pass. Engine prints: "<ts> [timecrate] delivered. If that did not arrive, the alert path is broken".
t5out="$(timeout "$(budget 120)" "$TC" alerts test 2>&1)"; t5rc=$?
if [ "$t5rc" -eq 0 ] && printf '%s' "$t5out" | grep -q '\[timecrate\] delivered\.'; then
  ok "a test alert was accepted by the notification route"
else
  no "the alert path did not confirm delivery (rc=$t5rc): $(printf '%s' "$t5out" | tail -1)"
fi
fi
say ""

# ---- teardown: nothing of ours may survive, least of all key material -----------------------------
# Only VMs THIS suite creates. `timecrate-capstone-vm` is the default name used by the separately
# scheduled quarterly capstone, and T2/T3 always override it with a timecrate-overnight-* name — so
# deleting it here could only ever destroy a VM belonging to a run this suite does not own,
# mid-drill, while that run is handling the escrowed key.
for vm in timecrate-overnight-old timecrate-overnight-1 timecrate-overnight-2 timecrate-overnight-3; do
  asuser timeout 120 multipass delete "$vm" --purge >/dev/null 2>&1 || true
done
# Capture the query's own status, not the pipeline's. Ending this in `|| true` made a wedged or
# timed-out daemon produce an empty `left` and therefore a PASS reading "every test VM destroyed" —
# certifying key cleanup the suite had in fact been unable to check. A host with no instances still
# prints the CSV header (verified 2026-08-04), so the header is what separates "nothing is
# running" from "nothing answered".
vm_csv="$(asuser timeout 60 multipass list --format csv 2>/dev/null)"; list_rc=$?
if [ "$list_rc" -ne 0 ] || ! printf '%s\n' "$vm_csv" | head -1 | grep -q '^Name,'; then
  no "could not verify VM teardown (multipass list rc=$list_rc) — test VMs holding the escrowed key may survive; check by hand"
else
  # Scoped to this suite's own VMs for the same reason: a concurrently running quarterly capstone
  # holding timecrate-capstone-vm is not a survivor of OUR teardown, and reporting it as one would page
  # about a healthy drill.
  left="$(printf '%s\n' "$vm_csv" | tail -n +2 | cut -d, -f1 | grep -E '^timecrate-overnight-' || true)"
  if [ -n "$left" ]; then
    no "VMs SURVIVED teardown and hold a copy of the escrowed key: $(printf '%s' "$left" | tr '\n' ' ')"
  else
    ok "every test VM destroyed (each held a copy of the escrowed key)"
  fi
fi

say ""
say "==== OVERNIGHT RESULT on $HOST: $PASS PASS / $FAIL FAIL / $SKIP SKIP ===="
say "full report: $REPORT"

# A skipped test is not a passed test. Reporting "all clear" for a run whose recovery tests never
# executed is the exact silent success this suite exists to catch: on 2026-08-03 four of eight
# checks were skipped and the summary still read all-clear, so the gap went unnoticed until it was
# looked for by hand. Skips alert as `warn` — quieter than a failure, never invisible.
if [ "$FAIL" -gt 0 ]; then SEV=critical; WHAT=FAILURES
elif [ "$SKIP" -gt 0 ]; then SEV=warn; WHAT="INCOMPLETE (tests skipped)"
else SEV=info; WHAT="all clear"; fi
printf 'Timecrate overnight assurance on %s: %s pass / %s fail / %s skip.\n\n%s\n\nFull report: %s\n' \
  "$HOST" "$PASS" "$FAIL" "$SKIP" "$(grep -E '^  \[(PASS|FAIL|SKIP)\]' "$REPORT" | tail -12)" "$REPORT" \
  | "$HERE/alert.sh" "$SEV" "Timecrate overnight $WHAT on $HOST" overnight 2>/dev/null || true
[ "$FAIL" -eq 0 ]
