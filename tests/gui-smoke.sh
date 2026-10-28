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
      if [ -n "${TC_STUB_NOREMOTE:-}" ]; then
        printf '{"remote":"","name":"","type":"","configured":false,"has_token":false,"token_expiry":"","account":"","reachable":false,"kits":"","last_backup":"","rclone_config":"/x/rclone.conf","remote_quota_used":"","remote_quota_total":""}\n'
      else
        printf '{"remote":"dropbox:Backup/TIMECRATE","name":"dropbox","type":"dropbox","configured":true,"has_token":true,"token_expiry":"2027-01-01T00:00:00Z","account":"a@b.c","reachable":true,"kits":"13","last_backup":"2026-07-29T03:11:16-06:00","rclone_config":"/x/rclone.conf","remote_quota_used":"35060522191","remote_quota_total":"4412407808000"}\n'
      fi
    fi ;;
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
                    if "04:17:00" not in label:
                        failures.append("custom calendar '*-*-* 04:17:00' displayed as %r" % label)
                    if choices[row.get_selected() - 1][0] != "*-*-* 04:17:00":
                        failures.append("custom calendar would be saved as %r"
                                        % (choices[row.get_selected() - 1][0],))
                    if state["dlg2"]._schedule_baseline.get("backup") != row.get_selected():
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

echo "==== GUI RESULT: $PASS PASS / $FAIL FAIL ===="
[ "$FAIL" -eq 0 ]
