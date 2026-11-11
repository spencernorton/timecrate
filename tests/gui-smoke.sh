#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Spencer Norton
#
# Headless smoke test for the GTK4 front-end.
#
# A GUI that only fails at runtime is a GUI nobody tested: every widget here is constructed by
# PyGObject at import/instantiation time, so a wrong libadwaita signature or a widget that does
# not exist in the shipped runtime is invisible until someone opens the window. This builds the
# real window and the real settings dialog against a stub CLI under Xvfb.
#
#   docker run --rm -v "$PWD":/repo:ro -e REPO=/repo ubuntu:26.04 bash /repo/tests/gui-smoke.sh
#
# Set SHOT=/path/dir to also write screenshots (needs imagemagick).
set -uo pipefail
PASS=0; FAIL=0
ok(){ echo "  [PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

export DEBIAN_FRONTEND=noninteractive
# NOT silenced, and time-boxed: sending these to /dev/null turned a hung apt into a job that
# printed nothing for thirty minutes and then died of the CI timeout, with no way to tell a
# broken mirror from a broken test. Fail in five minutes with a reason instead.
timeout 300 apt-get update -qq || { echo "[FAIL] apt-get update failed or timed out"; exit 1; }
timeout 300 apt-get install -y -qq xvfb python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 \
  ${SHOT:+imagemagick x11-apps} || { echo "[FAIL] apt-get install failed or timed out"; exit 1; }

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
GUI="$REPO/gui/timecrate-gui"

# Stub CLI: the front-end must render from exactly what `timecrate` prints, so the stub is the
# contract. Values are chosen to exercise the states that used to be wrong -- an unreadable
# remote, a never-run drill, unconfirmed escrow, local kits left behind by a failed upload.
mkdir -p /tmp/gs/bin
cat > /tmp/gs/bin/timecrate <<'STUB'
#!/bin/sh
# every call is appended here when asked, so a test can assert on what the window sent
[ -z "${TC_STUB_LOG:-}" ] || echo "$*" >> "$TC_STUB_LOG"
# the engine warns on stderr, on any call (a setting it ignored, say): no view may read that as data
echo "2026-07-29T03:00:00-06:00 [timecrate][WARN] stub: one warning on every call" >&2
# TC_STUB_HOSTILE: the same answers with an ampersand and angle brackets in every name the window
# shows. Rows, toasts and banners read their text as Pango markup unless told otherwise, and text
# that does not parse is dropped: the row stays blank.
if [ -n "${TC_STUB_HOSTILE:-}" ] && [ -z "${TC_STUB_INNER:-}" ]; then
  TC_STUB_INNER=1 "$0" "$@" | sed -e 's#Backup/TIMECRATE#R\&D/<TIMECRATE>#g' -e 's#a@b\.c#A \& B <ab>#g' \
    -e 's#My Backups#R\&D <new>#g' -e 's#~/Documents#~/R\&D <docs>#g' -e 's#/home/user/project-a#/home/user/a\&b#g' \
    -e 's#"/etc/timecrate/timecrate.conf"#"/etc/time\&crate/<conf>"#g' \
    -e 's#"reachable":true#"drive_signed_in":true,"drive_remote":"gdrive","reachable":true#'
  exit 0
fi
case "$1 $2" in
  "status --json") cat <<'J'
{"version":"3.0.0","remote":"dropbox:Backup/TIMECRATE","remote2":"","cipher":"AES-256 (AES-NI)",
 "keytype":"RSA-4096","key_fpr":"61A052AB0000000000000000000000000000069F2","escrow_confirmed":false,
 "last_backup":"2026-07-29T03:11:16-06:00 timecrate-2026-07-29_03-10-50.tar.zst.gpg",
 "drill_last":"","local_kits":2,"staging":"/var/lib/timecrate/staging","expected_latest":"",
 "expected_kits":0,"conf_sources":["/etc/timecrate/timecrate.conf"],"user":"u",
 "include_file":"/etc/timecrate/include","exclude_file":"/etc/timecrate/exclude",
 "keep":14,"keep_monthly":12,"keep_yearly":3,"max_mb":2000,"min_mb":25,"zstd_level":19,
 "cloud_kits":"13","drill_next":"Sat 2026-08-01 01:57:45",
 "git_watch":"/home/user/project-a /home/user/project-b","cloud_bytes":"27262976","remote_quota_used":"1099511627776","remote_quota_total":"2199023255552",
 "last_backup_bytes":"18874368","previous_backup_bytes":"9437184"}
J
    ;;
  # oldest first, as the engine prints it: two kits written before 3.0.0 (the previous name),
  # then a new one. The third kit is double the second: the deviation marker is the reason sizes
  # are here at all.
  "list --long") printf '9437184\t2026-07-27 03:00:11\ttimemachine-2026-07-27_03-00-11.tar.zst.gpg\n9437184\t2026-07-28 03:00:42\ttimemachine-2026-07-28_03-00-42.tar.zst.gpg\n18874368\t2026-07-29 03:10:50\ttimecrate-2026-07-29_03-10-50.tar.zst.gpg\n' ;;
  "list "*|"list") printf 'timemachine-2026-07-27_03-00-11.tar.zst.gpg\ntimemachine-2026-07-28_03-00-42.tar.zst.gpg\ntimecrate-2026-07-29_03-10-50.tar.zst.gpg\n' ;;
  "schedule "*|"schedule")
    if [ -n "${TC_STUB_CUSTOM:-}" ]; then
      # a valid OnCalendar the window offers no preset for -- displaying this as "Daily" would be
      # the window asserting a schedule that is not the one running
      printf 'Scheduled runs\n  backup   enabled   *-*-* 04:17:00              next: Thu 2026-07-30\n  drill    enabled   *-*-01 00:00:00            next: Sat 2026-08-01\n'
    else
      printf 'Scheduled runs\n  backup   enabled   *-*-* 03:00:00              next: Thu 2026-07-30\n  drill    enabled   *-*-01 00:00:00            next: Sat 2026-08-01\n'
    fi ;;
  "remote status")
    if [ "$3" = "--json" ]; then
      if [ -n "${TC_STUB_LOCAL:-}" ]; then
        printf '{"remote":"/media/alice/Backup/TIMECRATE","name":"","type":"local","configured":true,"has_token":false,"token_expiry":"","account":"","reachable":true,"kits":"4","last_backup":"","rclone_config":"/x/rclone.conf","remote_quota_used":"1000","remote_quota_total":"2000"}\n'
      elif [ -n "${TC_STUB_SFTP:-}" ]; then
        printf '{"remote":"nas:backups","name":"nas","type":"sftp","configured":true,"has_token":false,"token_expiry":"","account":"","reachable":true,"kits":"2","last_backup":"","rclone_config":"/x/rclone.conf","remote_quota_used":"","remote_quota_total":""}\n'
      elif [ -n "${TC_STUB_NOREMOTE:-}" ]; then
        printf '{"remote":"","name":"","type":"","configured":false,"has_token":false,"token_expiry":"","account":"","reachable":false,"kits":"","last_backup":"","rclone_config":"/x/rclone.conf","remote_quota_used":"","remote_quota_total":""}\n'
      else
        printf '{"remote":"dropbox:Backup/TIMECRATE","name":"dropbox","type":"dropbox","configured":true,"has_token":true,"token_expiry":"2027-01-01T00:00:00Z","account":"a@b.c","reachable":true,"kits":"13","last_backup":"2026-07-29T03:11:16-06:00","rclone_config":"/x/rclone.conf","remote_quota_used":"35060522191","remote_quota_total":"4412407808000"}\n'
      fi
    fi ;;
  "remote list")
    if [ -n "${TC_STUB_NOREMOTES:-}" ]; then echo '[]'
    else printf '[{"name":"dropbox","type":"dropbox"},{"name":"nas","type":"sftp"}]\n'; fi ;;
  "remote set-path"|"remote set-mirror")
    case " $* " in
      *" --dry-run "*) printf '[timecrate] DRY RUN: would repoint\n[timecrate] 13 backup(s) at the current path, 0 at %s\n' "$3" ;;
      *) echo "[timecrate] done" ;;
    esac ;;
  "remote browse")
    # path-dependent, so an interleaved reply is detectable
    case "$3" in
      *TIMECRATE) printf '["INNER_ONE","INNER_TWO"]\n' ;;
      *) printf '["Apps","My Backups","TIMECRATE"]\n' ;;
    esac ;;
  "history --json") printf '[{"when":"2026-07-01T03:00:00-06:00","kind":"backup","result":"ok","name":"x","bytes":"","seconds":""},{"when":"2026-07-02T03:00:00-06:00","kind":"backup","result":"ok","name":"y","bytes":"11748704","seconds":"26"},{"when":"2026-07-03T01:00:00-06:00","kind":"drill","result":"FAILED","bytes":"","seconds":"","name":"y"}]\n' ;;
  "alerts --json") printf '{"readable":false,"configured":"","command":"","severity":"critical","secrets_file":"/etc/timecrate.env"}\n' ;;
  "paths include") [ "$3" = list ] && printf 'etc\nroot\n~/Documents\n' ;;
  "paths exclude") [ "$3" = list ] && printf 'var/cache\n' ;;
  "keys --json")
    if [ -n "${TC_STUB_NOKEY:-}" ]; then
      printf '{"encryption_fpr":"","encryption_secret_present":false,"signing_fpr":"","signing_secret_present":false,"signing_public_present":false,"escrow_state":"none","escrow_fpr":"","escrow_when":"","escrow_file_on_box":false}\n'
    else
      # encrypt-only (post-harden) with a STALE escrow: the two states most easily misreported
      printf '{"encryption_fpr":"AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555","encryption_secret_present":false,"signing_fpr":"9999888877776666555544443333222211110000","signing_secret_present":true,"signing_public_present":true,"escrow_state":"confirmed","escrow_fpr":"0000000000000000000000000000000000000000","escrow_when":"2026-01-01T00:00:00-06:00","escrow_file_on_box":true}\n'
    fi ;;
  *) echo "stub: unhandled '$*'" >&2; exit 2 ;;
