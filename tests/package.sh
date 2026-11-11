#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Spencer Norton
#
# The packages, installed and upgraded under a real systemd. Starts a container whose PID 1 is
# systemd, installs timecrate and timecrate-gui there, and proves that
#   - a fresh install enables and starts every timer, and skips the capstone without multipass
#   - backup -> list -> verify -> restore -> prune works from the installed package, through the
#     installed units as well as by hand, and a failure reaches the alert command twice (from the
#     run, and from OnFailure=)
#   - the window starts headless against the installed engine and a real remote
#   - an upgrade (<version> -> <version>+test1) leaves every timer enabled and running, and a timer
#     the administrator disabled stays disabled
#   - and, as the control, that a package built the pre-3.0.0 way (--no-enable --no-start)
#     leaves the timers stopped after the same upgrade -- so the check above can fail.
#
#   tests/package.sh [deb-dir]
# With deb-dir, its timecrate and timecrate-gui packages are the ones installed first (the
# release artifacts); otherwise they are built from this tree. Needs docker. The container gets
# CAP_SYS_ADMIN and no AppArmor profile, which systemd needs to remount its own private cgroup
# namespace read-write; it is not privileged and sees no host device.
set -uo pipefail
PASS=0; FAIL=0
ok(){ echo "  [PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

inside(){
  export DEBIAN_FRONTEND=noninteractive
  # the version this tree builds as, so a release bump needs no edit here
  V="$(sed -n '1s/^timecrate (\([^)]*\)).*/\1/p' /src/debian/changelog)"
  echo "== P0: build $V, $V+test1, and a control built the pre-3.0.0 way =="
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends \
    debhelper dpkg-dev sudo xvfb xauth ca-certificates >/dev/null || { no "build tools not installable"; return; }
  build(){   # <name> <version> [old-rules]
    local d="/build/$1"; rm -rf "$d"; mkdir -p /build; cp -a /src "$d"
    sed -i "1s/([^)]*)/($2)/" "$d/debian/changelog"
    [ -n "${3:-}" ] && sed -i 's/^\tdh_installsystemd --restart-after-upgrade$/\tdh_installsystemd --no-enable --no-start/' "$d/debian/rules"
    (cd "$d" && dpkg-buildpackage -us -uc -b -d >/dev/null 2>&1) || { no "build of $2 failed"; return 1; }
    ls /build/timecrate_"$2"_all.deb /build/timecrate-gui_"$2"_all.deb >/dev/null
  }
  if [ -n "${DEBS:-}" ]; then
    A="$(ls /debs/timecrate_*_all.deb)"; AG="$(ls /debs/timecrate-gui_*_all.deb)"
  else
    build a "$V" && A="/build/timecrate_${V}_all.deb" AG="/build/timecrate-gui_${V}_all.deb"
  fi
  build b "$V+test1" && build c "$V+test2" old-rules || return
  dpkg-deb --ctrl-tarfile "/build/timecrate_$V+test1_all.deb" | tar -xO ./preinst 2>/dev/null \
    | grep -q 'deb-systemd-invoke stop' \
    && no "the new preinst stops units on upgrade" || ok "the preinst of an upgrade stops nothing"
  dpkg-deb --ctrl-tarfile "/build/timecrate_$V+test2_all.deb" | tar -xO ./preinst 2>/dev/null \
    | grep -q 'deb-systemd-invoke stop' \
    && ok "(control) the pre-3.0.0 rules do put a stop in preinst" || no "the control build has no preinst stop -- the check proves nothing"

  echo "== P1: a fresh install enables and starts every timer =="
  apt-get install -y -qq "$A" "$AG" >/tmp/p1.out 2>&1 || { no "install failed: $(tail -3 /tmp/p1.out)"; return; }
  for t in backup drill capstone; do
    [ "$(systemctl is-enabled "timecrate-$t.timer" 2>/dev/null)" = enabled ] \
      && [ "$(systemctl is-active "timecrate-$t.timer" 2>/dev/null)" = active ] \
      && ok "timecrate-$t.timer is enabled and running after install" \
      || no "timecrate-$t.timer after install: $(systemctl is-enabled "timecrate-$t.timer" 2>&1)/$(systemctl is-active "timecrate-$t.timer" 2>&1)"
  done
  systemctl start timecrate-capstone.service 2>/dev/null
  [ "$(systemctl show -p ConditionResult --value timecrate-capstone.service)" = no ] \
    && ! systemctl is-failed --quiet timecrate-capstone.service \
    && ok "without multipass the capstone is skipped, not failed" \
    || no "capstone without multipass: $(systemctl is-failed timecrate-capstone.service 2>&1)"

  echo "== P2: backup, list, verify, restore and prune from the installed package =="
  useradd -m alice
  mkdir -p /home/alice/data/sub /home/alice/data/cache /srv/remote
  chown alice: /srv/remote    # a folder destination is written by the account, never by root
  printf 'hello\n' > /home/alice/data/a.txt; printf 'deep\n' > "/home/alice/data/sub/with space.txt"
  printf 'junk\n' > /home/alice/data/scratch.tmp; printf 'cached\n' > /home/alice/data/cache/blob
  ln -s a.txt /home/alice/data/link; chown -R alice: /home/alice/data
  timecrate config set-user alice >/dev/null 2>&1 && grep -q '^TIMECRATE_USER=alice$' /etc/timecrate/timecrate.conf \
    && ok "config set-user pins the account in the shipped configuration" || no "config set-user did not pin the account"
  cat >> /etc/timecrate/timecrate.conf <<'CONF'
TIMECRATE_REMOTE=/srv/remote
TIMECRATE_MIN_MB=0
CONF
  TIL='~'; printf '%s/data\n' "$TIL" > /etc/timecrate/include   # a literal ~/: the engine expands it
  printf '*.tmp\n~/data/cache\n' > /etc/timecrate/exclude
  su alice -c 'timecrate init' >/tmp/p2i.out 2>&1 \
    && ok "init works as the user on a fresh install" || no "init as the user failed: $(tail -2 /tmp/p2i.out)"
  timecrate escrow-confirm >/dev/null 2>&1
  timecrate backup >/tmp/p2b.out 2>&1 && ok "a backup to a local-path remote completes" \
    || no "backup failed: $(tail -3 /tmp/p2b.out)"
  kit="$(su alice -c 'timecrate list' 2>/dev/null | tail -1)"
  [ -n "$kit" ] && [ -f "/srv/remote/$kit" ] && [ -f "/srv/remote/$kit.sha256" ] \
    && ok "the kit and its checksum are on the remote ($kit)" || no "no kit on the remote"
  su alice -c 'timecrate verify --all' >/tmp/p2v.out 2>&1 && grep -q 'VERIFY OK: 1/1' /tmp/p2v.out \
    && ok "verify --all, unprivileged, authenticates and decrypts it" || no "verify: $(tail -2 /tmp/p2v.out)"
  if timecrate restore "$kit" >/tmp/p2r.out 2>&1; then
    ext="$(ls -d /var/lib/timecrate/staging/restored-*/extracted/home/alice/data | tail -1)"
    [ -f "$ext/a.txt" ] && [ -f "$ext/sub/with space.txt" ] && [ -L "$ext/link" ] \
      && diff -r --exclude=scratch.tmp --exclude=cache /home/alice/data "$ext" >/dev/null \
      && ok "restore brings the data back byte for byte, symlink included" || no "restored tree differs"
    [ ! -e "$ext/scratch.tmp" ] && [ ! -e "$ext/cache" ] \
      && ok "and what the exclude list names stayed out" || no "excluded files are in the kit"
  else no "restore failed: $(tail -2 /tmp/p2r.out)"; fi
  timecrate recovery-drill >/tmp/p2d.out 2>&1 && ok "the recovery drill passes with the escrowed key alone" \
    || no "drill: $(tail -2 /tmp/p2d.out)"
  for _ in 1 2 3; do sleep 1; TIMECRATE_KEEP=2 TIMECRATE_KEEP_MONTHLY=0 TIMECRATE_KEEP_YEARLY=0 timecrate backup >/tmp/p2p.out 2>&1 || break; done
  [ "$(find /srv/remote -name '*.tar.zst.gpg' | wc -l)" = 2 ] && [ "$(find /srv/remote -name '*.sha256' | wc -l)" = 2 ] \
    && [ "$(find /srv/remote -name '*.meta.json' | wc -l)" = 2 ] \
    && ok "retention prunes to the newest two, sidecars and all" || no "after pruning: $(ls /srv/remote | tr '\n' ' ')"
  systemctl start timecrate-backup.service; systemctl is-failed --quiet timecrate-backup.service \
    && no "the backup unit failed: $(journalctl -u timecrate-backup.service -n 5 --no-pager)" \
    || { journalctl -u timecrate-backup.service --no-pager | grep -q 'backup complete' \
         && ok "the installed backup unit runs a backup, sandbox and all" || no "the backup unit did not complete"; }
  systemctl start timecrate-drill.service; systemctl is-failed --quiet timecrate-drill.service \
    && no "the drill unit failed: $(journalctl -u timecrate-drill.service -n 8 --no-pager)" \
    || ok "the installed drill unit passes (the drill, sweep included)"

  echo "== P3: a failure reaches the alert command, from the run and from OnFailure= =="
  cat > /usr/local/sbin/test-alert <<'HOOK'
#!/bin/sh
{ printf 'ARGS %s|%s|%s\n' "$1" "$2" "$3"; cat; } >> /var/log/test-alert.log
HOOK
  chmod 755 /usr/local/sbin/test-alert
  printf 'TIMECRATE_ALERT_CMD=/usr/local/sbin/test-alert\n' > /etc/timecrate.env; chmod 600 /etc/timecrate.env
  timecrate alerts test >/dev/null 2>&1 && grep -q '^ARGS critical|Timecrate alert test' /var/log/test-alert.log \
    && ok "alerts test delivers through the command" || no "alerts test did not reach the command"
  : > /var/log/test-alert.log
  printf 'TIMECRATE_INCLUDE=/nonexistent\n' >> /etc/timecrate.env
  systemctl start timecrate-backup.service; sleep 2
  grep -q '|backup$' /var/log/test-alert.log && ok "a failed scheduled backup alerts from inside the run" \
    || no "no in-run alert: $(cat /var/log/test-alert.log)"
  grep -q '|unit-timecrate-backup.service$' /var/log/test-alert.log && ok "and the OnFailure= unit alerts as well" \
    || no "no OnFailure alert: $(cat /var/log/test-alert.log)"
  printf 'TIMECRATE_ALERT_CMD=/usr/local/sbin/test-alert\n' > /etc/timecrate.env
  systemctl reset-failed timecrate-backup.service 2>/dev/null

  echo "== P4: the window starts headless against the installed engine =="
  cat > /tmp/probe.py <<'PY'
import importlib.machinery, importlib.util, os, sys
from gi.repository import Adw, GLib
spec = importlib.util.spec_from_loader("tcgui", importlib.machinery.SourceFileLoader("tcgui", "/usr/bin/timecrate-gui"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bad = []
class P(Adw.Application):
    def do_activate(self):
        w = m.Window(self); w.present(); st = {"n": 0}
        def step():
            st["n"] += 1
            if (not w.status or not w.kit_names) and st["n"] < 30: return True
            if not str(w.status.get("cloud_kits", "")).isdigit(): bad.append("cloud_kits %r" % w.status.get("cloud_kits"))
            if len(w.kit_names) < 1: bad.append("no kits listed")
            buf = w.logview.get_buffer()
            if "BEGIN PGP PRIVATE" in buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False): bad.append("key material in the log")
            self.quit(); return False
        GLib.timeout_add(500, step)
P(application_id="dev.norvi.TimecratePackageProbe").run([])
print("\n".join("ASSERT " + b for b in bad)); sys.exit(1 if bad else 0)
PY
  chmod 644 /tmp/probe.py
  su alice -c 'xvfb-run -a python3 /tmp/probe.py' >/tmp/p4.out 2>&1 \
    && ok "the window renders live kits and status from the installed engine" \
    || no "headless window: $(grep -E 'ASSERT|Error' /tmp/p4.out | head -2)"

  echo "== P5: an upgrade keeps the timers running; a disabled one stays disabled =="
  systemctl disable --now timecrate-drill.timer >/dev/null 2>&1
  apt-get install -y -qq "/build/timecrate_$V+test1_all.deb" "/build/timecrate-gui_$V+test1_all.deb" >/tmp/p5.out 2>&1 \
    || { no "upgrade failed: $(tail -3 /tmp/p5.out)"; return; }
  [ "$(dpkg-query -W -f '${Version}' timecrate)" = "$V+test1" ] && ok "upgraded to $V+test1" || no "not upgraded"
  for t in backup capstone; do
    [ "$(systemctl is-enabled "timecrate-$t.timer")" = enabled ] && [ "$(systemctl is-active "timecrate-$t.timer")" = active ] \
      && ok "timecrate-$t.timer is still enabled and running after the upgrade" \
      || no "UPGRADE TRAP: timecrate-$t.timer is $(systemctl is-enabled "timecrate-$t.timer")/$(systemctl is-active "timecrate-$t.timer") after the upgrade"
  done
  [ "$(systemctl is-enabled timecrate-drill.timer)" = disabled ] && ! systemctl is-active --quiet timecrate-drill.timer \
    && ok "the timer the administrator disabled stayed disabled" || no "the upgrade re-armed a disabled timer"
  grep -q '^TIMECRATE_USER=alice' /etc/timecrate/timecrate.conf && ok "the edited configuration survived the upgrade" \
    || no "the upgrade replaced the configuration"
  systemctl start timecrate-backup.service; systemctl is-failed --quiet timecrate-backup.service \
    && no "backup after the upgrade failed" || ok "and a backup still runs after the upgrade"

  echo "== P6: control -- the pre-3.0.0 rules DO disarm the timers on the same upgrade =="
  [ -e /usr/sbin/policy-rc.d ] && no "policy-rc.d is present, so no package script can start anything and P1/P5 prove nothing"
  systemctl is-active --quiet timecrate-backup.timer \
    || no "(control) the backup timer was not running before the control upgrade -- the control proves nothing"
  apt-get install -y -qq "/build/timecrate_$V+test2_all.deb" "/build/timecrate-gui_$V+test2_all.deb" >/dev/null 2>&1
  if systemctl is-active --quiet timecrate-backup.timer; then
    no "the control upgrade left the timer running -- P5 does not prove the fix"
  else
    ok "the control build stops the backup timer on upgrade and never restarts it (the trap is real)"
  fi
  echo "==== PACKAGE RESULT: $PASS PASS / $FAIL FAIL ===="
  [ "$FAIL" -eq 0 ]
}

if [ "${1:-}" = --inside ]; then inside; exit; fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${TIMECRATE_TEST_IMAGE:-ubuntu:26.04@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78}"
NAME="tc-package-$$"
# --mount, not -v: a bind whose source is missing must fail, not be created empty
debs=(); [ -n "${1:-}" ] && debs=(--mount "type=bind,src=$(cd "$1" && pwd),dst=/debs,readonly" -e DEBS=1)
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT
docker run -d --rm --name "$NAME" --pids-limit 4096 --cap-add SYS_ADMIN --security-opt apparmor=unconfined --cgroupns=private \
  --tmpfs /run --tmpfs /run/lock --mount "type=bind,src=$REPO,dst=/src,readonly" ${debs[@]+"${debs[@]}"} "$IMAGE" \
  bash -c 'export DEBIAN_FRONTEND=noninteractive
           # Container images forbid starting services from package scripts (policy-rc.d, exit 101);
           # a real machine has no such file, and this test is about what a real machine does.
           rm -f /usr/sbin/policy-rc.d
           apt-get update -qq && apt-get install -y -qq --no-install-recommends systemd systemd-sysv dbus >/dev/null
           mount -o remount,rw /sys/fs/cgroup
           exec /sbin/init' >/dev/null
for _ in $(seq 1 90); do
  state="$(docker exec "$NAME" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in running|degraded) break;; esac
  sleep 2
done
case "$state" in running|degraded) ;; *) echo "systemd did not come up in the container (state: ${state:-none})" >&2; exit 1;; esac
docker exec "$NAME" bash /src/tests/package.sh --inside
