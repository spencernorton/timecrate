#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Spencer Norton
#
# End-to-end proof in a THROWAWAY Multipass VM (Ubuntu 26.04, real systemd/apt):
#   install the built .debs -> init (GPG + ML-KEM-1024) -> hybrid backup to a remote ->
#   wipe the identity, keeping ONLY the escrow sheet -> import-key + pq import ->
#   restore from the remote -> reboot -> identity and kit still verify.
#
# The backup remote is a plain local path by default. To prove the real Google Drive
# leg instead, seed a signed-in rclone Drive config on the host and point at a
# throwaway Drive folder (the config is transferred as a file, never printed):
#   TIMECRATE_E2E_DRIVE_CONF=~/.config/timecrate/rclone-drive.conf \
#   TIMECRATE_E2E_DRIVE_PATH=gdrive:Backups/_e2e-test \
#     tests/vm-e2e.sh
# The VM is always deleted. Run scripts/build.sh first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM="timecrate-e2e-$$"
TOKEN="e2e-$(date +%s)-$RANDOM"
PASS=0; FAIL=0
ok(){ echo "  [PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
cleanup(){ multipass delete --purge "$VM" >/dev/null 2>&1 || true; [ -z "${WORK:-}" ] || rm -rf -- "$WORK"; }
trap cleanup EXIT

command -v multipass >/dev/null || { echo "multipass is required" >&2; exit 1; }
ls "$ROOT"/dist/timecrate_*_all.deb >/dev/null 2>&1 || { echo "no dist/*.deb — run scripts/build.sh first" >&2; exit 1; }

# snap-confined multipass can read $HOME but not /tmp: stage transfers inside the repo
WORK="$(mktemp -d "$ROOT/.e2e-work.XXXXXX")"
GUEST="$WORK/guest.sh"
cat > "$GUEST" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
PASS=0; FAIL=0
ok(){ echo "  [PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
TOKEN="$(cat ~/e2e/token)"; REMOTE="$(cat ~/e2e/remote)"; DRIVE_LEG="$(cat ~/e2e/drive-leg)"
export TIMECRATE_INCLUDE=/home/ubuntu/e2e/include TIMECRATE_EXCLUDE=/home/ubuntu/e2e/exclude
export TIMECRATE_REMOTE="$REMOTE" TIMECRATE_MIN_MB=0 TIMECRATE_CRYPTO=hybrid
[ "$DRIVE_LEG" = real ] && export TIMECRATE_DRIVE_CONF=/home/ubuntu/e2e/rclone-drive.conf

echo "S1: install the built packages"
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq ~/debs/timecrate_*_all.deb ~/debs/timecrate-gui_*_all.deb >/tmp/apt.log 2>&1 \
  && ok "timecrate + timecrate-gui installed" || { no "package install failed: $(tail -1 /tmp/apt.log)"; }
command -v timecrate >/dev/null && [ "$(timecrate version)" = "timecrate 3.1.2" ] \
  && ok "installed engine reports 3.1.2" || no "engine missing or wrong version"

echo "S2: init creates the GPG and PQ identities"
mkdir -p ~/e2e-data && printf 'marker %s\n' "$TOKEN" > ~/e2e-data/marker.txt
printf 'home/ubuntu/e2e-data\n' > ~/e2e/include; printf '' > ~/e2e/exclude
timecrate init >/tmp/init.log 2>&1 && [ -s ~/.config/timecrate/pq-secret.pem ] \
  && ok "init created GPG + ML-KEM-1024 keys" || no "init failed: $(tail -2 /tmp/init.log)"
PQFPR="$(timecrate pq status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["fpr"])')"

echo "S3: hybrid backup uploads a PQ-wrapped kit (leg: $DRIVE_LEG)"
sudo env TIMECRATE_INCLUDE="$TIMECRATE_INCLUDE" TIMECRATE_EXCLUDE="$TIMECRATE_EXCLUDE" \
  TIMECRATE_REMOTE="$REMOTE" TIMECRATE_MIN_MB=0 TIMECRATE_CRYPTO=hybrid \
  ${TIMECRATE_DRIVE_CONF:+TIMECRATE_DRIVE_CONF="$TIMECRATE_DRIVE_CONF"} \
  timecrate backup >/tmp/backup.log 2>&1 \
  && ok "backup completed" || no "backup failed: $(tail -2 /tmp/backup.log)"
KIT="$(timecrate list 2>/dev/null | tail -1)"
[ -n "$KIT" ] && ok "remote lists the kit: $KIT" || no "remote lists nothing"
timecrate verify --remote >/tmp/verify.log 2>&1 && grep -q 'VERIFY OK' /tmp/verify.log \
  && ok "kit on the remote verifies (PQ unwrap + signature)" || no "remote verify failed: $(tail -2 /tmp/verify.log)"

echo "S4: escrow sheet (TXT + PDF), then WIPE the identity and the data"
mkdir -p ~/escrow
timecrate escrow-doc ~/escrow/sheet.txt >/dev/null 2>&1
timecrate escrow-doc --format pdf ~/escrow/sheet.pdf >/dev/null 2>&1
[ -s ~/escrow/sheet.txt ] && [ "$(head -c 4 ~/escrow/sheet.pdf 2>/dev/null)" = '%PDF' ] \
  && ok "escrow sheet written as TXT and PDF" || no "escrow sheet missing (txt/pdf)"
grep -q 'PQ SECRET KEY' ~/escrow/sheet.txt && ok "sheet carries the PQ secret" || no "sheet lacks the PQ secret"
mv ~/.config/timecrate ~/identity-wiped
rm -rf ~/e2e-data
[ ! -e ~/.config/timecrate/pq-secret.pem ] && ok "identity wiped (only the sheet survives)" || no "wipe incomplete"

echo "S5: rebuild identity from the sheet alone, restore from the remote"
sed -n '/BEGIN PGP PRIVATE KEY BLOCK/,/END PGP PRIVATE KEY BLOCK/p' ~/escrow/sheet.txt > ~/escrow/secret.asc
sed -n '/BEGIN PGP PUBLIC KEY BLOCK/,/END PGP PUBLIC KEY BLOCK/p' ~/escrow/sheet.txt > ~/escrow/signing-pub.asc
sed -n '/--- PQ SECRET KEY/,/--- PQ PUBLIC KEY/p' ~/escrow/sheet.txt \
  | sed -n '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/p' > ~/escrow/pq.pem
timecrate import-key ~/escrow/secret.asc --signing-pub ~/escrow/signing-pub.asc --yes >/tmp/import.log 2>&1 \
  && ok "GPG identity imported from the sheet" || no "import-key failed: $(tail -2 /tmp/import.log)"
timecrate pq import ~/escrow/pq.pem >/tmp/pqimport.log 2>&1 \
  && [ "$(timecrate pq status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["fpr"])')" = "$PQFPR" ] \
  && ok "PQ identity imported from the sheet (same fingerprint)" || no "pq import failed: $(tail -2 /tmp/pqimport.log)"
TS="${KIT#timecrate-}"; TS="${TS%.tar.zst.gpg}"
sudo env TIMECRATE_REMOTE="$REMOTE" ${TIMECRATE_DRIVE_CONF:+TIMECRATE_DRIVE_CONF="$TIMECRATE_DRIVE_CONF"} \
  timecrate restore "$TS" >/tmp/restore.log 2>&1 \
  && ok "restore fetched and authenticated the kit" || no "restore failed: $(tail -2 /tmp/restore.log)"
FOUND="$(sudo find /var/lib/timecrate/staging -name marker.txt -path '*e2e-data*' 2>/dev/null | head -1)"
[ -n "$FOUND" ] && sudo grep -q "$TOKEN" "$FOUND" \
  && ok "restored marker carries the original token" || no "restored marker missing or wrong"
# the drill is the escrow proof: it must open the hybrid kit, not just classic ones
sudo env TIMECRATE_REMOTE="$REMOTE" ${TIMECRATE_DRIVE_CONF:+TIMECRATE_DRIVE_CONF="$TIMECRATE_DRIVE_CONF"} \
  timecrate recovery-drill /home/ubuntu/escrow/secret.asc >/tmp/drill.log 2>&1 \
  && grep -q 'RECOVERY DRILL PASSED' /tmp/drill.log \
  && ok "recovery drill passes against the hybrid kit" || no "drill failed: $(tail -2 /tmp/drill.log)"
echo "==== IN-VM RESULT: $PASS PASS / $FAIL FAIL ===="
[ "$FAIL" -eq 0 ]
EOS

echo "launching throwaway VM $VM (ubuntu 26.04)…"
multipass launch 26.04 --name "$VM" --cpus 2 --memory 2G --disk 15G >/dev/null
multipass exec "$VM" -- mkdir -p /home/ubuntu/debs /home/ubuntu/e2e
for d in "$ROOT"/dist/timecrate_*_all.deb "$ROOT"/dist/timecrate-gui_*_all.deb; do
  multipass transfer "$d" "$VM":/home/ubuntu/debs/
done
multipass transfer "$GUEST" "$VM":/home/ubuntu/e2e/guest.sh
multipass exec "$VM" -- bash -c "printf '%s' '$TOKEN' > ~/e2e/token"
if [ -n "${TIMECRATE_E2E_DRIVE_CONF:-}" ] && [ -n "${TIMECRATE_E2E_DRIVE_PATH:-}" ] && [ -f "${TIMECRATE_E2E_DRIVE_CONF:-}" ]; then
  # Confined Multipass cannot read hidden ~/.config paths; stage privately under WORK.
  install -m 600 "$TIMECRATE_E2E_DRIVE_CONF" "$WORK/rclone-drive.conf"
  multipass transfer "$WORK/rclone-drive.conf" "$VM":/home/ubuntu/e2e/rclone-drive.conf
  rm -f "$WORK/rclone-drive.conf"
  multipass exec "$VM" -- chmod 600 /home/ubuntu/e2e/rclone-drive.conf
  printf '%s' "$TIMECRATE_E2E_DRIVE_PATH" > "$WORK/remote"
  printf 'real' > "$WORK/leg"
else
  printf '/home/ubuntu/remote-store' > "$WORK/remote"
  printf 'stand-in (set TIMECRATE_E2E_DRIVE_CONF + TIMECRATE_E2E_DRIVE_PATH for the real Drive leg)' > "$WORK/leg"
fi
multipass transfer "$WORK/remote" "$VM":/home/ubuntu/e2e/remote
multipass transfer "$WORK/leg" "$VM":/home/ubuntu/e2e/drive-leg
rm -rf "$WORK"

echo "running the in-VM proof (install -> hybrid backup -> wipe -> escrow restore)…"
if multipass exec "$VM" -- bash /home/ubuntu/e2e/guest.sh 2>&1 | tee /tmp/vm-e2e.log | grep -E 'PASS|FAIL|RESULT|S[0-9]:'; then :; fi
grep -q 'IN-VM RESULT: .* 0 FAIL' /tmp/vm-e2e.log \
  && ok "in-VM disaster proof passed (see /tmp/vm-e2e.log)" || no "in-VM proof failed (see /tmp/vm-e2e.log)"

echo "rebooting the VM and re-checking from a cold boot…"
multipass restart "$VM" >/dev/null 2>&1 || { multipass stop "$VM" >/dev/null 2>&1; multipass start "$VM" >/dev/null; }
for _ in $(seq 1 36); do multipass exec "$VM" -- true >/dev/null 2>&1 && break; sleep 5; done
multipass exec "$VM" -- bash -c '
  systemctl is-enabled timecrate-backup.timer >/dev/null || { echo TIMER_FAIL; exit 1; }
  timecrate keys --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"pq_fpr\"], \"pq key gone\"" \
    || { echo KEYS_FAIL; exit 1; }
  export TIMECRATE_REMOTE="$(cat ~/e2e/remote)"
  [ -f ~/e2e/rclone-drive.conf ] && export TIMECRATE_DRIVE_CONF=/home/ubuntu/e2e/rclone-drive.conf
  timecrate verify --remote >/tmp/vfy.log 2>&1 || { echo VERIFY_FAIL; tail -3 /tmp/vfy.log; exit 1; }
  echo REBOOT_CHECK_OK' >/tmp/vm-e2e-reboot.log 2>&1 || true
if grep -q REBOOT_CHECK_OK /tmp/vm-e2e-reboot.log; then
  ok "after reboot: timers armed, PQ identity intact, kit on the remote still verifies"
else
  no "after-reboot check failed: $(tail -3 /tmp/vm-e2e-reboot.log | tr '\n' ' ')"
fi

echo "==== VM-E2E RESULT: $PASS PASS / $FAIL FAIL (VM $VM deleted) ===="
[ "$FAIL" -eq 0 ]