esac
STUB
chmod +x /tmp/gs/bin/timecrate
export PATH="/tmp/gs/bin:$PATH"
# a directory the allow-list will see as a plain path but which resolves to / — the shape a
# string comparison against "/" would wave through
ln -sfn / /tmp/gs/slip

cat > /tmp/gs/drive.py <<'PY'
import importlib.util, os, sys
from gi.repository import Adw, GLib, Gtk

spec = importlib.util.spec_from_loader(
    "tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
tcgui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tcgui)

shot_dir = os.environ.get("SHOT")
failures = []

class Probe(Adw.Application):
    def do_activate(self):
        win = tcgui.Window(self)
        win.present()
        state = {"phase": 0}

        def step():
            try:
                if state["phase"] == 0:
                    # status/list are async; give them a turn, then assert what rendered
                    if not win.status:
                        return True
                    if win.p_cloud.get_label() != "13 KITS":
                        failures.append("cloud pill is %r, expected '13 KITS'" % win.p_cloud.get_label())
                    if win.p_drill.get_label() != "NEVER RUN":
                        failures.append("drill pill is %r for an empty drill_last" % win.p_drill.get_label())
                    if win.p_escrow.get_label() != "ACTION NEEDED":
                        failures.append("escrow pill is %r for escrow_confirmed=false" % win.p_escrow.get_label())
                    if "2 kept" not in win.r_local.get_subtitle():
                        failures.append("local copies row ignored local_kits=2: %r" % win.r_local.get_subtitle())
                    if "timecrate.conf" not in win.r_conf.get_subtitle():
                        failures.append("config row does not name the loaded file: %r" % win.r_conf.get_subtitle())
                    if len(win.kit_names) != 3:
                        failures.append("kit list has %d rows, expected 3" % len(win.kit_names))
                    if win.kit_stack.get_visible_child_name() != "list":
                        failures.append("kit stack shows %r" % win.kit_stack.get_visible_child_name())
                    # sizes: the rows are newest-first, so row 0 is the 18 MB kit
                    if "18.0 MB" not in win.kit_rows[0].get_title():
                        failures.append("kit row shows no size: %r" % win.kit_rows[0].get_title())
                    if not win.kit_names[0].endswith(".tar.zst.gpg"):
                        failures.append("kit_names picked up a column, not a filename: %r"
                                        % win.kit_names[0])
                    # a kit written before 3.0.0 is a kit like any other: dated, restorable
                    old = "timemachine-2026-07-27_03-00-11.tar.zst.gpg"
                    if old not in win.kit_names:
                        failures.append("a kit of the previous name is missing from the list")
                    elif win._kit_display(old) == old:
                        failures.append("a kit of the previous name is not shown by its date")
                    if not win._allowed_args(["restore", old]):
                        failures.append("a kit of the previous name cannot be restored")
                    # a kit that doubled is flagged; one that did not move is not
                    if not win.kit_rows[0].flagged:
                        failures.append("a kit twice the size of its predecessor was not flagged")
                    if win.kit_rows[1].flagged:
                        failures.append("an unchanged kit was flagged as deviating")
                    desc = win.kit_group.get_description()
                    if "26.0 MB" not in desc:
                        failures.append("kit group does not state the total: %r" % desc)
                    if "1.0 TB of 2.0 TB" not in desc:
                        failures.append("kit group does not state the remote quota: %r" % desc)
                    if shot_dir:
                        os.system("import -window root %s/main.png 2>/dev/null" % shot_dir)
                    state["phase"] = 1
                    return True
                if state["phase"] == 1:
                    dlg = tcgui.SettingsDialog(win, win.status)
                    dlg.present(win)
                    state["dlg"] = dlg
                    state["phase"] = 2
                    return True
                if state["phase"] == 2:
                    dlg = state["dlg"]
                    if int(dlg.rows["TIMECRATE_KEEP"].get_value()) != 14:
                        failures.append("settings did not load keep=14")
                    # the destination is no longer a row here: the Remote page owns it, because
                    # two writers meant closing this dialog reverted a folder change
                    if "TIMECRATE_REMOTE" in dlg.rows:
                        failures.append("the Backup page still owns TIMECRATE_REMOTE — closing "
                                        "the dialog can revert a change made on the Remote page")
                    # the second remote is no longer offered as a free-text field; leaving it in
                    # `rows` would put it back into everything _save writes
                    if "TIMECRATE_REMOTE2" in dlg.rows:
                        failures.append("the second-remote field is still writable from settings")
                    # the watched-repo list is the one thing a "successful" backup silently does
                    # not save, so it must load AND be in the set _save writes
                    if "project-b" not in dlg.rows["TIMECRATE_GIT_WATCH"].get_text():
                        failures.append("git_watch did not load into settings: %r"
                                        % dlg.rows["TIMECRATE_GIT_WATCH"].get_text())
                    if "TIMECRATE_GIT_WATCH" not in [n for n, _k in tcgui.SETTINGS]:
                        failures.append("git_watch is editable but would never be written")
                    if dlg.schedule_rows["backup"][0].get_selected() != 2:
                        failures.append("schedule combo did not match '*-*-* 03:00:00' (got %d)"
                                        % dlg.schedule_rows["backup"][0].get_selected())
                    # systemd normalises `monthly` to `*-*-01 00:00:00`; the combo must still
                    # show Monthly, or the Schedule tab misreports what is actually configured
                    if dlg.schedule_rows["drill"][0].get_selected() != 1:
                        failures.append("normalised 'monthly' calendar did not map back to Monthly (got %d)"
                                        % dlg.schedule_rows["drill"][0].get_selected())
                    state["phase"] = 3
                    return True
                if state["phase"] == 3:
                    # the keys page loads asynchronously; this turn is the one that lets it
                    kp = state["dlg"].keys_page
                    if kp.p_enc.get_label() != "ENCRYPT ONLY":
                        failures.append("encryption pill is %r for a key with no secret half"
                                        % kp.p_enc.get_label())
                    if kp.p_escrow.get_label() != "STALE":
                        failures.append("escrow confirmed for ANOTHER key rendered as %r"
                                        % kp.p_escrow.get_label())
                    if not kp.hint.get_visible():
                        failures.append("encrypt-only machine got no 'cannot restore here' hint")
                    if kp.btn_export.get_sensitive():
                        failures.append("export offered on a box whose secret key is gone")
                    # the stub predates the PQ key: classic posture, no PQ pill, PDF offered
                    if kp.crypto_row.get_selected() != 0:
                        failures.append("crypto combo is %d for a classic machine"
                                        % kp.crypto_row.get_selected())
                    if kp.p_pq.get_label() != "NOT SET UP":
                        failures.append("pq pill is %r with no PQ key" % kp.p_pq.get_label())
                    if not kp.btn_sheet_pdf.get_sensitive():
                        failures.append("PDF recovery-sheet download not offered")
                    if not kp.btn_verify.get_sensitive():
                        failures.append("verify disabled despite a configured key")
                    # nothing that could carry key material may reach the activity pane
                    buf = win.logview.get_buffer()
                    pane = buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False)
                    for secret in ("BEGIN PGP PRIVATE", "access_token", "refresh_token"):
                        if secret in pane:
                            failures.append("activity pane contains %r" % secret)
                    state["phase"] = 34
                    return True
                if state["phase"] == 34:
                    titles = [r.get_title() for r in win.history_rows]
                    if len(titles) != 3:
                        failures.append("history shows %d runs, expected 3: %r" % (len(titles), titles))
                    # size/duration are absent on pre-1.9.0 lines: say so rather than render 0 B
                    if not any("not recorded" in t for t in titles):
                        failures.append("a run with no recorded size did not say so: %r" % titles)
                    if not any("11.2 MB in 26s" in t for t in titles):
                        failures.append("a run with size and duration rendered as %r" % titles)
                    drill = [r for r in win.history_rows if r.get_title().startswith("Recovery drill")]
                    if not drill:
                        failures.append("the drill run is missing from history: %r" % titles)
                    else:
                        # a FAILED drill must not wear the success icon
                        img = drill[0].get_first_child()
                        icons = []
                        def collect(w):
                            while w is not None:
                                if isinstance(w, Gtk.Image) and w.get_icon_name():
                                    icons.append(w.get_icon_name())
                                collect(w.get_first_child())
                                w = w.get_next_sibling()
                        collect(drill[0].get_first_child())
                        if "emblem-ok-symbolic" in icons:
                            failures.append("a FAILED drill is showing the success icon: %r" % icons)
                    alert = state["dlg"].alert_row.get_subtitle() or ""
                    if "cannot tell" not in alert:
                        failures.append("an unreadable secrets file rendered as %r" % alert)
                    if not win._allowed_args(["alerts", "test"]):
                        failures.append("alerts test is not in the privileged allow-list")
                    state["phase"] = 35
                    return True
                if state["phase"] == 35:
                    rp = state["dlg"].remote_page
                    if "dropbox:Backup/TIMECRATE" not in (rp.r_path.get_subtitle() or ""):
                        failures.append("remote page did not show the folder: %r" % rp.r_path.get_subtitle())
                    if rp.p_reach.get_label() != "OK":
                        failures.append("reachable pill is %r for a reachable remote" % rp.p_reach.get_label())
                    # the quota is reported by the provider; saying otherwise is the bug this
                    # field was added for
                    if "of" not in (rp.r_quota.get_subtitle() or ""):
                        failures.append("quota not rendered: %r" % rp.r_quota.get_subtitle())
                    if rp.btn_connect.get_label() != "Re-authorise…":
                        failures.append("connect button says %r for an already-configured remote"
                                        % rp.btn_connect.get_label())
                    # the provider choice starts from the configured remote (dropbox here), and
                    # Drive reports its own sign-in state beside it
                    if rp.provider_row.get_selected() != 1:
                        failures.append("provider combo is %d for a dropbox remote"
                                        % rp.provider_row.get_selected())
                    if "not signed in" not in (rp.r_drive.get_subtitle() or ""):
                        failures.append("drive row rendered %r with no Drive sign-in"
                                        % rp.r_drive.get_subtitle())
                    if "@" not in (rp.r_account.get_subtitle() or ""):
                        failures.append("account not shown: %r" % rp.r_account.get_subtitle())
                    # Reconnecting an existing Drive account must reach OAuth rather than
                    # fail the engine's existing-config guard. Capture without starting OAuth.
                    old_async = tcgui.run_async
                    calls = []
                    tcgui.run_async = lambda argv, callback: calls.append(argv)
                    rp.info["drive_configured"] = True
                    rp.provider_row.set_selected(0)
                    rp._connect()
                    tcgui.run_async = old_async
                    rp.provider_row.set_selected(1)
                    if not calls or "--reauthorize" not in calls[0]:
                        failures.append("Drive reconnect omitted --reauthorize: %r" % calls)
                    # nothing token-shaped may ever reach the UI
                    for w in (rp.r_token, rp.r_account, rp.r_path):
                        t = (w.get_subtitle() or "")
                        if "access_token" in t or "refresh_token" in t:
                            failures.append("token material rendered in %r" % t)
                    state["picker"] = tcgui.FolderPicker(win, "dropbox:Backup", lambda: None)
                    state["phase"] = 36
                    return True
                if state["phase"] == 36:
                    pk = state["picker"]
                    names = [r.get_title() for r in pk.rows()]
                    if "My Backups" not in names:
                        failures.append("folder picker lost a name with a space: %r" % names)
                    before = len(names)
                    pk._enter("TIMECRATE")
                    state["before"] = before
                    state["phase"] = 37
                    return True
                if state["phase"] == 37:
                    pk = state["picker"]
                    if not pk.path.endswith("Backup/TIMECRATE"):
                        failures.append("entering a folder gave path %r" % pk.path)
                    pk._up()
                    state["phase"] = 38
                    return True
                if state["phase"] == 38:
                    pk = state["picker"]
                    if pk.path != "dropbox:Backup":
                        failures.append("going up gave path %r" % pk.path)
                    # enter and immediately leave: two listings in flight at once
                    pk._enter("TIMECRATE")
                    pk._up()
                    state["phase"] = 39
                    return True
                if state["phase"] == 39:
                    pk = state["picker"]
                    names = [r.get_title() for r in pk.rows()]
                    if any(n.startswith("INNER_") for n in names):
                        failures.append("a superseded listing was applied: %r under %r"
                                        % (names, pk.path))
                    if len(pk.rows()) != state["before"]:
                        failures.append("row count %d after up, expected %d — rows are accumulating"
                                        % (len(pk.rows()), state["before"]))
                    state["phase"] = 4
                    return True
                if state["phase"] == 4:
                    if shot_dir:
                        os.system("import -window root %s/settings.png 2>/dev/null" % shot_dir)
                    # a schedule with no matching preset must be shown as itself, not rounded to
                    # the nearest canned choice
                    os.environ["TC_STUB_CUSTOM"] = "1"
                    state["dlg2"] = tcgui.SettingsDialog(win, win.status)
                    state["phase"] = 5
                    return True
                if state["phase"] == 5:
                    row, choices = state["dlg2"].schedule_rows["backup"]
                    label = row.get_model().get_string(row.get_selected())
                    if label != "Daily at a time you choose" \
                            or state["dlg2"].time_row.get_text() != "04:17":
                        failures.append("calendar '*-*-* 04:17:00' displayed as %r at %r"
                                        % (label, state["dlg2"].time_row.get_text()))
                    if state["dlg2"]._schedule_baseline.get("backup") != (row.get_selected(), "04:17"):
                        failures.append("custom calendar not in the baseline — closing the dialog "
                                        "would silently rewrite the schedule")
                    del os.environ["TC_STUB_CUSTOM"]
                    state["phase"] = 6
                    return True
                if state["phase"] == 6:
                    # Checks and recovery: the allow-list is the boundary between the window and
                    # a root process, so it is asserted directly rather than through the UI.
                    newest = win.kit_names[0]
                    cases = [
                        (["verify", "--remote"], False, "verify must NOT be privileged: it needs "
                         "no root, so an administrator prompt for a read-only check is theatre"),
                        (["restore", newest, "--to-root"], True, "restore --to-root on a listed kit"),
                        (["restore", "not-a-kit.tar.zst.gpg", "--to-root"], False,
                         "restore --to-root on a kit the remote never listed"),
                        (["restore", newest, "--to-root", "--allow-unsigned"], False,
                         "--to-root with the signature hatch appended"),
                        (["break-glass", "/definitely/not/here.gpg", "/tmp"], False,
                         "break-glass with a kit path that does not exist"),
                        (["break-glass", os.environ["GUI"], "/tmp"], True,
                         "break-glass with a real file and a real directory"),
                        (["break-glass", os.environ["GUI"], "/definitely/not/here"], False,
                         "break-glass with a target directory that does not exist"),
                        # / passes isdir and R_OK, and extracting a kit there overwrites the
                        # running system — the exact outcome restore --to-root gates behind a
                        # typed confirmation. Reaching it through a folder chooser is a bypass.
                        (["break-glass", os.environ["GUI"], "/"], False,
                         "break-glass targeting / — the ungated route to overwriting /"),
                        (["break-glass", os.environ["GUI"], "/tmp/gs/slip"], False,
                         "break-glass targeting a symlink that resolves to /"),
                    ]
                    for args, want, why in cases:
                        if win._allowed_args(args) != want:
                            failures.append("allow-list %s %r (%s)"
                                            % ("rejected" if want else "ACCEPTED", args, why))
                    for name in ("btn_verify_newest", "btn_verify_all", "btn_to_root",
                                 "btn_break_glass"):
                        if not hasattr(win, name):
                            failures.append("no %s button in Checks and recovery" % name)
                    # menu completeness: a Help entry that is listed but has no action is a
                    # menu item that does nothing when clicked
                    if not win.lookup_action("help"):
                        failures.append("the Help menu entry has no win.help action behind it")
                    state["phase"] = 7
                    return True
                if state["phase"] == 7:
                    # the typed confirmation must actually gate: enabled only on the exact word
                    win.confirm_restore_to_root()
                    dlg, entry = win._to_root_dialog, win._to_root_entry
                    if dlg.get_response_enabled("go"):
                        failures.append("restore-over-/ was armed before anything was typed")
                    entry.set_text("restore")
                    if dlg.get_response_enabled("go"):
                        failures.append("restore-over-/ armed on lowercase 'restore'")
                    entry.set_text("RESTORE")
                    if not dlg.get_response_enabled("go"):
                        failures.append("typing RESTORE did not arm the confirmation")
                    entry.set_text("")
                    if dlg.get_response_enabled("go"):
                        failures.append("clearing the entry left restore-over-/ armed")
                    dlg.close()
                    state["phase"] = 8
                    return True
            except Exception as exc:  # a raised GTK/Adw error is the thing we are hunting
                failures.append("%s: %s" % (type(exc).__name__, exc))
            self.quit()
            return False

        GLib.timeout_add(700, step)

app = Probe(application_id="dev.norvi.TimecrateSmoke")
app.run([])
for f in failures:
    print("ASSERT " + f)
sys.exit(1 if failures else 0)
PY

cat > /tmp/gs/firstrun.py <<'PY'
import importlib.util, os, sys
from gi.repository import Adw, GLib

spec = importlib.util.spec_from_loader(
    "tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
tcgui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tcgui)

failures = []

class Probe(Adw.Application):
    def do_activate(self):
        win = tcgui.Window(self)
        win.present()
        state = {"n": 0}

        def step():
            state["n"] += 1
            if state["n"] < 4 and not win._first_run_shown:
                return True
            if not win._first_run_shown:
                failures.append("a machine with NO key never offered the first-run choice - the "
                                "window would just render errors until someone found a terminal")
            self.quit()
            return False

        GLib.timeout_add(500, step)

app = Probe(application_id="dev.norvi.TimecrateFirstRun")
app.run([])
for f in failures:
    print("ASSERT " + f)
sys.exit(1 if failures else 0)
PY

echo "== G1: window + settings dialog construct and render against a stub CLI =="
export GUI
if xvfb-run -a --server-args="-screen 0 1100x950x24" python3 /tmp/gs/drive.py > /tmp/gs/out 2>&1; then
  ok "GUI builds, renders and reads the CLI correctly"
else
  sed 's/^/    /' /tmp/gs/out
  no "GUI smoke failed (above)"
fi
grep -q 'Traceback' /tmp/gs/out && no "python traceback during GUI run" || ok "no traceback"

echo "== G3: a machine with no key is offered its identity back, not an error screen =="
if TC_STUB_NOKEY=1 xvfb-run -a --server-args="-screen 0 1100x950x24" python3 /tmp/gs/firstrun.py > /tmp/gs/fr 2>&1; then
  ok "first-run choice is presented when no key is configured"
else
  sed 's/^/    /' /tmp/gs/fr
  no "first-run flow failed (above)"
fi

cat > /tmp/gs/contrast.py <<'CONTRAST'
"""Measure the status pills against WCAG AA in BOTH colour schemes.

They shipped readable in light and at 1.36-1.61:1 in dark -- unreadable, on a window whose entire
job is to tell you the state of your backups at a glance. Eyeballing a screenshot is what let that
through, so this computes the ratio instead: a named colour is resolved by asking GTK for it via
get_color(), and the tint is composited over the scheme's real window background.
"""
import importlib.util, importlib.machinery, os, sys
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk, Gdk, GLib

spec = importlib.util.spec_from_loader(
    "tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
tcgui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tcgui)

AA = 4.5
failures = []

def lin(c): return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
def lum(c): return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
def ratio(a, b):
    la, lb = lum(a), lum(b); hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
def rgba(spec_):
    c = Gdk.RGBA(); c.parse(spec_); return c

class Probe(Adw.Application):
    def do_activate(self):
        prov = Gtk.CssProvider()
        prov.load_from_data(b".timecrate-winbg{color:@window_bg_color;}")
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        # a REAL window: it is what installs the provider and reloads it on a scheme change
        win_tm = tcgui.Window(self)
        win_tm.present()
        win = Gtk.ApplicationWindow(application=self)
        box = Gtk.Box()
        probe = Gtk.Label(label="x"); probe.add_css_class("timecrate-winbg"); box.append(probe)
        pill_probes = {}
        for state in ("success", "warning", "error"):
            lbl = Gtk.Label(label="X")
            lbl.add_css_class("pill"); lbl.add_css_class(state)
            box.append(lbl); pill_probes[state] = lbl
        win.set_child(box); win.present()
        sm = Adw.StyleManager.get_default()

        def measure():
            for scheme, name in ((Adw.ColorScheme.FORCE_LIGHT, "light"),
                                 (Adw.ColorScheme.FORCE_DARK, "dark")):
                sm.set_color_scheme(scheme)
                # Read the palette the window ACTUALLY applied, and take each foreground off a real
                # pill widget rather than from the table. Measuring the tables instead passes even
                # when the scheme selection is broken -- which is exactly how this check first
                # shipped, green, against the bug it was written for.
                table = win_tm.pill_palette
                winbg = probe.get_color()
                alpha = float(table["alpha"])
                for state in ("success", "warning", "error"):
                    fg = pill_probes[state].get_color()
                    tint = rgba(table["%s_bg" % state])
                    eff = Gdk.RGBA()
                    eff.red = tint.red * alpha + winbg.red * (1 - alpha)
                    eff.green = tint.green * alpha + winbg.green * (1 - alpha)
                    eff.blue = tint.blue * alpha + winbg.blue * (1 - alpha)
                    eff.alpha = 1.0
                    r = ratio(fg, eff)
                    print("    %-5s %-8s %.2f:1" % (name, state, r))
                    if r < AA:
                        failures.append("%s %s pill is %.2f:1, below WCAG AA %.1f:1"
                                        % (name, state, r, AA))
            self.quit(); return False

        GLib.timeout_add(400, measure)

app = Probe(application_id="dev.norvi.TimecrateContrast")
app.run([])
for f in failures:
    print("ASSERT " + f)
sys.exit(1 if failures else 0)
CONTRAST

echo "== G4: the status pills are readable in BOTH colour schemes =="
if xvfb-run -a --server-args="-screen 0 900x700x24" python3 /tmp/gs/contrast.py > /tmp/gs/contrast.out 2>&1; then
  grep -E '^    ' /tmp/gs/contrast.out
  ok "every pill meets WCAG AA in light and dark"
else
  grep -E '^    |^ASSERT' /tmp/gs/contrast.out
  no "a status pill is below WCAG AA (above)"
fi

cat > /tmp/gs/revert.py <<'REVERT'
"""Closing the settings window must not undo a folder change made inside it.

The dialog writes every row it owns on close, using the values it read when it OPENED. While the
destination was also a text entry on the Backup page, changing the folder on the Remote page and
then closing the window wrote the old path back over it -- the change appeared to work and then
silently reverted. Only one page may own that setting.
"""
import importlib.util, importlib.machinery, os, sys, tempfile
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw, GLib

d = tempfile.mkdtemp(); os.environ["XDG_CONFIG_HOME"] = d
spec = importlib.util.spec_from_loader(
    "tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
tcgui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tcgui)

failures = []
NEW = "dropbox:Backup/SOMEWHERE_ELSE"

class Probe(Adw.Application):
    def do_activate(self):
        win = tcgui.Window(self)
        dlg = tcgui.SettingsDialog(win, {"remote": "dropbox:Backup/TIMECRATE", "keep": 14,
                                         "keep_monthly": 12, "keep_yearly": 3, "min_mb": 25,
                                         "max_mb": 2000, "zstd_level": 19, "conf_sources": []})
        def step():
            # what the Remote page does when a folder is chosen
            tcgui.write_user_config({"TIMECRATE_REMOTE": NEW})
            dlg._save()                       # what closing the dialog does
            path = tcgui.user_config_path()
            text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            if NEW not in text:
                failures.append("closing the settings dialog reverted the remote: %r"
                                % [l for l in text.splitlines() if "REMOTE" in l])
            self.quit(); return False
        GLib.timeout_add(900, step)

app = Probe(application_id="dev.norvi.TimecrateRevert")
app.run([])
for f in failures:
    print("ASSERT " + f)
sys.exit(1 if failures else 0)
REVERT

echo "== G5: closing the settings window does not undo a folder change =="
if xvfb-run -a --server-args="-screen 0 900x700x24" python3 /tmp/gs/revert.py > /tmp/gs/revert.out 2>&1; then
  ok "a remote set on the Remote page survives closing the dialog"
else
  grep -E '^ASSERT' /tmp/gs/revert.out
  no "the settings dialog reverted the remote (above)"
fi

cat > /tmp/gs/onlychanged.py <<'ONLY'
"""The settings window must write only what changed, and the path editor must be real.

Writing every row on close means the dialog re-asserts values it read when it OPENED, stamping
them over anything altered elsewhere in the meantime -- which is how closing it used to undo a
folder change made on the Remote page. Removing that one setting fixed the instance; writing only
the differences removes the class, so it is worth an assertion of its own.
"""
import importlib.util, importlib.machinery, os, sys, tempfile
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw, GLib

d = tempfile.mkdtemp(); os.environ["XDG_CONFIG_HOME"] = d
spec = importlib.util.spec_from_loader(
    "tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
tcgui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tcgui)

failures = []
STATUS = {"remote": "dropbox:Backup/TIMECRATE", "keep": 14, "keep_monthly": 12,
          "keep_yearly": 3, "min_mb": 25, "max_mb": 2000, "zstd_level": 19,
          "conf_sources": [], "version": "9.9.9", "user": "u",
          "include_file": "/etc/timecrate/include", "exclude_file": "/etc/timecrate/exclude"}

class Probe(Adw.Application):
    def do_activate(self):
        win = tcgui.Window(self)
        dlg = tcgui.SettingsDialog(win, STATUS)

        def step():
            path = tcgui.user_config_path()
            # touched nothing -> must write nothing at all
            dlg._save()
            if os.path.exists(path):
                failures.append("closing an untouched settings window still wrote %s: %r"
                                % (path, open(path, encoding="utf-8").read()))
            # change exactly one row -> only that key may appear
            dlg.rows["TIMECRATE_KEEP"].set_value(21)
            dlg._save()
            text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            keys = [l.split("=")[0] for l in text.splitlines() if "=" in l and not l.startswith("#")]
            if keys != ["TIMECRATE_KEEP"]:
                failures.append("changing one setting wrote %r" % keys)

            # the path editor must list what the engine reports, with a remove control per entry
            ed = tcgui.PathsEditor(win, "include", lambda: None)

            def check_editor():
                titles = [r.get_title() for r in ed.rows()]
                if titles != ["etc", "root", "~/Documents"]:
                    failures.append("path editor showed %r" % titles)
                # and it must go through the privileged allow-list, not the filesystem
                if not win._allowed_args(["paths", "include", "add", "/tmp/x"]):
                    failures.append("paths add is not in the privileged allow-list")
                if win._allowed_args(["paths", "../etc", "add", "/tmp/x"]):
                    failures.append("allow-list accepted a bogus list name")
                self.quit(); return False

            GLib.timeout_add(1200, check_editor)
            return False

        GLib.timeout_add(900, step)

app = Probe(application_id="dev.norvi.TimecrateOnlyChanged")
app.run([])
for f in failures:
    print("ASSERT " + f)
sys.exit(1 if failures else 0)
ONLY

echo "== G6: settings write only what changed, and the path editor is real =="
if xvfb-run -a --server-args="-screen 0 900x700x24" python3 /tmp/gs/onlychanged.py > /tmp/gs/only.out 2>&1; then
  ok "an untouched dialog writes nothing; a changed row writes only itself; the editor lists the engine's entries"
else
  grep -E '^ASSERT' /tmp/gs/only.out
  no "settings/path-editor behaviour is wrong (above)"
fi

cat > /tmp/gs/schedonly.py <<'SCHEDONLY'
"""A change to only the schedule rows must reach the privileged queue, and a bad entry must
apply nothing. The save used to return early when no other setting had changed."""
import importlib.util, importlib.machinery, os, sys, tempfile
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw, GLib

d = tempfile.mkdtemp(); os.environ["XDG_CONFIG_HOME"] = d
spec = importlib.util.spec_from_loader(
    "tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
tcgui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tcgui)

failures = []
STATUS = {"remote": "dropbox:Backup/TIMECRATE", "keep": 14, "keep_monthly": 12,
          "keep_yearly": 3, "min_mb": 25, "max_mb": 2000, "zstd_level": 19, "conf_sources": []}

class Probe(Adw.Application):
    def do_activate(self):
        win = tcgui.Window(self)
        queued = []
        win.queue_privileged = lambda args, on_finished=None: queued.append(args)
        dlg = tcgui.SettingsDialog(win, STATUS)

        def step():
            path = tcgui.user_config_path()
            dlg.schedule_rows["backup"][0].set_selected(3)          # Weekly
            dlg._save()
            if queued != [["schedule", "backup", "on", "--at", "weekly"]]:
                failures.append("a schedule-only change queued %r" % queued)
            if os.path.exists(path):
                failures.append("a schedule-only change also wrote the config file")
            queued.clear()
            dlg._save()
            if queued:
                failures.append("the same schedule change was queued twice: %r" % queued)
            dlg.schedule_rows["drill"][0].set_selected(0)           # Off
            dlg._save()
            if queued != [["schedule", "drill", "off"]]:
                failures.append("turning the drill off queued %r" % queued)
            # an invalid size rail must apply nothing, schedule included
            queued.clear()
            dlg.schedule_rows["backup"][0].set_selected(4)          # Hourly
            dlg.rows["TIMECRATE_MIN_MB"].set_value(5000)
            dlg._save()
            if queued or os.path.exists(path):
                failures.append("a rejected save was half-applied: %r" % queued)
            self.quit(); return False

        GLib.timeout_add(900, step)

app = Probe(application_id="dev.norvi.TimecrateSchedOnly")
app.run([])
for f in failures:
    print("ASSERT " + f)
sys.exit(1 if failures else 0)
SCHEDONLY

echo "== G7: a schedule-only change is saved, and a rejected save applies nothing =="
if xvfb-run -a --server-args="-screen 0 900x700x24" python3 /tmp/gs/schedonly.py > /tmp/gs/sched.out 2>&1; then
  ok "schedule changes reach the privileged queue with no other setting changed"
else
  grep -E '^ASSERT|Error' /tmp/gs/sched.out
  no "a schedule-only change is lost or a rejected save is half-applied (above)"
fi

cat > /tmp/gs/features.py <<'FEATURES'
"""Destinations, the second copy, the daily time, pause, the account pin and their allow-list."""
import importlib.util, importlib.machinery, json, os, sys, tempfile
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw, GLib

os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
spec = importlib.util.spec_from_loader(
    "tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
tcgui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tcgui)

failures = []
finished = []       # a script that stops early must not read as a pass
LOG = os.environ["TC_STUB_LOG"]
LOCAL = "/media/alice/Backup/TIMECRATE"

def sent():
    with open(LOG, encoding="utf-8") as fh:
        return [l.strip() for l in fh if l.startswith("remote set-")]

def check(cond, msg):
    if not cond:
        failures.append(msg)

class Probe(Adw.Application):
    def do_activate(self):
        win = tcgui.Window(self)
        win.present()

        def script():
            while not win.status:
                yield
            base = dict(win.status)
            queued = []
            real_queue = win.queue_privileged
            win.queue_privileged = lambda args, on_finished=None: queued.append(args)

            # ---- F + E: banners on the main window
            def feed(**kw):
                win._on_status(True, json.dumps(dict(base, **kw)))
            feed()
            check(not win.pin_banner.get_revealed(), "pin banner shown with user_pinned missing")
            feed(user_pinned=True)
            check(not win.pin_banner.get_revealed(), "pin banner shown with user_pinned true")
            check(not win.pause_banner.get_revealed(), "pause banner shown while not paused")
            feed(user_pinned=False)
            check(win.pin_banner.get_revealed(), "no pin banner with user_pinned false")
            check("not tied to this account" in win.pin_banner.get_title(),
                  "pin banner says %r" % win.pin_banner.get_title())
            win.pin_banner.emit("button-clicked")
            check(queued == [["config", "set-user", GLib.get_user_name()]],
                  "pin button sent %r" % queued)
            queued.clear()
            feed(paused_until="2026-11-20T03:00:00-06:00")
            check(win.pause_banner.get_revealed()
                  and "paused until 2026-11-20 03:00:00" in win.pause_banner.get_title(),
                  "pause not shown: %r" % win.pause_banner.get_title())
            win.pause_banner.emit("button-clicked")
            check(queued == [["pause", "off"]], "Resume sent %r" % queued)
            queued.clear()
            feed(paused_until="")
            check(not win.pause_banner.get_revealed(), "pause banner stayed after the pause ended")

            # ---- G: the privileged allow-list
            for args, want in (
                    (["pause", "3d"], True), (["pause", "90m"], True), (["pause", "24h"], True),
                    (["pause", "30d"], True), (["pause", "off"], True),
                    (["pause", "31d"], False), (["pause", "0d"], False), (["pause", "3"], False),
                    (["pause", "3w"], False), (["pause", "-1d"], False), (["pause"], False),
                    (["pause", "3d", "--force"], False), (["pause", "off", "x"], False),
                    (["config", "set-user", "alice"], True),
                    (["config", "set-user", "-rf"], False), (["config", "set-user", "a b"], False),
                    (["config", "set-user", "a;b"], False), (["config", "set-user", ""], False),
                    (["config", "set-user"], False), (["config", "set-user", "a", "b"], False),
                    (["config", "show"], False)):
                check(win._allowed_args(args) == want,
                      "allow-list %s %r" % ("rejected" if want else "ACCEPTED", args))

            # ---- D + E: the Schedule page, from a calendar the presets do not cover
            os.environ["TC_STUB_CUSTOM"] = "1"
            dlg = tcgui.SettingsDialog(
                win, dict(base, paused_until="2026-11-20T03:00:00-06:00"))
            yield; yield
            del os.environ["TC_STUB_CUSTOM"]
            row, _choices = dlg.schedule_rows["backup"]
            labels = [row.get_model().get_string(i) for i in range(row.get_model().get_n_items())]
            check(labels[row.get_selected()] == "Daily at a time you choose"
                  and dlg.time_row.get_text() == "04:17" and dlg.time_row.get_visible(),
                  "04:17:00 shown as %r / %r" % (labels[row.get_selected()], dlg.time_row.get_text()))
            check(not any(l.startswith("Custom") for l in labels), "a Custom entry was added: %r" % labels)
            check(dlg.pause_row.get_model().get_string(dlg.pause_row.get_selected()).startswith(
                "Paused until 2026-11-20"), "running pause not shown on the Schedule page")
            dlg._save()
            check(queued == [], "an untouched dialog queued %r" % queued)
            dlg.time_row.set_text("21:30")
            dlg._save()
            check(queued == [["schedule", "backup", "on", "--at", "*-*-* 21:30:00"]],
                  "a new time queued %r" % queued)
            queued.clear()
            for bad in ("24:00", "12:60", "7", "ab:cd", ""):
                dlg.time_row.set_text(bad)
                dlg.pause_row.set_selected(2)                       # 3 days
                dlg._save()
                check(queued == [], "time %r was accepted (queued %r)" % (bad, queued))
                queued.clear()
            dlg.time_row.set_text("7:05")
            dlg._save()
            check(queued == [["schedule", "backup", "on", "--at", "*-*-* 07:05:00"], ["pause", "3d"]],
                  "valid time + pause queued %r" % queued)
            queued.clear()
            dlg.pause_row.set_selected(0)
            dlg._save()
            check(queued == [["pause", "off"]], "Not paused queued %r" % queued)
            queued.clear()
            win.queue_privileged = real_queue

            # ---- B: Remote page, default (dropbox) status
            rp = dlg.remote_page
            yield
            row_p = rp.provider_row
            kinds = [row_p.get_model().get_string(i) for i in range(row_p.get_model().get_n_items())]
            check(kinds[2:] == ["Folder on this computer or an attached drive",
                                "Another rclone remote"], "provider choices %r" % kinds)
            # the shared confirm flow, through the real picker, before anything is replaced
            done = []
            pk = tcgui.FolderPicker(win, "dropbox:Backup/TIMECRATE", lambda: done.append(1))
            yield
            pk._confirm()
            yield
            check("13 backup(s)" in win._dest_dialog.get_body(),
                  "the confirmation lost the engine's counts: %r" % win._dest_dialog.get_body())
            win._dest_dialog.emit("response", "use")
            yield
            check(done == [1], "choosing a folder did not finish")
            check(sent()[-2:] == ["remote set-path dropbox:Backup/TIMECRATE --dry-run",
                                  "remote set-path dropbox:Backup/TIMECRATE --yes"],
                  "set-path sequence %r" % sent())

            picks, real_local, real_pick = [], tcgui.choose_local_folder, tcgui.FolderPicker
            tcgui.choose_local_folder = lambda w, cb: picks.append(cb)
            row_p.set_selected(2)
            check(rp.row_connect.get_title() == "Choose a folder", "local row titled %r"
                  % rp.row_connect.get_title())
            sub = rp.row_connect.get_subtitle()
            check("writable by this account" in sub and "same disk" in sub,
                  "local help text %r" % sub)
            rp._connect()
            check(len(picks) == 1, "the local choice did not open a folder chooser")
            picks[0](LOCAL)
            yield; yield
            check("Use %s?" % LOCAL == win._dest_dialog.get_heading(), "confirm heading %r"
                  % win._dest_dialog.get_heading())
            win._dest_dialog.emit("response", "use")
            yield
            check(sent()[-2:] == ["remote set-path %s --dry-run" % LOCAL,
                                  "remote set-path %s --yes" % LOCAL],
                  "local set-path sequence %r" % sent())
            tcgui.choose_local_folder = real_local

            fake = []
            class FakePicker:
                def __init__(self, w, start, cb, mirror=False): fake.append((start, mirror))
                def present(self, *_): pass
            tcgui.FolderPicker = FakePicker
            row_p.set_selected(3)
            rp._connect()
            yield
            for r in ("r:dropbox", "r:nas"):
                check(win._remote_dialog.has_response(r), "no choice for %s" % r)
            win._remote_dialog.emit("response", "r:nas")
            check(fake == [("nas:", False)], "the remote choice opened %r" % fake)
            fake.clear()
            os.environ["TC_STUB_NOREMOTES"] = "1"
            rp._connect()
            yield
            del os.environ["TC_STUB_NOREMOTES"]
            check("rclone config" in win._remote_dialog.get_body()
                  and win._remote_dialog.has_response("close")
                  and not win._remote_dialog.has_response("r:nas"),
                  "empty remote list said %r" % win._remote_dialog.get_body())

            # ---- C: the second copy
            check(rp.mirror_row.get_title() == "Second copy"
                  and rp.mirror_row.get_subtitle() == "Off — backups go to one place",
                  "second copy row says %r" % rp.mirror_row.get_subtitle())
            win.status["remote2"] = "nas:Backup"
            rp._render_mirror()
            check(rp.mirror_row.get_subtitle() == "nas:Backup", "second copy shows %r"
                  % rp.mirror_row.get_subtitle())
            rp._change_mirror()
            check(rp._mirror_dialog.get_response_enabled("off"), "cannot turn the copy off")
            rp._mirror_dialog.emit("response", "off")
            yield
            check(sent()[-1] == "remote set-mirror off --yes", "turning off sent %r" % sent()[-1])
            check(rp.mirror_row.get_subtitle() == "Off — backups go to one place",
                  "second copy still shows %r after turning it off" % rp.mirror_row.get_subtitle())
            rp._change_mirror()
            check(not rp._mirror_dialog.get_response_enabled("off"),
                  "'Turn off' offered with no second copy")
            tcgui.choose_local_folder = lambda w, cb: picks.append(cb)
            picks.clear()
            rp._mirror_dialog.emit("response", "local")
            check(len(picks) == 1, "the second copy offered no folder chooser")
            picks[0]("/media/alice/Second")
            yield
            win._dest_dialog.emit("response", "use")
            yield
            check(sent()[-1] == "remote set-mirror /media/alice/Second --yes"
                  and not any("set-mirror" in l and "--dry-run" in l for l in sent()),
                  "local second copy sent %r" % sent()[-2:])
            check(rp.mirror_row.get_subtitle() != "Off — backups go to one place",
                  "second copy not shown after setting it")
            tcgui.choose_local_folder = real_local
            tcgui.choose_rclone_remote = lambda w, cb: cb("nas")
            rp._change_mirror()
            rp._mirror_dialog.emit("response", "rclone")
            check(fake == [("nas:", True)], "the second copy's remote choice opened %r" % fake)
            tcgui.FolderPicker = real_pick

            # ---- B: a local destination is shown as a folder, not as an account
            os.environ["TC_STUB_LOCAL"] = "1"
            lp = tcgui.RemotePage(win)
            yield; yield
            del os.environ["TC_STUB_LOCAL"]
            check(not lp.r_account.get_visible() and not lp.r_token.get_visible(),
                  "a local folder still shows Account / Authorisation")
            check(lp.r_path.get_title() == "Folder on this computer"
                  and lp.r_path.get_subtitle() == LOCAL, "local folder row: %r" % lp.r_path.get_subtitle())
            check(lp.p_reach.get_label() == "OK" and lp.btn_test.get_sensitive(),
                  "reachable/test lost for a local folder")
            check(not lp.btn_disconnect.get_sensitive(), "Forget offered for a local folder")
            check(lp.provider_row.get_selected() == 2, "provider is %d for a local folder"
                  % lp.provider_row.get_selected())
            picks.clear()
            tcgui.choose_local_folder = lambda w, cb: picks.append(cb)
            lp._browse()
            check(len(picks) == 1, "Browse on a local folder did not open the folder chooser")

            # ---- a remote of another kind is "another rclone remote". It was shown as Dropbox,
            # with a button that ran a Dropbox sign-in over it.
            os.environ["TC_STUB_SFTP"] = "1"
            sp = tcgui.RemotePage(win)
            yield; yield
            del os.environ["TC_STUB_SFTP"]
            check(sp.provider_row.get_selected() == 3 and sp.btn_connect.get_label() == "Choose remote…",
                  "an sftp remote is offered as provider %d, button %r"
                  % (sp.provider_row.get_selected(), sp.btn_connect.get_label()))
            calls, real_async = [], tcgui.run_async
            tcgui.run_async = lambda argv, cb: calls.append((argv, cb))
            fake.clear()
            tcgui.FolderPicker = FakePicker
            sp.provider_row.set_selected(1)
            check(sp.btn_connect.get_label() == "Connect…", "Dropbox beside an sftp remote offers %r"
                  % sp.btn_connect.get_label())
            sp._connect()
            tcgui.run_async = real_async
            # --reauthorize is safe to send: the engine keeps it from reaching a remote of another kind
            check(len(calls) == 1 and calls[0][0][1:] == ["remote", "connect", "--reauthorize"],
                  "Dropbox beside an sftp remote ran %r" % [c[0] for c in calls])
            # signed in under the provider's own name: which folder is the next decision
            calls[0][1](True, "connected as rclone remote 'dropbox'.")
            check(fake == [("dropbox:", False)], "after that sign-in the folder choice opened %r" % fake)
            # the same for the Drive sign-in's name with no sign-in behind it; a name that is
            # simply not set up yet is signed in where it is, so there is no folder to ask for
            for name, opened in (("gdrive", [("dropbox:", False)]), ("mybox", [])):
                sp.info = dict(sp.info, name=name, type="", configured=False, drive_remote="gdrive")
                calls.clear(); fake.clear()
                tcgui.run_async = lambda argv, cb: calls.append((argv, cb))
                sp._connect()
                tcgui.run_async = real_async
                calls[0][1](True, "connected.")
                check(fake == opened, "a sign-in beside the unset remote %r opened %r" % (name, fake))
            tcgui.FolderPicker = real_pick
            finished.append(1)
            self.quit()
            yield

        gen = script()

        def step():
            try:
                next(gen)
                return True
            except StopIteration:
                return False
            except Exception as exc:
                failures.append("%s: %s" % (type(exc).__name__, exc))
                self.quit()
                return False

        GLib.timeout_add(500, step)

app = Probe(application_id="dev.norvi.TimecrateFeatures")
app.run([])
if not finished:
    failures.append("the script stopped before its last check")
for f in failures:
    print("ASSERT " + f)
sys.exit(1 if failures else 0)
FEATURES

echo "== G8: destinations, second copy, daily time, pause, account pin =="
: > /tmp/gs/calls.log
if TC_STUB_LOG=/tmp/gs/calls.log xvfb-run -a --server-args="-screen 0 1100x950x24" python3 /tmp/gs/features.py > /tmp/gs/features.out 2>&1; then
  ok "the window offers and sends what the new engine commands expect"
else
  grep -E '^ASSERT|Error|Traceback' /tmp/gs/features.out
  no "destinations / second copy / schedule time / pause / pin misbehave (above)"
fi

echo "== G9: the project URL is current =="
if grep -rq 'spencercnorton' "$REPO/gui"; then no "stale project URL in gui/"; else ok "no stale project URL in gui/"; fi

echo "== G2: settings are written as a valid, re-readable shell config =="
python3 - <<'PY' && ok "config round-trips through the shell" || no "written config is not valid shell"
import importlib.machinery, importlib.util, os, subprocess, tempfile
d = tempfile.mkdtemp(); os.environ["XDG_CONFIG_HOME"] = d
spec = importlib.util.spec_from_loader(
    "tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# a remote with a space is the case an unquoted write turns into a syntax error
p = m.write_user_config({"TIMECRATE_REMOTE": "dropbox:My Backups/TC", "TIMECRATE_KEEP": 30})
out = subprocess.run(["bash", "-c", '. "$1"; echo "$TIMECRATE_REMOTE|$TIMECRATE_KEEP"', "_", p],
                     capture_output=True, text=True)
assert out.returncode == 0, out.stderr
assert out.stdout.strip() == "dropbox:My Backups/TC|30", out.stdout
# a second write must update in place, not append a duplicate
m.write_user_config({"TIMECRATE_KEEP": 7})
body = open(p).read()
assert body.count("TIMECRATE_KEEP=") == 1, body
assert "TIMECRATE_REMOTE=" in body, "second write dropped an unrelated setting"
PY

echo "== G8: no text in the window is read as markup =="
# Found on a real machine: the Remote page's Google Drive row was blank, because its text ends in
# "gdrive:<folder>" and GTK refused it as markup. The same went for a folder called "R&D" in the
# folder picker, a path with an ampersand in the include list, and any engine message that names
# <remote>:<path>. The stub answers with such names everywhere; GTK must reject nothing.
cat > /tmp/gs/markup.py <<'PY'
import importlib.util, importlib.machinery, os, sys, tempfile
import gi
gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")
from gi.repository import Adw, GLib

os.environ["XDG_CONFIG_HOME"] = tempfile.mkdtemp()
spec = importlib.util.spec_from_loader(
    "tcgui", importlib.machinery.SourceFileLoader("tcgui", os.environ["GUI"]))
tcgui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tcgui)
failures, finished = [], []

class Probe(Adw.Application):
    def do_activate(self):
        win = tcgui.Window(self)
        win.present()

        def script():
            while not (win.status and win.kit_names):
                yield
            if "R&D/<TIMECRATE>" not in (win.status.get("remote") or ""):
                failures.append("the stub is not in hostile mode: %r" % win.status.get("remote"))
            dlg = tcgui.SettingsDialog(win, win.status)
            dlg.present(win)
            while not dlg.remote_page.info:
                yield
            dlg.set_visible_page(dlg.remote_page)
            for _ in range(4):
                yield
            page = dlg.remote_page
            if "gdrive:<folder>" not in page.r_drive.get_subtitle():
                failures.append("the Google Drive row lost its text: %r" % page.r_drive.get_subtitle())
            if page.r_account.get_subtitle() != "A & B <ab>":
                failures.append("the account row shows %r" % page.r_account.get_subtitle())
            picker = tcgui.FolderPicker(win, "dropbox:", lambda *_: None)
            picker.present(win)
            for _ in range(6):
                yield
            if "R&D <new>" not in [r.get_title() for r in picker.rows()]:
                failures.append("the folder picker lost a folder: %r" % [r.get_title() for r in picker.rows()])
            picker._enter("R&D <new>")          # its path becomes the group's title
            for _ in range(6):
                yield
            picker.close()
            editor = tcgui.PathsEditor(win, "include", lambda *_: None)
            editor.present(win)
            for _ in range(6):
                yield
            editor.close()
            win.toast("Backups now go to dropbox:R&D/<TIMECRATE>")
            win._set_banner("backup failed: 'x' is not a remote path — it needs the form <remote>:<path> & more")
            win._on_kits(False, "it needs the form <remote>:<path>, e.g. dropbox:R&D\n")
            real_async = tcgui.run_async          # the coverage report, failing with such a path
            tcgui.run_async = lambda argv, cb, **kw: cb(False, "cannot read /home/user/a&b <x>")
            cov = tcgui.CoverageDialog(win)
            tcgui.run_async = real_async
            cov.present(win)
            for _ in range(6):
                yield
            finished.append(True)

        steps = script()
        def step():
            try:
                next(steps)
                return True
            except StopIteration:
                self.quit()
                return False
        GLib.timeout_add(250, step)
        GLib.timeout_add(60000, lambda: (failures.append("timed out"), self.quit())[1])

Probe(application_id="dev.norvi.TimecrateMarkup").run([])
if not finished:
    failures.append("the script did not reach its end")
for f in failures:
    print("ASSERT " + f)
sys.exit(1 if failures else 0)
PY
# The widgets keep the text they were given whether or not it could be drawn, so the script's own
# checks cannot see a blank row. GTK says so on stderr, and that is what is read here.
rejected(){ grep -h 'from markup due to error' "$@" 2>/dev/null | sed -E 's/.*Failed to set text/   /' | cut -c1-150 | sort -u; }
if TC_STUB_HOSTILE=1 xvfb-run -a --server-args="-screen 0 1100x950x24" python3 /tmp/gs/markup.py > /tmp/gs/markup.out 2>&1 \
   && [ -z "$(rejected /tmp/gs/markup.out)" ]; then
  ok "names with an ampersand or angle brackets are shown as they are"
else
  no "the window lost text that has an ampersand or angle brackets in it:"
  { grep ASSERT /tmp/gs/markup.out; rejected /tmp/gs/markup.out; } | head -8 | sed 's/^/    /'
fi
# ...and that goes for every scenario above, whatever it happened to show
if [ -z "$(rejected /tmp/gs/*.out /tmp/gs/out /tmp/gs/fr)" ]; then ok "GTK rejected no text as markup in any scenario"
else no "GTK rejected a text as markup in an earlier scenario: $(rejected /tmp/gs/*.out /tmp/gs/out /tmp/gs/fr | head -3)"; fi
# a row made straight from libadwaita reads the next name with an ampersand in it as markup
if grep -qE 'Adw\.(Action|Combo|Entry|Expander)Row\(' "$GUI"; then
  no "a row is made straight from libadwaita, not from the window's plain rows: $(grep -nE 'Adw\.(Action|Combo|Entry|Expander)Row\(' "$GUI" | head -3 | cut -c1-80)"
else ok "every row is one of the window's plain rows"; fi

echo "==== GUI RESULT: $PASS PASS / $FAIL FAIL ===="
[ "$FAIL" -eq 0 ]
