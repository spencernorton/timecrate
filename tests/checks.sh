#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Spencer Norton
#
# The cumulative regression suite. It installs packages, creates users and replaces rclone with
# fakes, so it runs as root in a throwaway ubuntu:26.04 container with the repo at /repo (or set
# REPO; CI runs it in place):
#   docker run --rm -v "$PWD":/repo:ro ubuntu:26.04 bash /repo/tests/checks.sh
PASS=0; FAIL=0
ok(){ echo "  [PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
# gpg-agent by name: an image where another package already pulled in gpg without its
# recommends has no agent, and every key operation then fails.
apt-get install -y -qq zstd gpg gpg-agent python3 acl shellcheck sudo >/dev/null 2>&1   # sudo: break-glass extracts through it

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
TC="$REPO/timecrate"
export TIMECRATE_USER=root
export TIMECRATE_CONF=/tmp/tm/conf
export TIMECRATE_STATE=/tmp/tm/state
export TIMECRATE_STAGING=/tmp/tm/staging
export TIMECRATE_LOCK=/tmp/tm/lock

echo "== T1: shellcheck at warning+ (style infos match pre-existing repo idiom) =="
if shellcheck -S warning -x -e SC1091,SC2029 "$TC" \
     "$REPO"/deploy/*.sh "$REPO"/tests/*.sh "$REPO"/scripts/*.sh > /tmp/sc.out 2>&1; then
  ok "shellcheck clean at warning severity"
else
  cat /tmp/sc.out; no "shellcheck warnings (above)"
fi
mkdir -p /tmp/tm   # lock/state parents (on a real box /run/lock exists)

echo "== T2: demo (crypto + fidelity round-trip) =="
if "$TC" demo >/tmp/demo.out 2>&1; then ok "demo PASS"; else no "demo failed: $(tail -3 /tmp/demo.out)"; fi

echo "== T3: broken include file dies loud =="
if TIMECRATE_INCLUDE=/nonexistent "$TC" backup --dry-run >/tmp/t3.out 2>&1; then
  no "backup --dry-run with missing include EXITED 0 (should die)"
else
  grep -q 'include file missing/unreadable' /tmp/t3.out && ok "missing include dies with clear error" || no "died but wrong error: $(tail -1 /tmp/t3.out)"
fi

echo "== T4: broken exclude file dies loud =="
if TIMECRATE_EXCLUDE=/nonexistent "$TC" backup --dry-run >/tmp/t4.out 2>&1; then
  no "backup --dry-run with missing exclude EXITED 0 (should die)"
else
  grep -q 'exclude file missing/unreadable' /tmp/t4.out && ok "missing exclude dies with clear error" || no "died but wrong error: $(tail -1 /tmp/t4.out)"
fi

echo "== T5: init generates encryption + STANDALONE signing keypairs, idempotently =="
mkdir -p /tmp/tm
if "$TC" init >/tmp/t5.out 2>&1 && [ -s /tmp/tm/conf/timecrate-secret.asc ]; then
  ok "init: encryption keypair + escrow file created"
else no "init failed: $(tail -3 /tmp/t5.out)"; fi
[ -s /tmp/tm/conf/signing.txt ] && [ -s /tmp/tm/conf/timecrate-signing-public.asc ] \
  && ok "init: signing fpr pinned + public key exported" || no "init: signing key artifacts missing"
sfpr1=$(cat /tmp/tm/conf/signing.txt 2>/dev/null)
efpr1=$(cat /tmp/tm/conf/recipients.txt 2>/dev/null)
[ -n "$sfpr1" ] && [ "$sfpr1" != "$efpr1" ] && ok "signing key is a SEPARATE key (not the encryption key)" || no "signing fpr equals encryption fpr (or empty)"
"$TC" init >/tmp/t5b.out 2>&1
[ "$(cat /tmp/tm/conf/signing.txt 2>/dev/null)" = "$sfpr1" ] && [ "$(cat /tmp/tm/conf/recipients.txt 2>/dev/null)" = "$efpr1" ] \
  && ok "second init run is idempotent (no key churn)" || no "second init MINTED NEW KEYS (escrow split!)"

echo "== T6: near-empty kit dies under the size floor =="
mkdir -p /tmp/tiny; echo hello > /tmp/tiny/f
printf 'tmp/tiny\n' > /tmp/inc.small
printf '.git\n' > /tmp/exc.small
if TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small "$TC" backup --no-upload >/tmp/t6.out 2>&1; then
  no "near-empty backup EXITED 0 (floor did not fire)"
else
  grep -q 'under the .* floor' /tmp/t6.out && ok "size floor dies loud" || no "died but not via floor: $(tail -2 /tmp/t6.out)"
fi

echo "== T7: --force overrides floor; full pipeline produces a kit; meta has zstd_long =="
if TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small "$TC" backup --no-upload --force >/tmp/t7.out 2>&1; then
  kit=$(ls /tmp/tm/staging/timecrate-*.tar.zst.gpg 2>/dev/null | head -1)
  meta=$(ls /tmp/tm/staging/timecrate-*.meta.json 2>/dev/null | head -1)
  [ -s "$kit" ] && ok "kit produced ($(du -h "$kit" | cut -f1))" || no "no kit in staging"
  grep -q '"zstd_long":27' "$meta" 2>/dev/null && ok "meta.json carries zstd_long" || no "meta.json missing zstd_long: $(cat "$meta" 2>/dev/null)"
  # parse, never grep: status.json is generated JSON and its whitespace is not a contract
  python3 -c 'import json,sys; sys.exit(0 if json.load(open("/tmp/tm/state/status.json"))["local_kits"]==1 else 1)' 2>/dev/null \
    && ok "status.json local_kits=1" || no "status.json local_kits wrong: $(cat /tmp/tm/state/status.json 2>/dev/null)"
  # staging dir cleaned up (only kit+sha+meta remain, no .stage.*)
  ls /tmp/tm/staging/.stage.* >/dev/null 2>&1 && no ".stage.* debris left behind" || ok "no staging debris"
else
  no "forced backup failed: $(tail -3 /tmp/t7.out)"
fi

echo "== T8: verify (happy) + verify on corrupt kit (dies loud) =="
kit=$(ls /tmp/tm/staging/timecrate-*.tar.zst.gpg 2>/dev/null | head -1)
if [ -n "$kit" ]; then
  "$TC" verify "$kit" >/tmp/t8a.out 2>&1 && grep -q 'VERIFY OK' /tmp/t8a.out && ok "verify OK on good kit" || no "verify failed on good kit: $(tail -2 /tmp/t8a.out)"
  grep -q 'signature VERIFIED' /tmp/t8a.out && ok "kit produced by backup is SIGNED (VALIDSIG seen)" || no "backup kit has no verified signature: $(grep -i sig /tmp/t8a.out | head -1)"
  cp "$kit" /tmp/corrupt.tar.zst.gpg; printf 'garbage' | dd of=/tmp/corrupt.tar.zst.gpg bs=1 seek=2000 conv=notrunc 2>/dev/null
  if "$TC" verify /tmp/corrupt.tar.zst.gpg >/tmp/t8b.out 2>&1; then
    no "verify on CORRUPT kit exited 0"
  else
    grep -q 'VERIFY FAILED\|sha256 FAILED\|checksum' /tmp/t8b.out && ok "verify dies loud on corrupt kit" || no "corrupt verify wrong error: $(tail -2 /tmp/t8b.out)"
  fi
else no "no kit to verify"; fi

echo "== T9: restore --local round-trip; kept dir renamed out of the sweep namespace =="
if [ -n "$kit" ]; then
  if "$TC" restore --local "$kit" >/tmp/t9.out 2>&1; then
    ext=$(find /tmp/tm/staging -path '*extracted/tmp/tiny/f' 2>/dev/null | head -1)
    [ -n "$ext" ] && [ "$(cat "$ext")" = hello ] && ok "restore --local extracts content intact" || no "restored content missing"
    ls -d /tmp/tm/staging/restored-* >/dev/null 2>&1 && ok "kept extraction renamed to restored-*" || no "kept extraction NOT renamed"
    ls -d /tmp/tm/staging/.restore.* >/dev/null 2>&1 && no ".restore.* left behind (sweep would eat the kept restore)" || ok "no .restore.* debris after keep"
  else no "restore --local failed: $(tail -3 /tmp/t9.out)"; fi
fi

echo "== T8s: FORGED (encrypted-but-unsigned) kit is rejected, and nothing admits it =="
# what a Dropbox-write attacker can build: right recipient, no signing secret
echo evil > /tmp/evil
tar -cf - -C /tmp evil | zstd -q --long=27 \
  | GNUPGHOME=/tmp/tm/conf/gnupg gpg --batch --yes --trust-model always --cipher-algo AES256 \
      --compress-algo none -e -r "$(cat /tmp/tm/conf/recipients.txt)" -o /tmp/forged.tar.zst.gpg 2>/dev/null
if "$TC" restore --local /tmp/forged.tar.zst.gpg >/tmp/t8s.out 2>&1; then
  no "FORGED kit was extracted (signature gate absent!)"
else
  grep -q 'NO signature' /tmp/t8s.out && ok "forged kit REFUSED before any extraction" || no "forged kit died with wrong error: $(tail -1 /tmp/t8s.out)"
fi
# The transition hatch closed 2026-07-31. There must be no argument, and no environment
# variable, that gets an unsigned kit past the gate.
if "$TC" restore --local /tmp/forged.tar.zst.gpg --allow-unsigned >/tmp/t8s2.out 2>&1; then
  no "--allow-unsigned STILL admits an unsigned kit"
else
  grep -q 'unknown restore flag\|NO signature' /tmp/t8s2.out && ok "--allow-unsigned no longer admits anything" \
    || no "unsigned kit refused for the wrong reason: $(tail -1 /tmp/t8s2.out)"
fi
if TIMECRATE_ALLOW_UNSIGNED=1 "$TC" restore --local /tmp/forged.tar.zst.gpg >/tmp/t8s3.out 2>&1; then
  no "TIMECRATE_ALLOW_UNSIGNED=1 still admits an unsigned kit"
else
  grep -q 'NO signature' /tmp/t8s3.out && ok "the environment variable does not admit one either" \
    || no "env hatch refused for the wrong reason: $(tail -1 /tmp/t8s3.out)"
fi
grep -q 'break-glass' /tmp/t8s3.out && ok "the refusal points at break-glass for a genuine pre-v1.3.0 archive" \
  || no "the refusal offers no route for a genuine old archive"
# ...and that pointer has to lead somewhere. break-glass shares decrypt_verified, so closing the
# hatch blocked the very route the refusal recommends until it was taught to report instead.
"$TC" break-glass /tmp/forged.tar.zst.gpg /tmp/bg-out >/tmp/t8s4.out 2>&1 \
  && no "break-glass EXTRACTED an unsigned archive" \
  || { grep -q 'by hand' /tmp/t8s4.out && grep -q 'gpg --status-file' /tmp/t8s4.out \
       && ok "break-glass prints the raw commands and declines to extract an unsigned archive" \
       || no "break-glass left an unsigned archive with no route: $(tail -1 /tmp/t8s4.out)"; }
[ -e /tmp/bg-out/etc ] && no "break-glass extracted despite refusing" || ok "nothing was extracted"
# a SIGNED archive must still extract, or the fix broke the normal path
"$TC" break-glass "$kit" /tmp/bg-ok >/tmp/t8s5.out 2>&1 \
  && ok "break-glass still extracts a properly signed archive" \
  || no "break-glass no longer works on a signed archive: $(tail -1 /tmp/t8s5.out)"
rm -rf /tmp/bg-out /tmp/bg-ok
rm -rf /tmp/tm/staging/restored-*   # keep later restored-* assertions unambiguous

echo "== T8u: kit signed by an UNEXPECTED key (in-keyring attacker) is refused =="
GNUPGHOME=/tmp/tm/conf/gnupg gpg --batch --gen-key >/dev/null 2>&1 <<'KS'
%no-protection
Key-Type: RSA
Key-Length: 3072
Key-Usage: sign
Name-Real: timecrate-attacker
Expire-Date: 0
%commit
KS
afpr=$(GNUPGHOME=/tmp/tm/conf/gnupg gpg --list-keys --with-colons timecrate-attacker | awk -F: '/^fpr/{print $10; exit}')
tar -cf - -C /tmp evil | zstd -q --long=27 \
  | GNUPGHOME=/tmp/tm/conf/gnupg gpg --batch --yes --trust-model always --cipher-algo AES256 \
      --compress-algo none --sign -u "$afpr" -e -r "$(cat /tmp/tm/conf/recipients.txt)" -o /tmp/wrongsign.tar.zst.gpg 2>/dev/null
if "$TC" restore --local /tmp/wrongsign.tar.zst.gpg >/tmp/t8u.out 2>&1; then
  no "kit signed by the WRONG key was extracted (pin check absent!)"
else
  grep -q 'UNEXPECTED key' /tmp/t8u.out && ok "wrong-signer kit refused (pin enforced)" || no "wrong-signer died with wrong error: $(tail -1 /tmp/t8u.out)"
fi
rm -rf /tmp/tm/staging/restored-*

echo "== T9b: failed upload must KEEP the finished kit (fake rclone outage) =="
cat > /usr/local/bin/rclone <<'FAKE'
#!/bin/bash
case "$*" in *copyto*) echo "fake rclone: simulated Dropbox 500" >&2; exit 1;; *) exit 0;; esac
FAKE
chmod +x /usr/local/bin/rclone
mkdir -p /tmp/tm/staging2
if TIMECRATE_STAGING=/tmp/tm/staging2 TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small \
   "$TC" backup --force >/tmp/t9b.out 2>&1; then
  no "backup with failing upload EXITED 0"
else
  grep -q 'kit kept locally' /tmp/t9b.out && ok "upload failure dies loud" || no "upload failure wrong error: $(tail -2 /tmp/t9b.out)"
  k2=$(ls /tmp/tm/staging2/timecrate-*.tar.zst.gpg 2>/dev/null | head -1)
  [ -s "$k2" ] && ok "finished kit SURVIVES the failed upload" || no "kit was DELETED on failed upload (regression!)"
  ls /tmp/tm/staging2/*.part >/dev/null 2>&1 && no "*.part left after completed pipeline" || ok "no .part residue"
fi
rm -f /usr/local/bin/rclone

echo "== T9c: non-numeric size env dies loud =="
if TIMECRATE_MIN_MB=banana "$TC" backup --dry-run >/tmp/t9c.out 2>&1; then
  no "banana MIN_MB accepted (guards silently disabled)"
else
  grep -q 'must be plain integers' /tmp/t9c.out && ok "non-numeric size env dies loud" || no "wrong error: $(tail -1 /tmp/t9c.out)"
fi

echo "== T10: verify unbound-arg guards =="
"$TC" verify >/tmp/t10.out 2>&1; grep -q 'usage:' /tmp/t10.out && ok "verify with no arg → usage" || no "verify no-arg: $(tail -1 /tmp/t10.out)"
"$TC" break-glass >/tmp/t10b.out 2>&1; grep -q 'usage:' /tmp/t10b.out && ok "break-glass with no arg → usage" || no "break-glass no-arg: $(tail -1 /tmp/t10b.out)"
"$TC" restore --local >/tmp/t10c.out 2>&1; grep -q 'usage:' /tmp/t10c.out && ok "restore --local with no arg → usage" || no "restore --local no-arg: $(tail -1 /tmp/t10c.out)"

echo "== T11: status renders without rclone/systemd/journal (no set -e death) =="
if "$TC" status >/tmp/t11.out 2>&1 && grep -q 'Timecrate status' /tmp/t11.out; then
  ok "status renders on a box with no rclone remote/systemd"
else no "status died: $(tail -3 /tmp/t11.out)"; fi
"$TC" status --json >/tmp/t11b.out 2>&1 && python3 -c 'import json,sys; json.load(open("/tmp/t11b.out"))' 2>/dev/null && ok "status --json is valid JSON" || no "status --json invalid"

echo "== T12: escrow-doc refuses an included path, allows a safe one =="
if "$TC" escrow-doc /root/escrow-sheet.txt >/tmp/t12.out 2>&1; then
  no "escrow-doc into /root (an included path) SUCCEEDED — secret would ride in the kit"
else
  grep -q 'INSIDE the backup include set' /tmp/t12.out && ok "escrow-doc refuses included path" || no "refused with wrong error: $(tail -1 /tmp/t12.out)"
fi
if "$TC" escrow-doc /tmp/escrow-sheet.txt >/tmp/t12b.out 2>&1 && grep -q 'BEGIN PGP PRIVATE KEY BLOCK' /tmp/escrow-sheet.txt; then
  ok "escrow-doc writes to a safe path"
else no "escrow-doc safe path failed: $(tail -2 /tmp/t12b.out)"; fi
grep -q 'mkdir -p /restore' /tmp/escrow-sheet.txt && ok "escrow sheet includes mkdir -p /restore" || no "sheet missing mkdir step"

echo "== T13: harden refuses without escrow-confirm; drill log feeds status =="
if "$TC" harden >/tmp/t13.out 2>&1; then no "harden ran without escrow-confirm"; else
  grep -q 'NOT confirmed' /tmp/t13.out && ok "harden blocked before escrow-confirm" || no "harden wrong error: $(tail -1 /tmp/t13.out)"; fi
printf '%s drill PASSED 2026-07-23_03-00-00\n' "$(date -Is)" >> /tmp/tm/state/log
"$TC" escrow-confirm >/dev/null 2>&1   # triggers write_status, which folds the drill line in
"$TC" status --json >/tmp/t13b.out 2>&1
grep -q '"drill_last": *"PASSED' /tmp/t13b.out && ok "drill_last surfaces PASSED from state log" || no "drill_last missing: $(cat /tmp/t13b.out)"

echo "== T14: prune_remote guards (KEEP=0 and non-numeric refused, remote untouched) =="
sed -n '/^prune_remote()/,/^}$/p;/^kit_sort()/p' "$TC" > /tmp/prune_fn.sh
cat > /tmp/t14run.sh <<'RUNNER'
warn(){ echo "WARN: $*" >&2; }
log(){ :; }
rc(){ echo SHOULD-NOT-RUN; exit 9; }
KIT_GLOB='{timecrate,timemachine}-*.tar.zst.gpg' KEEP_MONTHLY=12 KEEP_YEARLY=3
source /tmp/prune_fn.sh
KEEP=0       prune_remote "fake:r" "x.tar.zst.gpg"
KEEP=banana  prune_remote "fake:r" "x.tar.zst.gpg"
RUNNER
if bash /tmp/t14run.sh >/tmp/t14.out 2>&1 && ! grep -q 'SHOULD-NOT-RUN' /tmp/t14.out; then
  ok "KEEP=0 + non-numeric KEEP refused without touching remote"
else no "prune guard failed: $(cat /tmp/t14.out)"; fi

echo "== T16: GFS retention keeps dailies + monthly/yearly firsts, drops the rest =="
{ printf 'timecrate-2023-03-04_03-00-00.tar.zst.gpg\n'
  printf 'timecrate-2024-01-05_03-00-00.tar.zst.gpg\n'
  for m in 2025-08 2025-09 2025-10 2025-11 2025-12 2026-01 2026-02 2026-03 2026-04 2026-05 2026-06; do
    printf 'timecrate-%s-01_03-00-00.tar.zst.gpg\n' "$m"; done
  printf 'timecrate-2026-07-01_03-00-00.tar.zst.gpg\n'
  printf 'timecrate-2026-07-05_03-00-00.tar.zst.gpg\n'
  for d in 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do
    printf 'timecrate-2026-07-%s_03-00-00.tar.zst.gpg\n' "$d"; done
} > /tmp/kitlist
rm -f /tmp/dels
cat > /tmp/t16run.sh <<'RUNNER'
warn(){ :; }; log(){ :; }
rc(){ case "$1" in lsf) cat /tmp/kitlist;; delete) echo "$2" >> /tmp/dels;; esac; return 0; }
KIT_GLOB='{timecrate,timemachine}-*.tar.zst.gpg' KEEP=14 KEEP_MONTHLY=12 KEEP_YEARLY=3
source /tmp/prune_fn.sh
prune_remote "fake:r" ""
RUNNER
bash /tmp/t16run.sh >/dev/null 2>&1
dropped=$(grep -c 'tar.zst.gpg$' /tmp/dels 2>/dev/null || echo 0)
# expected drops: 2023-03-04 (outside 3-year tier) and 2026-07-05 (not a daily keeper, not a first)
if [ "$dropped" = 2 ] && grep -q '2023-03-04' /tmp/dels && grep -q '2026-07-05' /tmp/dels; then
  ok "GFS: exactly the non-keepers dropped (2023 yearly-expired + mid-July straggler)"
else
  no "GFS drop set wrong — dropped: $(tr '\n' ' ' < /tmp/dels 2>/dev/null)"
fi
grep -q '2024-01-05' /tmp/dels && no "yearly keeper 2024 was dropped" || ok "yearly firsts survive"
grep -q '2026-07-01' /tmp/dels && no "monthly keeper 2026-07-01 was dropped" || ok "monthly firsts survive"

echo "== T17: anti-rollback — restoring an older kit needs --force =="
printf 'timecrate-2099-01-01_00-00-00.tar.zst.gpg 5\n' > /tmp/tm/state/expected
if "$TC" restore --local "$kit" >/tmp/t17.out 2>&1; then
  no "older-than-expected kit restored without --force"
else
  grep -q 'ROLLBACK GUARD' /tmp/t17.out && ok "older kit refused with rollback warning" || no "wrong error: $(tail -1 /tmp/t17.out)"
fi
if "$TC" restore --local "$kit" --force >/tmp/t17b.out 2>&1; then
  ok "--force allows the deliberate point-in-time restore"
else no "--force restore failed: $(tail -2 /tmp/t17b.out)"; fi
rm -f /tmp/tm/state/expected; rm -rf /tmp/tm/staging/restored-*

echo "== T18: second-remote mirror fires when TIMECRATE_REMOTE2 is set =="
rm -f /tmp/rclone-calls.log
cat > /usr/local/bin/rclone <<'FAKE'
#!/bin/bash
echo "$*" >> /tmp/rclone-calls.log
case "$*" in *" lsf "*) echo stub-kit.tar.zst.gpg;; esac
exit 0
FAKE
chmod +x /usr/local/bin/rclone
mkdir -p /tmp/tm/staging3
if TIMECRATE_STAGING=/tmp/tm/staging3 TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small \
   TIMECRATE_REMOTE2=fake2:tm "$TC" backup --force >/tmp/t18.out 2>&1; then
  grep -q 'mirroring to fake2:tm' /tmp/t18.out && ok "mirror step ran" || no "no mirror log line"
  grep -q 'copyto .*fake2:tm/' /tmp/rclone-calls.log && ok "kit copied to the second remote" || no "no copyto to remote2 in rclone calls"
  grep -qF 'lsf fake2:tm --include {timecrate,timemachine}-*' /tmp/rclone-calls.log && ok "second remote pruned independently (prune-shaped lsf)" || no "remote2 never prune-listed"
  [ -s /tmp/tm/state/expected ] && ok "anti-rollback anchor recorded after upload" || no "expected anchor missing"
else
  no "mirrored backup failed: $(tail -3 /tmp/t18.out)"
fi
rm -f /usr/local/bin/rclone /tmp/tm/state/expected

echo "== T19: drill remote sweep — verify-all, unsigned kits, DELETION, ROLLBACK, no crash =="
mkdir -p /tmp/fakeremote
cat > /usr/local/bin/rclone <<'FAKE'
#!/bin/bash
# directory-backed fake rclone (ignores --config <file>)
args=(); skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in --config) skip=1;; *) args+=("$a");; esac
done
case "${args[0]}" in
  lsf)
    inc=""; n=${#args[@]}
    for ((i=1; i<n; i++)); do [ "${args[i]}" = --include ] && inc="${args[i+1]:-}"; done
    case "$inc" in
      ''|*'*'*) ls /tmp/fakeremote 2>/dev/null | grep '\.tar\.zst\.gpg$' || true;;
      *)        ls /tmp/fakeremote 2>/dev/null | grep -Fx "$inc" || true;;
    esac;;
  copyto) f="/tmp/fakeremote/$(basename "${args[1]}")"; [ -f "$f" ] && cp "$f" "${args[2]}" || exit 1;;
  delete) rm -f "/tmp/fakeremote/$(basename "${args[1]}")";;
esac
exit 0
FAKE
chmod +x /usr/local/bin/rclone
cp "$kit" "/tmp/fakeremote/$(basename "$kit")"
cp "$kit.sha256" "/tmp/fakeremote/$(basename "$kit").sha256" 2>/dev/null || true
# a) healthy remote: drill passes and sweeps
if "$TC" recovery-drill >/tmp/t19a.out 2>&1; then
  grep -q 'RECOVERY DRILL PASSED' /tmp/t19a.out && grep -q 'remote sweep: 1 kits, 1 signature-verified' /tmp/t19a.out \
    && ok "drill passes + sweeps a healthy remote" || no "drill passed but sweep line wrong: $(grep 'remote sweep' /tmp/t19a.out)"
else no "healthy drill failed: $(tail -3 /tmp/t19a.out)"; fi
# b) an injected unsigned kit is flagged by the sweep
cp /tmp/forged.tar.zst.gpg /tmp/fakeremote/timecrate-2026-01-01_00-00-00.tar.zst.gpg
if "$TC" recovery-drill >/tmp/t19b.out 2>&1; then
  no "drill PASSED with an unsigned kit on the remote"
else
  grep -q 'unsigned' /tmp/t19b.out && ok "sweep flags the injected unsigned kit" || no "wrong failure: $(tail -2 /tmp/t19b.out)"
fi
rm -f /tmp/fakeremote/timecrate-2026-01-01_00-00-00.tar.zst.gpg
# c) DELETION: expected count higher than reality
printf '%s 5\n' "$(basename "$kit")" > /tmp/tm/state/expected
if "$TC" recovery-drill >/tmp/t19c.out 2>&1; then
  no "drill PASSED despite fewer kits than expected"
else
  grep -q 'REMOTE DELETION' /tmp/t19c.out && ok "DELETION alert on fewer-than-expected kits" || no "wrong failure: $(tail -2 /tmp/t19c.out)"
fi
# d) ROLLBACK: expected newest is newer than reality
printf 'timecrate-2099-01-01_00-00-00.tar.zst.gpg 1\n' > /tmp/tm/state/expected
if "$TC" recovery-drill >/tmp/t19d.out 2>&1; then
  no "drill PASSED despite an older-than-expected newest kit"
else
  grep -q 'REMOTE ROLLBACK' /tmp/t19d.out && ok "ROLLBACK alert on older-than-expected newest" || no "wrong failure: $(tail -2 /tmp/t19d.out)"
fi
# e) total wipe with an anchor: clean DELETION diagnosis, no crash, no 'run a backup first'
rm -f /tmp/fakeremote/*
printf '%s 1\n' "$(basename "$kit")" > /tmp/tm/state/expected
"$TC" recovery-drill >/tmp/t19e.out 2>&1
if grep -q 'bad array subscript' /tmp/t19e.out; then no "empty-remote sweep CRASHED (bad array subscript)"
elif grep -q 'REMOTE DELETION' /tmp/t19e.out; then ok "total wipe diagnosed as REMOTE DELETION (version-history pointer), no crash"
else no "total wipe mis-diagnosed: $(tail -2 /tmp/t19e.out)"; fi
rm -f /usr/local/bin/rclone /tmp/tm/state/expected; rm -rf /tmp/fakeremote

echo "== T20: config file layer (v1.5.0) =="
# The bug this replaced: /etc/timecrate.env was read by the systemd units and NOT by the tool,
# so backup used the deployed remote while status/list/GUI used the built-in default and reported
# an empty remote as a healthy "0 kits".
mkdir -p /tmp/tm/etc
printf 'TIMECRATE_REMOTE=sysconf:FROM_SYSTEM\nTIMECRATE_KEEP=7\n' > /tmp/tm/etc/system.conf
export TIMECRATE_SYSTEM_CONF=/tmp/tm/etc/system.conf
export TIMECRATE_SECRET_ENV=/nonexistent-secret-env
export TIMECRATE_USER_CONF=/tmp/tm/etc/user.conf
"$TC" config > /tmp/t20a.out 2>&1
grep -q 'sysconf:FROM_SYSTEM' /tmp/t20a.out && ok "system config file is loaded by the tool itself" \
  || no "system config ignored: $(grep -i remote /tmp/t20a.out | head -1)"
# match on the fields, not the column padding -- alignment is presentation, not contract
grep -qE '^ *loaded +/tmp/tm/etc/system\.conf' /tmp/t20a.out && ok "config reports WHICH file it read" \
  || no "config does not report its sources"
# a one-off env var must still win over the file
TIMECRATE_REMOTE=env:WINS "$TC" config > /tmp/t20b.out 2>&1
grep -q 'env:WINS' /tmp/t20b.out && ok "environment overrides the config file" \
  || no "config file overrode the environment (precedence inverted)"
# and the per-user file must win over the system file
printf 'TIMECRATE_REMOTE=userconf:WINS\n' > /tmp/tm/etc/user.conf
"$TC" config > /tmp/t20c.out 2>&1
grep -q 'userconf:WINS' /tmp/t20c.out && ok "user config overrides system config" \
  || no "user config did not override system config"
rm -f /tmp/tm/etc/user.conf

# a root-only secrets file you cannot read is not an absent one -- reporting it as "absent"
# reads as "nothing is configured there", which is the lie this command exists to catch
printf 'EXAMPLE_SETTING=x\n' > /tmp/tm/etc/secret.env; chmod 000 /tmp/tm/etc/secret.env
TIMECRATE_SECRET_ENV=/tmp/tm/etc/secret.env setpriv --reuid=1 --regid=1 --clear-groups "$TC" config > /tmp/t20d.out 2>&1 || true
if grep -q 'UNREADABLE.*secret.env' /tmp/t20d.out; then ok "an existing but unreadable config file is reported as UNREADABLE, not absent"
elif grep -q 'absent.*secret.env' /tmp/t20d.out; then no "unreadable root-only file reported as 'absent'"
else ok "config could not drop privileges here (skipped)"; fi
chmod 644 /tmp/tm/etc/secret.env; rm -f /tmp/tm/etc/secret.env

# ...but only the secrets file is MEANT to be unreadable. Telling the operator that a mode-mangled
# system config is "normal" and "the units DO load it" is the same lie with the opposite sign.
chmod 000 /tmp/tm/etc/system.conf
setpriv --reuid=1 --regid=1 --clear-groups "$TC" config > /tmp/t20e.out 2>&1 || true
if grep -q 'UNREADABLE.*system\.conf.*check its permissions' /tmp/t20e.out; then
  ok "an unreadable NON-secret config is reported as a permissions problem, not as normal"
elif grep -q 'UNREADABLE.*system\.conf.*normal for the root-only' /tmp/t20e.out; then
  no "unreadable system config described as the normal root-only secrets file"
else ok "config could not drop privileges here (skipped)"; fi
chmod 644 /tmp/tm/etc/system.conf

echo "== T21: an unlistable remote is UNKNOWN, never a healthy zero =="
printf '#!/bin/sh\nexit 3\n' > /usr/local/bin/rclone; chmod +x /usr/local/bin/rclone
if "$TC" list >/tmp/t21a.out 2>&1; then
  no "list EXITED 0 on an unlistable remote (GUI renders that as 'no backups yet')"
else
  grep -q 'cannot list' /tmp/t21a.out && ok "list dies loud when the remote cannot be read" \
    || no "list failed with the wrong error: $(tail -1 /tmp/t21a.out)"
fi
"$TC" status --json > /tmp/t21b.out 2>&1
python3 -c 'import json,sys; d=json.load(open("/tmp/t21b.out")); sys.exit(0 if d.get("cloud_kits")=="" else 1)' 2>/dev/null \
  && ok "status reports cloud_kits UNKNOWN (not 0) when rclone fails" \
  || no "status collapsed an unreadable remote into 0 kits: $(cat /tmp/t21b.out)"
rm -f /usr/local/bin/rclone
unset TIMECRATE_SYSTEM_CONF TIMECRATE_SECRET_ENV TIMECRATE_USER_CONF

echo "== T22: the keyring, the rclone token and staging can never enter a kit =="
# These used to be literal per-machine home paths in the exclude file — correct on one box and
# silently wrong everywhere else. They are derived from live config now, so an include set that
# covers them (or an empty exclude file) still cannot ship the key that decrypts the kit.
: > /tmp/exc.empty
printf 'tmp/tm\n' > /tmp/inc.conf
if TIMECRATE_INCLUDE=/tmp/inc.conf TIMECRATE_EXCLUDE=/tmp/exc.empty "$TC" backup --no-upload --force >/tmp/t22.out 2>&1; then
  kit2=$(ls -t /tmp/tm/staging/timecrate-*.tar.zst.gpg 2>/dev/null | head -1)
  GNUPGHOME=/tmp/tm/conf/gnupg gpg --batch --no-tty -d "$kit2" 2>/dev/null \
    | zstd -dc --long=27 2>/dev/null | tar -tf - > /tmp/t22.list 2>/dev/null || true
  [ -s /tmp/t22.list ] || no "T22 kit did not list (test harness broken)"
  grep -q 'tmp/tm/conf/timecrate-secret.asc' /tmp/t22.list \
    && no "THE DECRYPTION KEY IS INSIDE THE KIT" || ok "keyring/escrow excluded from the kit by derivation"
  grep -q 'tmp/tm/staging/' /tmp/t22.list \
    && no "staging (previous kits) archived into the new kit" || ok "staging excluded from the kit by derivation"
  rm -f "$kit2" "${kit2}.sha256" "${kit2%.tar.zst.gpg}.meta.json"
else
  no "T22 backup failed: $(tail -3 /tmp/t22.out)"
fi

echo "== T23: schedule reports honestly and refuses a calendar that would never fire =="
apt-get install -y -qq systemd >/dev/null 2>&1   # for systemd-analyze; nothing is running as PID 1
"$TC" schedule > /tmp/t23.out 2>&1
grep -qE 'backup +disabled' /tmp/t23.out && ok "schedule reports an unscheduled box as disabled" \
  || no "schedule misreported an unscheduled box: $(cat /tmp/t23.out)"
# a bad OnCalendar does not error at enable time -- systemd just never fires the timer again
if "$TC" schedule backup on --at 'every other tuesday' >/tmp/t23b.out 2>&1; then
  no "an invalid OnCalendar was ACCEPTED (the timer would silently never fire)"
else
  grep -q 'not a valid OnCalendar' /tmp/t23b.out && ok "invalid OnCalendar refused before anything is written" \
    || no "refused for the wrong reason: $(tail -1 /tmp/t23b.out)"
fi
"$TC" schedule nonsense on >/tmp/t23c.out 2>&1 && no "unknown schedule target accepted" \
  || ok "unknown schedule target refused"

echo "== T15: POST-HARDEN restore — enc secret gone from TC keyring, escrow imported into DEFAULT keyring =="
# harden-style state: encryption secret deleted, standalone signing secret SURVIVES in the TC
# keyring — decrypt_verified must fall through to the default keyring (the documented recovery
# path), not pin the TC keyring because "some secret" is present
GNUPGHOME=/tmp/tm/conf/gnupg gpg --batch --yes --delete-secret-keys "$(cat /tmp/tm/conf/recipients.txt)" 2>/dev/null
gpg --batch --import /tmp/tm/conf/timecrate-secret.asc >/dev/null 2>&1
gpg --batch --import /tmp/tm/conf/timecrate-signing-public.asc >/dev/null 2>&1
if "$TC" restore --local "$kit" >/tmp/t15.out 2>&1; then
  grep -q 'signature VERIFIED' /tmp/t15.out && ok "post-harden restore via default keyring (decrypt + VALIDSIG)" || no "restored but signature not verified: $(grep -i signat /tmp/t15.out | head -1)"
else
  no "post-harden restore FAILED (keyring-selection regression?): $(tail -2 /tmp/t15.out)"
fi

echo "== T24: key lifecycle — the wiped-box path =="
# Restore the state T15 dismantled: it deleted the encryption secret to simulate a hardened box.
gpg_tc(){ GNUPGHOME=/tmp/tm/conf/gnupg gpg --batch --no-tty "$@"; }
gpg_tc --import /tmp/tm/conf/timecrate-secret.asc >/dev/null 2>&1
EFPR=$(cat /tmp/tm/conf/recipients.txt)

"$TC" keys > /tmp/t24a.out 2>&1
grep -q "$EFPR" /tmp/t24a.out && ok "keys reports the configured encryption fingerprint" \
  || no "keys did not report the fingerprint: $(cat /tmp/t24a.out)"
"$TC" keys --json > /tmp/t24j.json 2>/dev/null
python3 -c 'import json;d=json.load(open("/tmp/t24j.json"));assert d["encryption_secret_present"];assert d["signing_public_present"]' 2>/dev/null \
  && ok "keys --json reports encryption secret + signing public separately" || no "keys --json wrong: $(cat /tmp/t24j.json)"

# export -> import into a COMPLETELY fresh config dir is the wiped-box path in one line
"$TC" export-key --out /tmp/escrowed.asc >/dev/null 2>&1 \
  && ok "export-key writes the escrow file" || no "export-key failed"
rm -rf /tmp/tm2
if TIMECRATE_CONF=/tmp/tm2/conf TIMECRATE_STATE=/tmp/tm2/state "$TC" import-key /tmp/escrowed.asc \
     --signing-pub /tmp/tm/conf/timecrate-signing-public.asc --yes >/tmp/t24b.out 2>&1; then
  [ "$(cat /tmp/tm2/conf/recipients.txt 2>/dev/null)" = "$EFPR" ] \
    && ok "import-key onto a bare machine restores the identity" \
    || no "import-key wrote the wrong recipient: $(cat /tmp/tm2/conf/recipients.txt 2>/dev/null)"
  [ -s /tmp/tm2/conf/signing.txt ] && ok "import-key pins the signing key from --signing-pub" \
    || no "import-key did not pin the signing fingerprint"
else no "import-key failed: $(tail -2 /tmp/t24b.out)"; fi

# and the imported identity must actually decrypt a real kit
if TIMECRATE_CONF=/tmp/tm2/conf TIMECRATE_STATE=/tmp/tm2/state TIMECRATE_STAGING=/tmp/tm2/staging \
     "$TC" restore --local "$kit" >/tmp/t24c.out 2>&1; then
  grep -q 'signature VERIFIED' /tmp/t24c.out \
    && ok "a kit restores on the rebuilt machine, signature and all" \
    || no "restored but unverified on the rebuilt machine"
else no "the imported key could NOT restore a real kit: $(tail -2 /tmp/t24c.out)"; fi

# a public key is not an escrow file, and saying so at import time beats finding out at a restore
gpg_tc --armor --export "$EFPR" > /tmp/pub-only.asc 2>/dev/null
TIMECRATE_CONF=/tmp/tm3/conf "$TC" import-key /tmp/pub-only.asc --yes >/tmp/t24d.out 2>&1 \
  && no "import-key ACCEPTED a public-only export" \
  || { grep -q 'no SECRET key' /tmp/t24d.out && ok "import-key refuses a public-only export" \
       || no "refused for the wrong reason: $(tail -1 /tmp/t24d.out)"; }

# ECC is the trap this tool is built around: it imports fine and then cannot decrypt
mkdir -p /tmp/ecc && chmod 700 /tmp/ecc
GNUPGHOME=/tmp/ecc gpg --batch --quick-gen-key --passphrase '' ecc@test default default never >/dev/null 2>&1 || true
GNUPGHOME=/tmp/ecc gpg --batch --armor --export-secret-keys ecc@test > /tmp/ecc.asc 2>/dev/null || true
if [ -s /tmp/ecc.asc ] && ! grep -q '^sec:.*:1:' <(GNUPGHOME=/tmp/ecc gpg --with-colons --list-secret-keys 2>/dev/null); then
  TIMECRATE_CONF=/tmp/tm4/conf "$TC" import-key /tmp/ecc.asc --yes >/tmp/t24e.out 2>&1 \
    && no "import-key ACCEPTED a non-RSA key (every backup made with it would be unrecoverable)" \
    || { grep -q 'non-RSA key' /tmp/t24e.out && ok "import-key refuses a non-RSA key" \
         || no "non-RSA refused for the wrong reason: $(tail -1 /tmp/t24e.out)"; }
else ok "no ECC default in this GnuPG (skipped)"; fi

# swapping the recipient silently is how old kits become unreadable. The claim under test is
# that the SUPERSEDED secret survives --replace, so the kit has to be one encrypted to the key
# being displaced -- restoring a kit encrypted to the key just imported proves nothing.
rm -rf /tmp/tm7
TIMECRATE_CONF=/tmp/tm7/conf TIMECRATE_STATE=/tmp/tm7/state "$TC" init --new-identity >/dev/null 2>&1
NEWFPR=$(cat /tmp/tm7/conf/recipients.txt 2>/dev/null)
if [ -n "$NEWFPR" ] && [ "$NEWFPR" != "$EFPR" ]; then
  ok "minted a second, different identity to test displacement against"
  # a kit encrypted AND signed by the soon-to-be-superseded key B
  TIMECRATE_CONF=/tmp/tm7/conf TIMECRATE_STATE=/tmp/tm7/state TIMECRATE_STAGING=/tmp/tm7/staging \
    TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small \
    "$TC" backup --no-upload --force >/tmp/t24p.out 2>&1
  KITB=$(ls /tmp/tm7/staging/timecrate-*.tar.zst.gpg 2>/dev/null | head -1)
  [ -n "$KITB" ] && ok "built a kit encrypted to the key about to be superseded" \
    || no "could not build the superseded-key kit: $(tail -2 /tmp/t24p.out)"

  TIMECRATE_CONF=/tmp/tm7/conf TIMECRATE_STATE=/tmp/tm7/state "$TC" import-key /tmp/escrowed.asc --yes >/tmp/t24f.out 2>&1 \
    && no "import-key overwrote a DIFFERENT configured key without --replace" \
    || { grep -q 'already configured' /tmp/t24f.out && ok "import-key refuses to displace another key without --replace" \
         || no "wrong refusal: $(tail -1 /tmp/t24f.out)"; }

  # no --signing-pub: keep B's signing key pinned, so the restore below is testing the ENCRYPTION
  # secret's survival and not tripping over an authenticity change at the same time
  TIMECRATE_CONF=/tmp/tm7/conf TIMECRATE_STATE=/tmp/tm7/state "$TC" import-key /tmp/escrowed.asc --replace --yes >/tmp/t24f2.out 2>&1 \
    || no "import-key --replace failed: $(tail -1 /tmp/t24f2.out)"
  [ "$(cat /tmp/tm7/conf/recipients.txt 2>/dev/null)" = "$EFPR" ] \
    && ok "--replace re-points new backups at the imported key" || no "--replace did not re-point the recipient"

  if [ -n "$KITB" ] && TIMECRATE_CONF=/tmp/tm7/conf TIMECRATE_STATE=/tmp/tm7/state \
       TIMECRATE_STAGING=/tmp/tm7/staging "$TC" restore --local "$KITB" >/tmp/t24g.out 2>&1; then
    grep -q 'signature VERIFIED' /tmp/t24g.out \
      && ok "--replace keeps kits encrypted to the SUPERSEDED key readable" \
      || no "superseded-key kit decrypted but did not verify"
  else no "--replace made the superseded key's own kits unreadable: $(tail -2 /tmp/t24g.out)"; fi
else no "could not mint a second identity to test --replace against"; fi

# the one-way door: minting a key on a box whose remote already holds backups
cat > /usr/local/bin/rclone <<'FAKE'
#!/bin/bash
case "$*" in *" lsf "*) printf 'timecrate-2026-01-01_00-00-00.tar.zst.gpg\n';; esac
exit 0
FAKE
chmod +x /usr/local/bin/rclone
rm -rf /tmp/tm5
if TIMECRATE_CONF=/tmp/tm5/conf TIMECRATE_STATE=/tmp/tm5/state "$TC" init >/tmp/t24h.out 2>&1; then
  no "init MINTED A NEW KEY on a remote that already holds backups (they are now unreadable)"
else
  grep -q 'import-key' /tmp/t24h.out && ok "init refuses on a non-empty remote and points at import-key" \
    || no "init refused for the wrong reason: $(tail -1 /tmp/t24h.out)"
fi
rm -rf /tmp/tm5
TIMECRATE_CONF=/tmp/tm5/conf TIMECRATE_STATE=/tmp/tm5/state "$TC" init --new-identity >/dev/null 2>&1 \
  && ok "init --new-identity overrides the guard" || no "init --new-identity was still blocked"
# an unreachable remote is not an empty one: it must NOT block a rescue box from setting up
printf '#!/bin/sh\nexit 3\n' > /usr/local/bin/rclone; chmod +x /usr/local/bin/rclone
rm -rf /tmp/tm6
if TIMECRATE_CONF=/tmp/tm6/conf TIMECRATE_STATE=/tmp/tm6/state "$TC" init >/tmp/t24i.out 2>&1; then
  grep -q 'could not reach' /tmp/t24i.out && ok "init proceeds (with a warning) when the remote is unreachable" \
    || ok "init proceeds when the remote is unreachable"
else no "an unreachable remote BLOCKED init on a rescue box: $(tail -1 /tmp/t24i.out)"; fi
rm -f /usr/local/bin/rclone

# escrowing the key into the backup is the chicken-and-egg failure the escrow exists to avoid
TIMECRATE_INCLUDE=/tmp/inc.small "$TC" export-key --out /tmp/tiny/key.asc >/tmp/t24k.out 2>&1 \
  && no "export-key wrote the secret key INTO the backup include set" \
  || { grep -q 'include set' /tmp/t24k.out && ok "export-key refuses a path inside the include set" \
       || no "wrong refusal: $(tail -1 /tmp/t24k.out)"; }

# a pre-1.7.0 escrow marker says nothing about WHICH key -- report that, do not invent it
: > /tmp/tm/conf/.escrow-confirmed
"$TC" keys > /tmp/t24l.out 2>&1
grep -q 'pre-1.7.0' /tmp/t24l.out && ok "a legacy escrow marker is reported as unknown, not upgraded" \
  || no "legacy escrow marker misreported: $(grep -i escrow /tmp/t24l.out)"
# ...and a marker that cannot name its key must not authorise the one irreversible act
: > /tmp/tm/conf/.escrow-confirmed
"$TC" harden --offbox-verified >/tmp/t24m.out 2>&1 \
  && no "harden SHREDDED the secret key on a pre-1.7.0 marker that names no key" \
  || { grep -q 'predates v1.7.0' /tmp/t24m.out && ok "harden refuses a legacy marker that cannot name its key" \
       || no "harden refused for the wrong reason: $(tail -1 /tmp/t24m.out)"; }
"$TC" escrow-confirm >/dev/null 2>&1
[ "$(sed -n 1p /tmp/tm/conf/.escrow-confirmed)" = "$EFPR" ] \
  && ok "escrow-confirm records WHICH key was escrowed" || no "escrow-confirm did not record the fingerprint"
# an escrow recorded against the PREVIOUS key is not a confirmation for this one
printf 'DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF\n2026-01-01T00:00:00-06:00\n' > /tmp/tm/conf/.escrow-confirmed
"$TC" harden --offbox-verified >/tmp/t24n.out 2>&1 \
  && no "harden accepted an escrow confirmed for a different key" \
  || { grep -q 'confirmed for DEADBEEF' /tmp/t24n.out && ok "harden refuses an escrow recorded against another key" \
       || no "stale-escrow harden refused for the wrong reason: $(tail -1 /tmp/t24n.out)"; }
"$TC" escrow-confirm >/dev/null 2>&1

# an RSA primary carrying an ECC ENCRYPTION subkey is the trap a primary-only algorithm check misses
rm -rf /tmp/mixed && mkdir -p /tmp/mixed && chmod 700 /tmp/mixed
GNUPGHOME=/tmp/mixed gpg --batch --quick-gen-key --passphrase '' mixed@test rsa2048 sign never >/dev/null 2>&1
MIXFPR=$(GNUPGHOME=/tmp/mixed gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
if [ -n "$MIXFPR" ] && GNUPGHOME=/tmp/mixed gpg --batch --quick-add-key "$MIXFPR" cv25519 encr never >/dev/null 2>&1; then
  GNUPGHOME=/tmp/mixed gpg --batch --armor --export-secret-keys "$MIXFPR" > /tmp/mixed.asc 2>/dev/null
  rm -rf /tmp/tm8
  TIMECRATE_CONF=/tmp/tm8/conf "$TC" import-key /tmp/mixed.asc --yes >/tmp/t24o.out 2>&1 \
    && no "import-key ACCEPTED an RSA key whose ENCRYPTION subkey is ECC (kits would be unrecoverable)" \
    || { grep -q 'encrypts with a non-RSA key' /tmp/t24o.out && ok "import-key refuses a non-RSA encryption subkey under an RSA primary" \
         || no "mixed-algorithm key refused for the wrong reason: $(tail -1 /tmp/t24o.out)"; }
else ok "could not build a mixed RSA/ECC key in this GnuPG (skipped)"; fi

# an unreadable key store is not an empty one -- the same lesson as the config split-brain, one
# directory over, and the one that would invite a fresh identity onto a box that already has one
echo "== T25: an unreadable key store is diagnosed, not reported as 'no key' =="
# The same lesson as the config split-brain, one directory over, and the one that would invite a
# fresh identity onto a machine that already has one.
#
# CANDROP is established first, from a case that must produce UNREADABLE. Without it every later
# probe needs a "could not drop privileges" escape hatch, and an escape hatch that fires on the
# unexpected output is indistinguishable from a passing test -- which is exactly what hid the
# GNUPGHOME case when this was first written.
# Established against the ENVIRONMENT, never against the tool's own output. Deriving it from
# "did timecrate print UNREADABLE" makes a regression in timecrate look like a container
# that cannot drop privileges, and the whole section skips itself quietly -- the same escape
# hatch one level up.
CANDROP=0
[ "$(setpriv --reuid=1 --regid=1 --clear-groups id -u 2>/dev/null)" = 1 ] && CANDROP=1
[ "$CANDROP" = 1 ] || ok "this environment cannot drop privileges — T25 skipped entirely"
chmod 700 /tmp/tm/conf
if [ "$CANDROP" = 1 ]; then
  out=$(setpriv --reuid=1 --regid=1 --clear-groups "$TC" keys 2>&1 || true)
  printf '%s' "$out" | grep -q 'UNREADABLE' \
    && ok "keys says UNREADABLE, not 'NONE CONFIGURED'" \
    || no "an unreadable CONF_DIR was not diagnosed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-140)"
fi
setpriv --reuid=1 --regid=1 --clear-groups "$TC" keys --json > /tmp/t25b.json 2>/dev/null || true
if [ "$CANDROP" = 1 ]; then
  python3 -c 'import json;d=json.load(open("/tmp/t25b.json"));assert d["keyring_readable"] is False' 2>/dev/null \
    && ok "keys --json reports keyring_readable=false" || no "keys --json did not report keyring_readable=false"
  if setpriv --reuid=1 --regid=1 --clear-groups "$TC" init >/tmp/t25c.out 2>&1; then
    no "init generated a key on a machine whose key store it could not read"
  else
    grep -q 'may already have a key' /tmp/t25c.out && ok "init refuses when the key store is unreadable" \
      || no "init failed for the wrong reason: $(tail -1 /tmp/t25c.out)"
  fi
fi
chmod 755 /tmp/tm/conf

# Only ONE of the ways to be unable to read a key store is CONF_DIR being unreadable. Each of the
# others reads back as "no key configured" unless it is probed for directly.
probe_unreadable(){
  [ "$CANDROP" = 1 ] || { ok "privilege drop unavailable (skipped: $1)"; return 0; }
  out=$(setpriv --reuid=1 --regid=1 --clear-groups "$TC" keys 2>&1 || true)
  printf '%s' "$out" | grep -q 'UNREADABLE' \
    && ok "unreadable $1 is diagnosed, not read as 'no key'" \
    || no "unreadable $1 was NOT diagnosed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-140)"
}
# listable but not traversable: -r passes and every file inside is still unopenable
chmod 644 /tmp/tm/conf; probe_unreadable "CONF_DIR (r but not x)"; chmod 755 /tmp/tm/conf
# a traversable CONF_DIR holding a root-only recipients.txt -- what a root-run init leaves, one level down
chmod 600 /tmp/tm/conf/recipients.txt; probe_unreadable "recipients.txt"; chmod 644 /tmp/tm/conf/recipients.txt
# ...and the keyring itself, which reports a key with no secret half rather than no key at all
chmod 700 /tmp/tm/conf/gnupg; probe_unreadable "GNUPGHOME"; chmod 755 /tmp/tm/conf/gnupg
# with all three readable it must go back to reporting the key, or the probe is just always-true
setpriv --reuid=1 --regid=1 --clear-groups "$TC" keys 2>&1 | grep -q 'UNREADABLE' \
  && no "keyring still reported UNREADABLE after the permissions were restored" \
  || ok "a genuinely readable key store is not reported as unreadable"

echo "== T26: the intended root-on-user-keyring ownership is not warned about forever =="
# gpg calls root-reading-a-user-keyring "unsafe ownership" on every run. That is the NORMAL case
# for this tool -- root timers, user-owned keyring -- and a permanent warning in the backup log is
# how real warnings come to be ignored. Asserted through `verify`, whose gpg stderr reaches the
# operator; `keys` swallows it, so a check built on `keys` would pass no matter what the code did.
KGT=/tmp/kgperm
rm -rf "$KGT"; mkdir -p "$KGT"
kit26=$(ls /tmp/tm/staging/timecrate-*.tar.zst.gpg 2>/dev/null | head -1)
if [ -n "$kit26" ] && id -u nobody >/dev/null 2>&1; then
  cp -a /tmp/tm/conf/gnupg "$KGT/gnupg"
  chown -R nobody "$KGT/gnupg"; chmod 700 "$KGT/gnupg"
  TIMECRATE_USER=nobody TIMECRATE_GNUPGHOME="$KGT/gnupg" "$TC" verify "$kit26" >/tmp/t26a.out 2>&1 || true
  grep -q 'unsafe' /tmp/t26a.out \
    && no "the intended ownership (TC_USER, 700) still warns on every run" \
    || ok "intended ownership does not warn"
  # the BACKUP path is the one whose output lands in the nightly log, and it does not go through
  # gpg_tc -- covering only `verify` here let the warning survive in production
  TIMECRATE_USER=nobody TIMECRATE_GNUPGHOME="$KGT/gnupg" TIMECRATE_STAGING=/tmp/tm/stage26 \
    TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small \
    "$TC" backup --no-upload --force >/tmp/t26c.out 2>&1 || true
  grep -q 'unsafe' /tmp/t26c.out \
    && no "the BACKUP path still warns about the intended ownership (this is the nightly log)" \
    || ok "the backup path does not warn about the intended ownership"
  rm -rf /tmp/tm/stage26
  # ...but the point is precision, not silence: a wrong mode must still be reported
  chmod 755 "$KGT/gnupg"
  TIMECRATE_USER=nobody TIMECRATE_GNUPGHOME="$KGT/gnupg" "$TC" verify "$kit26" >/tmp/t26b.out 2>&1 || true
  grep -q 'unsafe' /tmp/t26b.out \
    && ok "a wrong mode still warns" \
    || no "permission warnings suppressed unconditionally — a real problem would be hidden"
else ok "no kit or no nobody user to test ownership against (skipped)"; fi
rm -rf "$KGT"

echo "== T27: sizes and remote facts (v1.9.0) =="
# A measured zero and an unknown must not render alike -- the rule the v1.5.0 config split-brain
# taught, applied to every new byte count here.
mkdir -p /tmp/fr27
head -c 3000000 /dev/zero > /tmp/fr27/timecrate-2026-07-28_03-00-00.tar.zst.gpg
head -c 5000000 /dev/zero > /tmp/fr27/timecrate-2026-07-29_03-00-00.tar.zst.gpg
cat > /usr/local/bin/rclone <<'FAKE'
#!/bin/bash
args=(); skip=0; fmt=""; sep=","
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in --config) skip=1;; *) args+=("$a");; esac
done
n=${#args[@]}
for ((i=1; i<n; i++)); do
  case "${args[i]}" in
    --format)    fmt="${args[i+1]:-}";;
    --separator) sep="${args[i+1]:-}";;
  esac
done
case "${args[0]}" in
  lsf)
    [ "${TC_FAKE_UNLISTABLE:-0}" = 1 ] && { echo "fake rclone: directory not found" >&2; exit 3; }
    [ "${TC_FAKE_EMPTY:-0}" = 1 ] && exit 0
    for f in $(ls /tmp/fr27 2>/dev/null | grep '\.tar\.zst\.gpg$' | sort); do
      sz="$(stat -c %s "/tmp/fr27/$f")"; mt="$(date -r "/tmp/fr27/$f" '+%Y-%m-%d %H:%M:%S')"
      # 1.5 GiB each: two of them exceed a 32-bit integer, which is where a %d conversion in
      # some awks would wrap or clamp
      [ "${TC_FAKE_BIGSIZE:-0}" = 1 ] && sz=1610612736
      # a backend that ignores --format, or a name that ate the separators, yields a bare name
      if [ "${TC_FAKE_SHORTLINE:-0}" = 1 ] && [ "$f" != "${f%2026-07-29*}" ]; then
        printf '%s\n' "$f"; continue
      fi
      case "$fmt" in
        stp) printf '%s%s%s%s%s\n' "$sz" "$sep" "$mt" "$sep" "$f";;
        sp)  printf '%s%s%s\n' "$sz" "$sep" "$f";;
        *)   printf '%s\n' "$f";;
      esac
    done;;
  about)
    [ "${TC_FAKE_NOABOUT:-0}" = 1 ] && { echo "fake rclone: about not supported" >&2; exit 1; }
    echo '{"total":2199023255552,"used":1099511627776,"free":1099511627776}';;
esac
exit 0
FAKE
chmod +x /usr/local/bin/rclone

# a) bare `list` is still name-only -- restore validates its argument against this
l27="$("$TC" list 2>/dev/null)"
if printf '%s' "$l27" | grep -q $'\t'; then
  no "bare list grew columns — restore's argument validation and the GUI allow-list read this"
else
  [ "$(printf '%s\n' "$l27" | grep -c .)" = 2 ] \
    && ok "bare list unchanged (name-only, 2 kits)" || no "bare list returned: $l27"
fi
# b) --long carries real bytes, in three tab-separated fields, oldest first
ll27="$("$TC" list --long 2>/dev/null)"
if [ "$(printf '%s\n' "$ll27" | head -1 | awk -F'\t' '{print NF}')" = 3 ]; then
  ok "list --long emits three tab-separated fields"
else no "list --long field count wrong: $(printf '%s\n' "$ll27" | head -1)"; fi
[ "$(printf '%s\n' "$ll27" | head -1 | cut -f1)" = 3000000 ] \
  && ok "list --long reports the real byte size" \
  || no "list --long size wrong: $(printf '%s\n' "$ll27" | head -1 | cut -f1)"
printf '%s\n' "$ll27" | head -1 | grep -q 'timecrate-2026-07-28' \
  && ok "list --long is oldest-first, name in the last field" || no "list --long ordering/columns wrong"
# a kit whose listing line lacks the size columns must still be OFFERED, with size unknown --
# the GUI builds its restore list from this output, so a dropped line reads as a lost backup
TC_FAKE_SHORTLINE=1 "$TC" list --long >/tmp/t27s.out 2>/dev/null
[ "$(grep -c 'timecrate-' /tmp/t27s.out)" = 2 ] \
  && ok "a malformed listing line still yields its kit" || no "a short line dropped a kit: $(cat /tmp/t27s.out)"
grep -q '^-	-	timecrate-2026-07-29' /tmp/t27s.out \
  && ok "the unparseable line reports size UNKNOWN rather than inventing one" \
  || no "short line rendered as: $(grep 2026-07-29 /tmp/t27s.out)"
"$TC" list --bogus >/tmp/t27f.out 2>&1 && no "list accepted an unknown flag" \
  || { grep -q 'unknown list flag' /tmp/t27f.out && ok "list rejects an unknown flag" \
       || no "wrong error for a bad list flag: $(tail -1 /tmp/t27f.out)"; }

# c) status totals the kits and reports the quota it was actually given
s27="$("$TC" status --json 2>/dev/null)"
jq27(){ printf '%s' "$s27" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],"MISSING"))' "$1"; }
[ "$(jq27 cloud_bytes)" = 8000000 ] && ok "status cloud_bytes totals the remote" || no "cloud_bytes=$(jq27 cloud_bytes), expected 8000000"
[ "$(jq27 cloud_kits)" = 2 ] && ok "the size-bearing listing still counts kits correctly" || no "cloud_kits=$(jq27 cloud_kits)"
[ "$(jq27 remote_quota_total)" = 2199023255552 ] && ok "remote quota reported from rclone about" || no "quota total=$(jq27 remote_quota_total)"
# d) a backend with no `about` is not a backend at quota zero
s27="$(TC_FAKE_NOABOUT=1 "$TC" status --json 2>/dev/null)"
[ -z "$(jq27 remote_quota_total)" ] && [ -z "$(jq27 remote_quota_used)" ] \
  && ok "unsupported 'about' leaves the quota UNKNOWN, not zero" \
  || no "quota faked to '$(jq27 remote_quota_total)' when about failed"
[ "$(jq27 cloud_bytes)" = 8000000 ] && ok "a failed quota call does not lose the kit total" || no "cloud_bytes lost when about failed"
# e0) a listing whose size column did not arrive is UNKNOWN, not a measured zero and not a
#     partial total -- the kits are still counted, so "15 kits totalling 0 B" must be impossible
s27="$(TC_FAKE_SHORTLINE=1 "$TC" status --json 2>/dev/null)"
[ "$(jq27 cloud_kits)" = 2 ] && [ -z "$(jq27 cloud_bytes)" ] \
  && ok "a listing missing a size column totals UNKNOWN, never a partial or zero" \
  || no "short listing gave kits='$(jq27 cloud_kits)' bytes='$(jq27 cloud_bytes)'"
# e1) an empty remote that ANSWERED still totals a real, measured zero
s27="$(TC_FAKE_EMPTY=1 "$TC" status --json 2>/dev/null)"
[ "$(jq27 cloud_bytes)" = 0 ] && [ "$(jq27 cloud_kits)" = 0 ] \
  && ok "an empty but readable remote totals a measured 0" \
  || no "empty remote gave kits='$(jq27 cloud_kits)' bytes='$(jq27 cloud_bytes)'"
# e2) a total past 2^31 survives the awk conversion
s27="$(TC_FAKE_BIGSIZE=1 "$TC" status --json 2>/dev/null)"
[ "$(jq27 cloud_bytes)" = 3221225472 ] \
  && ok "a 3 GiB total is not truncated by awk's integer width" \
  || no "3 GiB total came back as '$(jq27 cloud_bytes)'"
# e) an unreadable remote reports UNKNOWN for both, never a healthy zero
s27="$(TC_FAKE_UNLISTABLE=1 "$TC" status --json 2>/dev/null)"
[ -z "$(jq27 cloud_bytes)" ] && [ -z "$(jq27 cloud_kits)" ] \
  && ok "an unlistable remote is UNKNOWN bytes AND UNKNOWN kits" \
  || no "unlistable remote reported bytes='$(jq27 cloud_bytes)' kits='$(jq27 cloud_kits)'"
rm -f /usr/local/bin/rclone

# f) the production backup path records bytes and duration
mkdir -p /tmp/tiny27; head -c 40000000 /dev/zero > /tmp/tiny27/blob
printf 'tmp/tiny27\n' > /tmp/inc27; printf '.git\n' > /tmp/exc27
export TIMECRATE_STATE=/tmp/tm27/state
if TIMECRATE_INCLUDE=/tmp/inc27 TIMECRATE_EXCLUDE=/tmp/exc27 TIMECRATE_STAGING=/tmp/tm27/stage \
     "$TC" backup --no-upload --force >/tmp/t27g.out 2>&1; then
  line="$(grep ' ok ' /tmp/tm27/state/log | tail -1)"
  [ "$(printf '%s' "$line" | awk '{print NF}')" = 6 ] \
    && ok "state log line carries six fields (bytes + duration appended)" \
    || no "state log line has $(printf '%s' "$line" | awk '{print NF}') fields: $line"
  # the recorded size must be the KIT's, not the staged tree's -- they differ by ~40x here
  kb27="$(printf '%s' "$line" | awk '{print $5}')"
  real27="$(stat -c %s "/tmp/tm27/stage/$(printf '%s' "$line" | awk '{print $4}')" 2>/dev/null || echo 0)"
  [ -n "$kb27" ] && [ "$kb27" = "$real27" ] \
    && ok "recorded bytes match the kit on disk ($kb27)" || no "recorded $kb27, kit is $real27"
  printf '%s' "$line" | awk '{exit ($6 ~ /^[0-9]+$/) ? 0 : 1}' \
    && ok "duration recorded as whole seconds" || no "duration field is not numeric: $line"
  s27="$("$TC" status --json 2>/dev/null)"
  # -n first: without it this passes when BOTH are empty, which is the failure it exists to catch
  [ -n "$(jq27 last_backup_bytes)" ] && [ "$(jq27 last_backup_bytes)" = "$kb27" ] \
    && ok "status last_backup_bytes matches the log line" || no "last_backup_bytes=$(jq27 last_backup_bytes)"
else no "T27 backup failed: $(tail -3 /tmp/t27g.out)"; fi

# g) a pre-1.9.0 four-field line reports UNKNOWN size, not 0 -- the GUI draws a trend from this
printf '2026-07-01T03:00:00-06:00 ok 2026-07-01_03-00-00 timecrate-2026-07-01_03-00-00.tar.zst.gpg\n' \
  > /tmp/tm27/state/log
"$TC" escrow-confirm >/dev/null 2>&1     # cheapest command that re-runs write_status
s27="$("$TC" status --json 2>/dev/null)"
[ -z "$(jq27 last_backup_bytes)" ] \
  && ok "a pre-1.9.0 log line reports size UNKNOWN, not 0" \
  || no "old log line reported last_backup_bytes='$(jq27 last_backup_bytes)'"
# h) one run is not two: previous_backup_bytes must stay empty rather than repeat the last one
printf '2026-07-02T03:00:00-06:00 ok 2026-07-02_03-00-00 timecrate-2026-07-02_03-00-00.tar.zst.gpg 111 9\n' \
  > /tmp/tm27/state/log
"$TC" escrow-confirm >/dev/null 2>&1
s27="$("$TC" status --json 2>/dev/null)"
[ "$(jq27 last_backup_bytes)" = 111 ] && [ -z "$(jq27 previous_backup_bytes)" ] \
  && ok "a single run leaves previous_backup_bytes UNKNOWN" \
  || no "single run gave last='$(jq27 last_backup_bytes)' previous='$(jq27 previous_backup_bytes)'"
printf '2026-07-03T03:00:00-06:00 ok 2026-07-03_03-00-00 timecrate-2026-07-03_03-00-00.tar.zst.gpg 222 9\n' \
  >> /tmp/tm27/state/log
"$TC" escrow-confirm >/dev/null 2>&1
s27="$("$TC" status --json 2>/dev/null)"
[ "$(jq27 last_backup_bytes)" = 222 ] && [ "$(jq27 previous_backup_bytes)" = 111 ] \
  && ok "two runs give last + previous separately" \
  || no "two runs gave last='$(jq27 last_backup_bytes)' previous='$(jq27 previous_backup_bytes)'"
export TIMECRATE_STATE=/tmp/tm/state    # back to the suite-wide state dir
rm -rf /tmp/fr27 /tmp/tm27 /tmp/tiny27 /tmp/inc27 /tmp/exc27

echo "== T28: remote management =="
mkdir -p /tmp/tmrem
export TIMECRATE_USER_CONF=/tmp/tmrem/user.conf
# a fake rclone whose behaviour is chosen per-case, because the point of `remote test` is that it
# tells apart the reasons it failed
mkfake(){ cat > /usr/local/bin/rclone; chmod +x /usr/local/bin/rclone; }

# --- the text and --json views must not disagree about the same remote
mkfake <<'FAKE'
#!/bin/bash
# cat with a quoted heredoc, NOT printf: printf eats the backslashes, and rclone's `token` field
# is a JSON string CONTAINING JSON, so the escapes are load-bearing. A malformed stub here fails
# the test while the code is fine, which is its own kind of lie.
case "$*" in
  *" config dump"*) cat <<'J'
{"dropbox":{"type":"dropbox","token":"{\"access_token\":\"SECRET-AT\",\"refresh_token\":\"SECRET-RT\",\"expiry\":\"2027-01-01T00:00:00Z\"}"}}
J
    ;;
  *" lsf "*) printf 'timecrate-2026-01-01_00-00-00.tar.zst.gpg\n' ;;
esac
exit 0
FAKE
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote status > /tmp/t27a.txt 2>&1 || true
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote status --json > /tmp/t27a.json 2>&1 || true
if grep -q 'backend *dropbox' /tmp/t27a.txt \
   && python3 -c 'import json;d=json.load(open("/tmp/t27a.json"));assert d["type"]=="dropbox" and d["configured"] and d["has_token"]' 2>/dev/null; then
  ok "remote status: text and --json agree that the remote is configured"
else
  no "remote status text/--json disagree: text=$(grep -c backend /tmp/t27a.txt) json=$(cat /tmp/t27a.json | head -c 120)"
fi
# --- and neither may ever print the token itself
if grep -qE 'SECRET-AT|SECRET-RT|access_token|refresh_token' /tmp/t27a.txt /tmp/t27a.json; then
  no "remote status LEAKED the OAuth token"
else ok "remote status never prints the token (expiry only)"; fi

# --- `remote test` must name the reason, not just say unreachable
mkfake <<'FAKE'
#!/bin/bash
case "$*" in *" lsf "*) echo "ERROR : : error listing: directory not found" >&2; exit 3;; esac
exit 0
FAKE
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote test >/tmp/t27b.out 2>&1 \
  && no "remote test passed against a missing path" \
  || { grep -q 'does not exist yet' /tmp/t27b.out && ok "remote test: a missing path is reported as a missing path" \
       || no "missing path misreported: $(tail -1 /tmp/t27b.out)"; }

mkfake <<'FAKE'
#!/bin/bash
case "$*" in *" lsf "*) echo "Failed to lsf: 401 Unauthorized: invalid_grant" >&2; exit 7;; esac
exit 0
FAKE
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote test >/tmp/t27c.out 2>&1 \
  && no "remote test passed against a rejected token" \
  || { grep -q 'reauthorize\|will not authenticate' /tmp/t27c.out && ok "remote test: a rejected token is reported as a token problem" \
       || no "auth failure misreported: $(tail -1 /tmp/t27c.out)"; }

# --- a remote that lists but cannot be written to is a backup that fails at 03:00, not now
mkfake <<'FAKE'
#!/bin/bash
case "$*" in
  *" lsf "*) exit 0 ;;
  *" rcat "*) echo "insufficient permissions" >&2; exit 7 ;;
esac
exit 0
FAKE
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote test >/tmp/t27d.out 2>&1 \
  && no "remote test passed a readable-but-unwritable remote" \
  || { grep -q 'NOT writable' /tmp/t27d.out && ok "remote test: readable but unwritable is caught now, not at 03:00" \
       || no "unwritable remote misreported: $(tail -1 /tmp/t27d.out)"; }

# --- browse must keep folder names containing spaces intact
mkfake <<'FAKE'
#!/bin/bash
case "$*" in *" lsd "*) printf '          -1 2026-01-01 00:00:00        -1 My Backups\n          -1 2026-01-01 00:00:00        -1 TIMECRATE\n' ;; esac
exit 0
FAKE
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote browse --json > /tmp/t27e.json 2>&1 || true
python3 -c 'import json;d=json.load(open("/tmp/t27e.json"));assert d==["My Backups","TIMECRATE"], d' 2>/dev/null \
  && ok "browse keeps folder names with spaces intact" || no "browse mangled names: $(cat /tmp/t27e.json)"

# --- set-path guards
mkfake <<'FAKE'
#!/bin/bash
case "$*" in *" lsf "*) printf 'timecrate-2026-01-01_00-00-00.tar.zst.gpg\n' ;; esac
exit 0
FAKE
rm -f /tmp/tmrem/user.conf
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote set-path /not/a/remote --yes >/tmp/t27f.out 2>&1 \
  && no "set-path accepted a path with no remote prefix" \
  || { grep -q 'not a remote path' /tmp/t27f.out && ok "set-path refuses a path that is not <remote>:<path>" \
       || no "wrong refusal: $(tail -1 /tmp/t27f.out)"; }
# without --yes and without a tty it must refuse rather than assume consent
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote set-path dropbox:Other </dev/null >/tmp/t27g.out 2>&1 \
  && no "set-path changed the remote with no tty and no --yes" \
  || ok "set-path will not change the remote without explicit consent"
[ -f /tmp/tmrem/user.conf ] && no "set-path wrote the config after refusing" || ok "a refused set-path leaves the config untouched"
# and the successful path keeps a rollback copy
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote set-path dropbox:First --yes >/dev/null 2>&1
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote set-path dropbox:Second --yes >/dev/null 2>&1
grep -q "TIMECRATE_REMOTE=dropbox:Second" /tmp/tmrem/user.conf && ok "set-path writes the new remote" \
  || no "set-path did not write: $(cat /tmp/tmrem/user.conf 2>/dev/null)"
grep -q "TIMECRATE_REMOTE=dropbox:First" /tmp/tmrem/user.conf.bak && ok "set-path keeps the previous config as .bak" \
  || no "no usable .bak rollback: $(cat /tmp/tmrem/user.conf.bak 2>/dev/null)"
# --- disconnect has to STICK. `${VAR:-default}` treats an explicitly empty value as unset, so
# before this the next command after a disconnect silently pointed back at the built-in default
# and a backup would have uploaded to a path nobody chose.
mkfake <<'FAKE'
#!/bin/bash
case "$*" in *" lsf "*) printf 'timecrate-2026-01-01_00-00-00.tar.zst.gpg\n' ;; esac
exit 0
FAKE
TIMECRATE_REMOTE='' "$TC" config 2>/dev/null | grep -qE '^ +REMOTE +$' \
  && ok "an explicitly empty remote stays empty (no silent fallback to the built-in default)" \
  || no "an empty remote fell back to: $(TIMECRATE_REMOTE='' "$TC" config 2>/dev/null | awk '$1=="REMOTE"{print $2}')"
TIMECRATE_REMOTE='' "$TC" list >/tmp/t28h.out 2>&1 \
  && no "list ran against a machine with no remote configured" \
  || { grep -q 'no remote is configured' /tmp/t28h.out && ok "commands needing a remote refuse clearly when there is none" \
       || no "wrong refusal with no remote: $(tail -1 /tmp/t28h.out)"; }
# ...but "there is no remote" is a status, not a reason to refuse to report status
TIMECRATE_REMOTE='' "$TC" remote status >/tmp/t28i.out 2>&1 \
  && grep -q 'NONE' /tmp/t28i.out && ok "remote status still reports on a disconnected machine" \
  || no "remote status failed on a disconnected machine: $(tail -1 /tmp/t28i.out)"
# and an UNSET remote must still take the built-in default, or every fresh install breaks
env -u TIMECRATE_REMOTE "$TC" config 2>/dev/null | awk '$1=="REMOTE"{exit ($2=="" ? 1 : 0)}' \
  && ok "an unset remote still takes the built-in default" || no "unset remote resolved to nothing"

# --- headless connect must actually switch rclone off the local-browser flow, not just say so
mkfake <<'FAKE'
#!/bin/bash
echo "$*" >> /tmp/t28-rclone-args
case "$*" in *" config dump"*) echo '{}' ;; *" lsf "*) exit 0 ;; esac
exit 0
FAKE
rm -f /tmp/t28-rclone-args
env -u DISPLAY -u WAYLAND_DISPLAY TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote connect >/dev/null 2>&1 || true
if grep -q 'config create dropbox dropbox config_is_local=false' /tmp/t28-rclone-args; then
  ok "headless connect asks rclone for the paste-a-token flow"
else
  no "headless connect still uses the local-browser flow: $(grep 'config create' /tmp/t28-rclone-args | head -1)"
fi

# --- the recovery path status output ADVERTISES has to work while disconnected
mkfake <<'FAKE'
#!/bin/bash
case "$*" in
  *" lsf "*) printf 'timecrate-2026-01-01_00-00-00.tar.zst.gpg\n' ;;
  *" lsd "*) printf '          -1 2026-01-01 00:00:00        -1 Backup\n' ;;
esac
exit 0
FAKE
rm -f /tmp/tmrem/user.conf
TIMECRATE_REMOTE='' "$TC" remote set-path dropbox:Backup/TC --yes >/tmp/t28j.out 2>&1 \
  && ok "set-path works on a disconnected machine (the advice in status is not a dead end)" \
  || no "set-path refused on a disconnected machine: $(tail -1 /tmp/t28j.out)"
TIMECRATE_REMOTE='' "$TC" remote browse dropbox:Backup >/tmp/t28k.out 2>&1 \
  && ok "browse with an explicit target works while disconnected" \
  || no "browse refused an explicit target while disconnected: $(tail -1 /tmp/t28k.out)"

# --- an unreadable TARGET must be refused, not written as "empty"
mkfake <<'FAKE'
#!/bin/bash
case "$*" in *" lsf "*) echo 'didn'"'"'t find section in config file' >&2; exit 1 ;; esac
exit 0
FAKE
rm -f /tmp/tmrem/user.conf
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote set-path typo:Whatever --yes >/tmp/t28l.out 2>&1 \
  && no "set-path wrote a destination it could not read, reporting it as empty" \
  || { grep -q 'Refusing to point backups' /tmp/t28l.out && ok "an unreadable destination is refused, not recorded as an empty one" \
       || no "wrong refusal for an unreadable destination: $(tail -1 /tmp/t28l.out)"; }
[ -f /tmp/tmrem/user.conf ] && no "the refused destination was written anyway" || ok "a refused destination leaves the config untouched"

# --- and the config keeps its mode rather than taking the umask
mkfake <<'FAKE'
#!/bin/bash
case "$*" in *" lsf "*) printf 'timecrate-2026-01-01_00-00-00.tar.zst.gpg\n' ;; esac
exit 0
FAKE
rm -f /tmp/tmrem/user.conf /tmp/tmrem/user.conf.bak
TIMECRATE_REMOTE=dropbox:A "$TC" remote set-path dropbox:B --yes >/dev/null 2>&1
chmod 600 /tmp/tmrem/user.conf
TIMECRATE_REMOTE=dropbox:B "$TC" remote set-path dropbox:C --yes >/dev/null 2>&1
m=$(stat -c '%a' /tmp/tmrem/user.conf 2>/dev/null); mb=$(stat -c '%a' /tmp/tmrem/user.conf.bak 2>/dev/null)
[ "$m" = 600 ] && [ "$mb" = 600 ] \
  && ok "rewriting the config preserves its mode, backup included ($m/$mb)" \
  || no "config mode widened by the umask: conf=$m bak=$mb"

# --- set-path --dry-run reports the cost and changes nothing. The graphical front-end shows the
# counts and the warning before it commits, and it has no tty for the interactive confirmation.
mkfake <<'FAKE'
#!/bin/bash
case "$*" in *" lsf "*) printf 'timecrate-2026-01-01_00-00-00.tar.zst.gpg\n' ;; esac
exit 0
FAKE
rm -f /tmp/tmrem/user.conf
TIMECRATE_REMOTE=dropbox:Backup/TC "$TC" remote set-path dropbox:Elsewhere --dry-run >/tmp/t28m.out 2>&1 \
  && ok "set-path --dry-run succeeds" || no "set-path --dry-run failed: $(tail -1 /tmp/t28m.out)"
grep -q 'DRY RUN' /tmp/t28m.out && ok "it says it changed nothing" || no "no DRY RUN marker"
grep -q 'current  dropbox:Backup/TC' /tmp/t28m.out && grep -q 'new      dropbox:Elsewhere' /tmp/t28m.out \
  && ok "--dry-run still reports the count at both ends" || no "--dry-run did not report both ends"
[ -f /tmp/tmrem/user.conf ] && no "--dry-run WROTE the config" || ok "--dry-run left the config untouched"

rm -f /usr/local/bin/rclone /tmp/t28-rclone-args
unset TIMECRATE_USER_CONF

echo "== T29: the include/exclude lists are editable, and only by root =="
cp /tmp/inc.small /tmp/paths.inc; chmod 644 /tmp/paths.inc
export TIMECRATE_INCLUDE=/tmp/paths.inc
"$TC" paths include list >/tmp/t29a.out 2>&1 && grep -qx 'tmp/tiny' /tmp/t29a.out \
  && ok "paths list reads the list without root" || no "paths list failed: $(tail -1 /tmp/t29a.out)"
# absolute in, relative-to-/ stored: that is what tar --files-from expects
"$TC" paths include add /var/lib/thing >/dev/null 2>&1
grep -qx 'var/lib/thing' /tmp/paths.inc && ok "an absolute path is stored relative to /" \
  || no "add stored the wrong form: $(tail -2 /tmp/paths.inc | tr '\n' ' ')"
# a home path becomes ~/ so the list survives a different username. "Home" is the configured
# user's, from passwd: the tool ignores $HOME, which a CI runner may point elsewhere (GitHub's
# container jobs set /github/home for root).
CONF_HOME=$(getent passwd "$(id -un)" | cut -d: -f6)
"$TC" paths include add "$CONF_HOME/Docs" >/dev/null 2>&1
# the list stores the literal two characters ~/ ; held in a variable so shellcheck does not read
# it as a tilde that failed to expand (SC2088), which it would in any quoted literal
TILDE='~'
grep -qx "${TILDE}/Docs" /tmp/paths.inc && ok "a path under the configured home is stored as ~/" \
  || no "home path stored as: $(tail -1 /tmp/paths.inc)"
"$TC" paths include add /var/lib/thing >/tmp/t29b.out 2>&1
grep -q 'already in' /tmp/t29b.out && ok "adding a duplicate says so instead of duplicating" \
  || no "duplicate not detected"
n=$(grep -c . /tmp/paths.inc)
"$TC" paths include remove /var/lib/thing >/dev/null 2>&1
"$TC" paths include remove "${TILDE}/Docs" >/dev/null 2>&1
[ "$(grep -c . /tmp/paths.inc)" -eq $((n-2)) ] && ok "remove takes exactly the entries it names" \
  || no "remove changed the wrong number of lines"
"$TC" paths include remove /not/there >/tmp/t29c.out 2>&1 \
  && no "removing an absent entry reported success" \
  || { grep -q 'not in the' /tmp/t29c.out && ok "removing an absent entry says so" || no "wrong error"; }
# a newline would inject a second entry; .. would climb out of the tree the list describes.
# Both arrive from a graphical file chooser, so neither is hypothetical.
"$TC" paths include add "$(printf 'a\nb')" >/tmp/t29d.out 2>&1 \
  && no "a path containing a newline was accepted" \
  || { grep -q 'control character or newline' /tmp/t29d.out && ok "a newline in a path is refused" || no "wrong refusal"; }
"$TC" paths include add /etc/../root >/tmp/t29e.out 2>&1 \
  && no "a path containing .. was accepted" \
  || { grep -q "may not contain" /tmp/t29e.out && ok "'..' in a path is refused" || no "wrong refusal"; }
"$TC" paths bogus list >/tmp/t29f.out 2>&1 && no "an unknown list name was accepted" \
  || { grep -q "expected 'include' or 'exclude'" /tmp/t29f.out && ok "an unknown list name is refused" || no "wrong error"; }
# the conffile mode must survive an edit
chmod 640 /tmp/paths.inc; "$TC" paths include add /var/tmp/modecheck >/dev/null 2>&1
[ "$(stat -c '%a' /tmp/paths.inc)" = 640 ] && ok "editing preserves the file mode" \
  || no "mode changed to $(stat -c '%a' /tmp/paths.inc)"
# and it must refuse without root
if setpriv --reuid=1 --regid=1 --clear-groups "$TC" paths include add /tmp/x >/tmp/t29g.out 2>&1; then
  no "an unprivileged user edited the include list"
else
  grep -q 'must run as root' /tmp/t29g.out && ok "editing refuses without root" \
    || ok "could not drop privileges here (skipped)"
fi
# a filename with an accent in it is a filename, not an attack
"$TC" paths include add "/var/lib/R\xc3\xa9sum\xc3\xa9" >/dev/null 2>&1
"$TC" paths include add "$(printf '/var/lib/caf\xc3\xa9')" >/tmp/t29h.out 2>&1 \
  && grep -q 'caf' /tmp/paths.inc && ok "a UTF-8 path is accepted" \
  || no "a UTF-8 path was refused: $(tail -1 /tmp/t29h.out)"
# a directory whose name ends in a space is a different directory
"$TC" paths include add "/var/lib/trailing " >/dev/null 2>&1
grep -qx 'var/lib/trailing ' /tmp/paths.inc && ok "a trailing space in a path is preserved" \
  || no "trailing space was trimmed, changing which path was stored"

# add/remove is read-modify-rename; two of them interleaved must not discard one another
: > /tmp/paths.race; chmod 644 /tmp/paths.race
for i in $(seq 1 12); do
  TIMECRATE_INCLUDE=/tmp/paths.race "$TC" paths include add "/race/$i" >/dev/null 2>&1 &
done
wait
got=$(grep -c '^race/' /tmp/paths.race || true)
[ "$got" -eq 12 ] && ok "12 concurrent edits all landed (no lost update)" \
  || no "concurrent edits lost entries: $got of 12 survived"

unset TIMECRATE_INCLUDE

echo "== T30: history and alerting =="
mkdir -p /tmp/tmhist
cat > /tmp/tmhist/log <<'LOG'
2026-07-01T03:00:00-06:00 ok 2026-07-01_03-00-00 timecrate-2026-07-01_03-00-00.tar.zst.gpg
2026-07-02T03:00:00-06:00 ok 2026-07-02_03-00-00 timecrate-2026-07-02_03-00-00.tar.zst.gpg 11748704 26
2026-07-03T01:00:00-06:00 drill PASSED 2026-07-02_03-00-00
LOG
export TIMECRATE_STATE=/tmp/tmhist
"$TC" history --json > /tmp/t30a.json 2>&1
python3 - <<'PY' && ok "history parses both the pre-1.9.0 and the current line shapes" || no "history parse wrong: $(cat /tmp/t30a.json)"
import json, sys
d = json.load(open("/tmp/t30a.json"))
assert len(d) == 3, d
# a line written before bytes/seconds existed reports UNKNOWN, never a confident zero
assert d[0]["kind"] == "backup" and d[0]["bytes"] == "" and d[0]["seconds"] == "", d[0]
assert d[1]["bytes"] == "11748704" and d[1]["seconds"] == "26", d[1]
assert d[2]["kind"] == "drill" and d[2]["result"] == "PASSED", d[2]
PY
"$TC" history -n 1 --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if len(d)==1 else 1)' \
  && ok "-n limits the number of runs" || no "-n ignored"
"$TC" history -n abc >/tmp/t30b.out 2>&1 && no "-n accepted a non-number" \
  || { grep -q 'takes a number' /tmp/t30b.out && ok "-n rejects a non-number" || no "wrong error"; }
# a machine that has never run must say so rather than fail
rm -f /tmp/tmhist/log
"$TC" history --json | grep -qx '\[\]' && ok "no history yet reports an empty list, not an error" \
  || no "empty history did not report []"
unset TIMECRATE_STATE

# alerts: the command may be set in a root-only file, so an unprivileged read genuinely cannot
# tell -- and reporting that as "not configured" is the same lie as an unreadable keyring read as absent
cat > /tmp/tmhist/hook <<'HOOK'
#!/bin/sh
# records what the alert path hands a receiver: argv, then the message from stdin
{ printf 'ARGS %s|%s|%s\n' "$1" "$2" "$3"; cat; } >> /tmp/tmhist/hook.log
exit "${HOOK_RC:-0}"
HOOK
chmod 755 /tmp/tmhist/hook
printf 'TIMECRATE_ALERT_CMD=/tmp/tmhist/hook\n' > /tmp/tmhist/secret.env
chmod 600 /tmp/tmhist/secret.env
TIMECRATE_SECRET_ENV=/tmp/tmhist/secret.env "$TC" alerts --json > /tmp/t30c.json 2>&1
python3 -c 'import json;d=json.load(open("/tmp/t30c.json"));assert d["configured"] is True and d["command"]=="/tmp/tmhist/hook" and d["severity"]=="critical"' 2>/dev/null \
  && ok "alerts reports the command and severity a FAILURE uses" || no "alerts wrong: $(cat /tmp/t30c.json)"
if setpriv --reuid=1 --regid=1 --clear-groups env TIMECRATE_SECRET_ENV=/tmp/tmhist/secret.env \
     "$TC" alerts --json > /tmp/t30d.json 2>&1; then
  python3 -c 'import json;d=json.load(open("/tmp/t30d.json"));assert d["readable"] is False and d["configured"]==""' 2>/dev/null \
    && ok "an unreadable secrets file reports UNKNOWN, not 'not configured'" \
    || no "unreadable secrets misreported: $(cat /tmp/t30d.json)"
else ok "could not drop privileges here (skipped)"; fi
# and with no command anywhere, it really is journal-only
TIMECRATE_SECRET_ENV=/tmp/tmhist/nothere "$TC" alerts --json | \
  python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if d["configured"] is False else 1)' \
  && ok "no command anywhere reports journal-only (configured=false)" || no "absent command misreported"
"$TC" alerts bogus >/tmp/t30e.out 2>&1 && no "an unknown alerts subcommand was accepted" \
  || { grep -q 'expected status or test' /tmp/t30e.out && ok "an unknown alerts subcommand is refused" || no "wrong error"; }

# `alerts test` must use the real runner, the real command and a failure's severity
rm -f /tmp/tmhist/hook.log
if TIMECRATE_SECRET_ENV=/tmp/tmhist/secret.env "$TC" alerts test >/tmp/t30f.out 2>&1; then
  grep -q '\[timecrate\] delivered\.' /tmp/t30f.out && ok "alerts test reports delivery" || no "no delivery line: $(tail -1 /tmp/t30f.out)"
  grep -q '^ARGS critical|Timecrate alert test (not a real failure)|test$' /tmp/tmhist/hook.log \
    && ok "the command gets severity, title and key as arguments" \
    || no "hook arguments wrong: $(head -1 /tmp/tmhist/hook.log 2>/dev/null)"
  grep -q 'Nothing is actually wrong' /tmp/tmhist/hook.log \
    && ok "and the message on standard input" || no "the message did not reach the command's stdin"
else no "alerts test failed with a working command: $(tail -2 /tmp/t30f.out)"; fi
HOOK_RC=3 TIMECRATE_SECRET_ENV=/tmp/tmhist/secret.env "$TC" alerts test >/tmp/t30g.out 2>&1 \
  && no "alerts test PASSED although the command exited 3" \
  || { grep -q 'did NOT go through' /tmp/t30g.out && ok "a command that fails makes alerts test fail" \
       || no "wrong error for a failing command: $(tail -1 /tmp/t30g.out)"; }
TIMECRATE_SECRET_ENV=/tmp/tmhist/nothere "$TC" alerts test >/tmp/t30h.out 2>&1 \
  && no "alerts test passed with no command configured" \
  || { grep -q 'TIMECRATE_ALERT_CMD is not set' /tmp/t30h.out && ok "alerts test without a command says the journal is all there is" \
       || no "wrong error with no command: $(tail -1 /tmp/t30h.out)"; }
# The test has to use the severity a FAILURE uses: a friendlier one would prove a path failures do
# not take. The wrappers carry the literal; the engine carries ALERT_SEVERITY.
fail_sev=$(grep -ho 'alert\.sh" [a-z]*' "$REPO"/deploy/backup-and-alert.sh | awk '{print $2}' | sort -u | tr '\n' ' ')
test_sev="$(grep -m1 '^ALERT_SEVERITY=' "$TC" | cut -d'"' -f2)"
[ "$fail_sev" = "$test_sev " ] \
  && ok "alerts test uses the severity a real backup failure does ($test_sev)" \
  || no "alerts test sends at '$test_sev' but backup failures use '$fail_sev'"

# the runner itself: journal always, the command when set, and a loud line when it cannot deliver
AL="$REPO/deploy/alert.sh"
out="$(printf 'body text\n' | env -u TIMECRATE_ALERT_CMD TIMECRATE_SYSTEM_CONF=/nonexistent TIMECRATE_SECRET_ENV=/nonexistent \
       bash "$AL" warn "a title" backup 2>&1)"; arc=$?
[ "$arc" = 0 ] && printf '%s' "$out" | grep -q '^\[timecrate\]\[ALERT\] warn: a title' && printf '%s' "$out" | grep -q 'body text' \
  && ok "with no command, the runner writes the alert to the journal and succeeds" || no "journal-only runner: rc=$arc $out"
out="$(printf 'x\n' | TIMECRATE_ALERT_CMD=/nonexistent/cmd TIMECRATE_SYSTEM_CONF=/nonexistent TIMECRATE_SECRET_ENV=/nonexistent \
       bash "$AL" critical t k 2>&1)"; arc=$?
[ "$arc" != 0 ] && printf '%s' "$out" | grep -q 'NOT delivered' \
  && ok "a command that is not executable fails the alert loudly" || no "non-executable command: rc=$arc $out"
rm -f /tmp/tmhist/hook.log
TIMECRATE_ALERT_CMD=/tmp/tmhist/hook TIMECRATE_SYSTEM_CONF=/nonexistent TIMECRATE_SECRET_ENV=/nonexistent \
  bash "$AL" --unit-failed timecrate-backup.service </dev/null >/dev/null 2>&1
grep -q '^ARGS critical|Timecrate unit timecrate-backup.service failed on .*|unit-timecrate-backup.service$' /tmp/tmhist/hook.log \
  && grep -q 'journalctl -u timecrate-backup.service' /tmp/tmhist/hook.log \
  && ok "the OnFailure path names the unit and how to investigate it" \
  || no "OnFailure alert wrong: $(cat /tmp/tmhist/hook.log 2>/dev/null | head -2)"
# the environment wins over the files, as it does for the engine
printf 'TIMECRATE_ALERT_CMD=/nonexistent/from-file\n' > /tmp/tmhist/sys.conf
rm -f /tmp/tmhist/hook.log
printf 'x\n' | TIMECRATE_ALERT_CMD=/tmp/tmhist/hook TIMECRATE_SYSTEM_CONF=/tmp/tmhist/sys.conf \
  TIMECRATE_SECRET_ENV=/nonexistent bash "$AL" info t k >/dev/null 2>&1 \
  && [ -s /tmp/tmhist/hook.log ] && ok "an alert command in the environment beats one in a file" \
  || no "the file's command overrode the environment's"
rm -rf /tmp/tmhist

echo "== T31: verify against the remote, and a sweep that counts (v2.4.0) =="
if [ -n "${kit:-}" ] && [ -f "${kit:-}" ]; then
  mkdir -p /tmp/fr31
  kitname="$(basename "$kit")"
  cp "$kit" "/tmp/fr31/$kitname"
  cp "$kit.sha256" "/tmp/fr31/$kitname.sha256" 2>/dev/null || true
  # An OLDER, corrupt kit. It sorts FIRST, so a sweep that stops at the first failure never
  # reaches the good one and would report 0 verified rather than 1 — which is the whole point of
  # running each kit in a subshell.
  bad31="timecrate-2026-01-01_00-00-00.tar.zst.gpg"
  head -c 4096 /dev/urandom > "/tmp/fr31/$bad31"
  cat > /usr/local/bin/rclone <<'FAKE'
#!/bin/bash
args=(); skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in --config|--format|--separator) skip=1;; *) args+=("$a");; esac
done
case "${args[0]}" in
  lsf)    ls /tmp/fr31 2>/dev/null | grep '\.tar\.zst\.gpg$' | sort;;
  copyto) f="/tmp/fr31/$(basename "${args[1]}")"; [ -f "$f" ] && cp "$f" "${args[2]}" || exit 1;;
esac
exit 0
FAKE
  chmod +x /usr/local/bin/rclone

  # a) the newest kit, fetched and checked end to end
  if "$TC" verify --remote >/tmp/t31a.out 2>&1; then
    grep -q 'VERIFY OK: 1/1' /tmp/t31a.out \
      && ok "verify --remote fetches and verifies the newest kit" \
      || no "verify --remote said: $(tail -1 /tmp/t31a.out)"
  else no "verify --remote failed: $(tail -3 /tmp/t31a.out)"; fi
  # b) a kit named explicitly
  ts31="${kitname#timecrate-}"; ts31="${ts31%.tar.zst.gpg}"
  "$TC" verify --remote "$ts31" >/tmp/t31b.out 2>&1 \
    && ok "verify --remote <ts> verifies the named kit" \
    || no "named kit failed: $(tail -2 /tmp/t31b.out)"
  # c) a kit that is not there is an error, not an empty pass
  if "$TC" verify --remote 2000-01-01_00-00-00 >/tmp/t31c.out 2>&1; then
    no "verify --remote accepted a kit the remote does not hold"
  else
    grep -q 'no such kit' /tmp/t31c.out && ok "an absent kit is refused by name" \
      || no "wrong error: $(tail -1 /tmp/t31c.out)"
  fi
  # d) THE SWEEP: it must reach the good kit even though the first one blew up
  if "$TC" verify --all >/tmp/t31d.out 2>&1; then
    no "verify --all PASSED with a corrupt kit on the remote"
  else
    grep -q '1/2 verified' /tmp/t31d.out \
      && ok "the sweep continued past the bad kit and counted 1/2" \
      || no "sweep did not report 1/2: $(grep -o '[0-9]*/[0-9]* verified' /tmp/t31d.out | head -1)"
    # anchored to the SUMMARY line: a bare name match also succeeds on the die message printed
    # when the sweep aborts at the first bad kit, which is the failure this is here to catch
    grep -q "FAILED:.*$bad31" /tmp/t31d.out && ok "the sweep names the kit that failed" \
      || no "the failing kit is not named in the summary: $(tail -1 /tmp/t31d.out)"
  fi
  # e) the two ways of asking that do not mean anything
  "$TC" verify --all "$ts31" >/tmp/t31e.out 2>&1 && no "verify --all accepted a kit name" \
    || { grep -q 'takes no kit name' /tmp/t31e.out && ok "verify --all refuses a kit name" \
         || no "wrong error: $(tail -1 /tmp/t31e.out)"; }
  "$TC" verify --bogus >/tmp/t31f.out 2>&1 && no "verify accepted an unknown flag" \
    || { grep -q 'unknown verify flag' /tmp/t31f.out && ok "verify rejects an unknown flag" \
         || no "wrong error: $(tail -1 /tmp/t31f.out)"; }
  # f) the original local-file form still works
  "$TC" verify "$kit" >/tmp/t31g.out 2>&1 \
    && ok "verify <localfile> is unchanged" || no "local verify broke: $(tail -2 /tmp/t31g.out)"
  # g) nothing is left behind in staging
  [ -z "$(find "${TIMECRATE_STAGING:-/tmp/tm/staging}" -maxdepth 1 -name '.verify.*' 2>/dev/null)" ] \
    && ok "the sweep cleans up its work directory" || no "a .verify.* work dir survived"
  rm -f /usr/local/bin/rclone; rm -rf /tmp/fr31

  # h) break-glass must not be a second, ungated route to overwriting the running system.
  # `restore --to-root` verifies and demands a typed confirmation; passing / as the target
  # directory reaches the identical `tar -C /` without any of it.
  "$TC" break-glass "$kit" / >/tmp/t31h.out 2>&1 && no "break-glass extracted over / " \
    || { grep -q "refusing to extract over /" /tmp/t31h.out \
         && ok "break-glass refuses / and names the gated command instead" \
         || no "wrong refusal for /: $(tail -1 /tmp/t31h.out)"; }
  # It must refuse BEFORE doing anything, not after. The banner is printed on the way to
  # extracting, so its absence is the proof that nothing downstream of the guard ran -- an mtime
  # check on some system file only fires if that file happened to be in the kit, which is how a
  # check like this passes while the extraction it is watching for actually happened.
  grep -q 'Tool-independent recovery' /tmp/t31h.out \
    && no "break-glass got as far as the extraction banner before refusing /" \
    || ok "the / refusal happens before anything is printed or written"
  # a symlink pointing at / must resolve to the same refusal, not slip past a string comparison
  ln -sfn / /tmp/slip31
  "$TC" break-glass "$kit" /tmp/slip31 >/tmp/t31i.out 2>&1 && no "a symlink to / was accepted" \
    || { grep -q "refusing to extract over /" /tmp/t31i.out \
         && ok "a symlink resolving to / is refused too" \
         || no "symlink to / gave: $(tail -1 /tmp/t31i.out)"; }
  rm -f /tmp/slip31
  # ...but an ordinary directory still works, or the guard has eaten the command
  rm -rf /tmp/bg31; mkdir -p /tmp/bg31
  "$TC" break-glass "$kit" /tmp/bg31 >/tmp/t31j.out 2>&1
  [ -d /tmp/bg31 ] && grep -q 'Tool-independent recovery' /tmp/t31j.out \
    && ok "break-glass into an ordinary directory still runs" \
    || no "the / guard broke normal break-glass: $(tail -2 /tmp/t31j.out)"
  rm -rf /tmp/bg31
else ok "no signed kit available to verify against (skipped)"; fi

echo "== T32: restore --to-root actually extracts over / (and a forged kit does not) =="
# This path had ZERO execution coverage: --to-root appeared only in allow-list string checks.
# It is also the audit's original P1 -- "restore --to-root extracts unauthenticated tar as root"
# -- so the assertion that matters most is the negative one. A container is exactly the place
# this can be run for real: it is disposable, and the kit below writes one directory under /tmp.

# a) THE HEADLINE: a forged (encrypted, unsigned) kit must write NOTHING to /.
#    /tmp/forged.tar.zst.gpg holds a member called `evil` at the archive root, so a successful
#    extraction to / would leave /evil behind. Its absence is the proof.
rm -f /evil
if "$TC" restore --local /tmp/forged.tar.zst.gpg --to-root --force >/tmp/t32a.out 2>&1; then
  no "FORGED kit was extracted OVER / (the audit's original P1, live)"
else
  grep -q 'NO signature' /tmp/t32a.out \
    && ok "forged kit refused on the --to-root path too" \
    || no "forged --to-root died with the wrong error: $(tail -1 /tmp/t32a.out)"
fi
[ ! -e /evil ] \
  && ok "and it wrote NOTHING to / (no /evil)" \
  || { no "the forged kit landed a file at / despite the refusal"; rm -f /evil; }

# b) a genuine kit really does extract over /, with the content it carried
mkdir -p /tmp/tm-rootmark && echo "proof-of-root-restore" > /tmp/tm-rootmark/proof
printf 'tmp/tm-rootmark\n' > /tmp/inc32; printf '.git\n' > /tmp/exc32
if TIMECRATE_INCLUDE=/tmp/inc32 TIMECRATE_EXCLUDE=/tmp/exc32 TIMECRATE_STAGING=/tmp/tm32 \
     "$TC" backup --no-upload --force >/tmp/t32b.out 2>&1; then
  kit32="$(ls /tmp/tm32/timecrate-*.tar.zst.gpg 2>/dev/null | head -1)"
  rm -rf /tmp/tm-rootmark          # the thing a bare-metal restore has to bring back
  if [ -n "$kit32" ] && "$TC" restore --local "$kit32" --to-root --force >/tmp/t32c.out 2>&1; then
    [ "$(cat /tmp/tm-rootmark/proof 2>/dev/null)" = "proof-of-root-restore" ] \
      && ok "restore --to-root put the file back at its real path under /" \
      || no "--to-root reported success but the file is not at /tmp/tm-rootmark/proof"
    # the manifests are a restore-time aid, not system content: extracting them to / would
    # litter the root of a recovered machine
    [ ! -e /TIMECRATE-MANIFESTS ] \
      && ok "TIMECRATE-MANIFESTS is excluded from a / extraction" \
      || { no "/TIMECRATE-MANIFESTS was extracted onto the root filesystem"; rm -rf /TIMECRATE-MANIFESTS; }
    grep -q 'extracting straight to /' /tmp/t32c.out \
      && ok "--to-root warns that it is writing over the running system" \
      || no "--to-root extracted over / with no warning in the output"
  else no "restore --to-root FAILED on a genuine kit: $(tail -3 /tmp/t32c.out)"; fi
else no "T32 backup failed: $(tail -3 /tmp/t32b.out)"; fi
rm -rf /tmp/tm32 /tmp/tm-rootmark /tmp/inc32 /tmp/exc32

echo "== T33: pkexec sets no SUDO_USER — the account must not silently become root (v2.6.0) =="
# The GUI runs every privileged operation as `pkexec timecrate …`, and pkexec sets PKEXEC_UID,
# not SUDO_USER. So on any box that had not pinned TIMECRATE_USER the resolution fell through to
# `id -un` = root, and every GUI-driven backup, restore and drill quietly used root's home and
# root's empty keyring. The shipped conffile pins nothing, so that was the default after apt install.
# This script is documented as runnable in-place (REPO=…, and CI runs it that way), so it is not
# safe to assume a throwaway container: deleting a name we did not create would remove a real
# account. Mint a pid-scoped name, only when nothing answers to it already, and only ever remove
# one this invocation actually created.
tmu="tmpk$$"
tmu_made=0
# Outputs go in a private 0700 directory, not fixed /tmp names. This section runs as root, and on
# a shared host a predictable /tmp/<name> can be pre-created as a symlink for a root redirect to
# follow and truncate. It also collides for real: T32 above already writes /tmp/t32a.out.
umask 077
t33="$(mktemp -d)"
# ...and the account is removed on INT/TERM as well as EXIT. Without this the earlier claim that
# an early exit cannot strand it was simply untrue: ^C skips every line below.
trap '[ "${tmu_made:-0}" = 1 ] && userdel "$tmu" >/dev/null 2>&1; rm -rf "${t33:-}"' EXIT INT TERM
# -M: no home directory is created, and none is removed -- `userdel -r` here has no directory to
# take with it. Nothing below needs the home to exist: USER_HOME is read from the passwd entry
# (getent, field 6), never from the filesystem, so `config` reports the path either way. That is
# what makes this safe rather than carefully guarded -- `useradd -m` will happily adopt a
# directory that is already there and say so only in a warning, and then `userdel -r` deletes it.
if id -u "$tmu" >/dev/null 2>&1; then
  pkuid=""            # something already owns the name: touch nothing, delete nothing
elif useradd -M -s /bin/bash "$tmu" >/dev/null 2>&1; then
  tmu_made=1
  pkuid="$(id -u "$tmu" 2>/dev/null || true)"
else
  pkuid=""
fi
if [ -n "$pkuid" ]; then
  # strip every other answer to "who is this for", so PKEXEC_UID is the only signal left standing
  tmenv=(env -u SUDO_USER -u TIMECRATE_USER -u TIMECRATE_CONF -u TIMECRATE_STATE -u TIMECRATE_STAGING)
  "${tmenv[@]}" PKEXEC_UID="$pkuid" "$TC" config > "$t33/a.out" 2>&1
  grep -qE "^ *TC_USER +$tmu( |\$)" "$t33/a.out" \
    && ok "PKEXEC_UID resolves the invoking account (the GUI's path)" \
    || no "PKEXEC_UID ignored, TC_USER is: $(grep -E '^ *TC_USER' "$t33/a.out" | head -1)"
  # The account name is only half of it. USER_HOME is what the keyring, the rclone token and the
  # backed-up home all hang off, and landing in /root is the damage — asserting the name alone
  # would pass even if nothing downstream of it moved.
  grep -qE "^ *CONF_DIR +/home/$tmu/" "$t33/a.out" \
    && ok "...and the keyring directory follows it out of /root" \
    || no "CONF_DIR stayed behind: $(grep -E '^ *CONF_DIR' "$t33/a.out" | head -1)"
  grep -q 'from PKEXEC_UID' "$t33/a.out" \
    && ok "config says WHERE the account came from, not just what it is" \
    || no "config does not report the provenance of TC_USER"
  # sudo must still win. pkexec never sets both, but a wrapper might, and SUDO_USER is the
  # stronger statement of intent — inverting this would be a regression dressed as a fix.
  "${tmenv[@]}" SUDO_USER="$tmu" PKEXEC_UID=0 "$TC" config > "$t33/b.out" 2>&1
  grep -qE "^ *TC_USER +$tmu( |\$)" "$t33/b.out" && ok "SUDO_USER still outranks PKEXEC_UID" \
    || no "PKEXEC_UID overrode SUDO_USER: $(grep -E '^ *TC_USER' "$t33/b.out" | head -1)"
  # an explicit pin outranks both, INCLUDING a deliberate root — otherwise the fix has quietly
  # taken away the ability to say "yes, root, I meant it"
  "${tmenv[@]}" TIMECRATE_USER=root PKEXEC_UID="$pkuid" "$TC" config > "$t33/c.out" 2>&1
  grep -qE '^ *TC_USER +root( |$)' "$t33/c.out" && ok "an explicit TIMECRATE_USER outranks both" \
    || no "TIMECRATE_USER=root was overridden by PKEXEC_UID"
  grep -q 'acts as ROOT' "$t33/c.out" && no "the root warning nags about a DELIBERATE pin" \
    || ok "a deliberate TIMECRATE_USER=root is not warned about"
  # a uid with no passwd entry must fall back, not resolve to an empty name and then an empty home
  "${tmenv[@]}" PKEXEC_UID=999999 "$TC" config > "$t33/d.out" 2>&1
  grep -qE '^ *TC_USER +root( |$)' "$t33/d.out" \
    && ok "an unresolvable PKEXEC_UID falls back instead of emptying the account" \
    || no "unresolvable PKEXEC_UID gave: $(grep -E '^ *TC_USER' "$t33/d.out" | head -1)"
  # ...and root-with-nothing-to-infer-from is the systemd timer's case, which PKEXEC_UID cannot
  # help with. It is still wrong, so it has to say so out loud rather than proceed quietly.
  "${tmenv[@]}" "$TC" config > "$t33/e.out" 2>&1
  grep -q 'acts as ROOT' "$t33/e.out" \
    && ok "an unpinned root run warns that it is acting on root's home" \
    || no "unpinned root run is silent about acting as root"
  grep -qE '^ *TC_USER +root +\(NOT pinned' "$t33/e.out" \
    && ok "config marks the fallback as unpinned rather than as a choice" \
    || no "config presents fallback-root as a configured value: $(grep -E '^ *TC_USER' "$t33/e.out" | head -1)"
  # root running `sudo timecrate` sets SUDO_USER=root: unpinned root, so it must still warn --
  # but the warning must not claim nothing identified a caller, because SUDO_USER did. Matching
  # the reason INSIDE the warning line, not anywhere in the output, or the TC_USER line below it
  # satisfies the grep on its own and the assertion means nothing.
  "${tmenv[@]}" SUDO_USER=root "$TC" config > "$t33/f.out" 2>&1
  grep -q 'acts as ROOT' "$t33/f.out" \
    && ok "sudo run BY root still warns — unpinned root is unpinned root" \
    || no "sudo-as-root skipped the warning entirely"
  grep 'acts as ROOT' "$t33/f.out" | grep -q 'from SUDO_USER' \
    && ok "...and the warning names what DID resolve it instead of denying a caller" \
    || no "the warning denies the caller that resolved the account: $(grep 'acts as ROOT' "$t33/f.out" | head -1)"
  # The per-user config is sourced AFTER the account is resolved -- so on a fallback-root run it is
  # read out of /root, reached only because of the fallback. If it sets TIMECRATE_USER, that
  # value took no part in resolution, and a warning keyed on the variable rather than on what
  # resolution actually did would fall silent on the strength of a file the bug itself found.
  printf 'TIMECRATE_USER=%s\n' "$tmu" > "$t33/late.conf"
  "${tmenv[@]}" TIMECRATE_USER_CONF="$t33/late.conf" "$TC" config > "$t33/g.out" 2>&1
  grep -q 'acts as ROOT' "$t33/g.out" \
    && ok "a TIMECRATE_USER set too late to resolve anything does not silence the warning" \
    || no "a late per-user TIMECRATE_USER suppressed the fallback-root warning"
  grep -qE "^ *TC_USER +root( |$)" "$t33/g.out" \
    && ok "...and the account really did stay root, so the warning was the honest one" \
    || no "the late config changed the resolved account: $(grep -E '^ *TC_USER' "$t33/g.out" | head -1)"
  rm -f "$t33/late.conf"
else ok "no disposable account could be minted here (skipped)"; fi

echo "== T34: root never writes backups through a path the target user controls =="
# The container runs everything as root, which is the blind spot that hid the original ownership
# bug. Drop to a real unprivileged user so these mean something.
if id -u nobody >/dev/null 2>&1; then
  rm -rf /tmp/t34stage /tmp/t34victim; mkdir -p /tmp/t34victim
  victim_before=$(stat -c '%U' /tmp/t34victim)

  # staging is root-owned by construction now, so there is no ownership to hand over and nothing
  # for a symlink swap to steal. Belt and braces: a symlinked staging path is still refused.
  ln -s /tmp/t34victim /tmp/t34stage
  out=$(TIMECRATE_USER=nobody TIMECRATE_STAGING=/tmp/t34stage \
        TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small \
        "$TC" backup --no-upload --force 2>&1 || true)
  [ "$(stat -c '%U' /tmp/t34victim)" = "$victim_before" ] \
    && ok "a symlinked staging path did not transfer ownership of its target" \
    || no "PRIVILEGE ESCALATION: /tmp/t34victim changed hands"
  printf '%s' "$out" | grep -q 'refusing to use' \
    && ok "and root refuses to write backups through it" \
    || no "root did not refuse the redirected path: $(printf '%s' "$out" | tail -1)"
  # nothing may have been written on the other side of the link
  find /tmp/t34victim -name 'timecrate-*' -o -name '.stage.*' | grep -q . \
    && no "root wrote into the symlink target anyway" || ok "nothing was written through the link"

  # A root-controlled base, because /tmp is world-writable and is now refused outright for a
  # non-root TC_USER -- which is the whole point of the rule, and is asserted separately below.
  rm -f /tmp/t34stage; rm -rf /var/lib/t34stage
  TIMECRATE_USER=nobody TIMECRATE_STAGING=/var/lib/t34stage \
    TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small \
    "$TC" backup --no-upload --force >/dev/null 2>&1 || true
  if [ -d /var/lib/t34stage ]; then
    [ "$(stat -c '%U' /var/lib/t34stage)" = root ] \
      && ok "staging is root-owned, so there is no user-controlled path for root to follow" \
      || no "staging is owned by $(stat -c '%U' /var/lib/t34stage) — that is the shared-ownership design this replaced"
    [ "$(stat -c '%a' /var/lib/t34stage)" = 700 ] && ok "and it is 700" || no "staging mode is $(stat -c '%a' /var/lib/t34stage)"
  else no "staging was not created"; fi

  # THE PRODUCTION CASE. Until 2.6.1 the default staging lived inside the configured user's home,
  # which is precisely the shape that let that user redirect a root write. It must be refused by
  # the ancestor rule, not merely by a symlink check -- the user need never make the final
  # component a symlink; owning an ancestor is enough.
  home34="$(getent passwd nobody | cut -d: -f6)"
  if [ -n "$home34" ] && [ "$home34" != /nonexistent ]; then
    hs34="$home34/archives/tm"
  else
    hs34=/tmp/t34home/archives/tm; mkdir -p /tmp/t34home; chown nobody /tmp/t34home
  fi
  out34h="$(TIMECRATE_USER=nobody TIMECRATE_STAGING="$hs34" \
      TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small \
      "$TC" backup --no-upload --force 2>&1 || true)"
  printf '%s' "$out34h" | grep -q 'refusing to use' \
    && ok "staging inside the target user's home is refused (the shape that shipped until 2.6.1)" \
    || no "root accepted staging under the user's home: $(printf '%s' "$out34h" | tail -1)"
  [ ! -e "$hs34" ] && ok "and nothing was created there" || no "root created $hs34 anyway"
  rm -rf /tmp/t34home

  # ...and the bug all of this exists to fix: an unprivileged verify must still work
  kit34=$(ls /var/lib/t34stage/timecrate-*.tar.zst.gpg 2>/dev/null | head -1)
  if [ -n "$kit34" ]; then
    cp "$kit34" /tmp/t34kit.tar.zst.gpg; cp "$kit34.sha256" /tmp/t34kit.tar.zst.gpg.sha256 2>/dev/null || true
    chmod 644 /tmp/t34kit.tar.zst.gpg*
    # The claim under test is narrow and must not be satisfied by an escape branch: verify must
    # get somewhere writable. Whether this particular copied kit passes its checksum is a
    # different question, so assert on the permission failure and on the fallback firing.
    setpriv --reuid=1 --regid=1 --clear-groups env HOME=/tmp XDG_CACHE_HOME=/tmp/t34cache \
      TIMECRATE_STAGING=/var/lib/t34stage "$TC" verify /tmp/t34kit.tar.zst.gpg >/tmp/t34v.out 2>&1 || true
    grep -qi 'permission denied' /tmp/t34v.out \
      && no "unprivileged verify still cannot write: $(grep -i 'permission denied' /tmp/t34v.out | head -1)" \
      || ok "unprivileged verify is not blocked by root-owned staging"
    # The cache fallback lives on the --remote/--all path, which needs a real remote and so is
    # not exercised here; it was verified on the box instead (unprivileged `verify --remote`
    # against root-owned 700 staging). Asserting it from this test would only ever have been
    # checking the single-file path, which uses the kit's own directory and never touches staging.
  fi
  # The case that actually broke: staging is root-owned AND DOES NOT EXIST YET. verify used to
  # mkdir it unconditionally and die with "Permission denied" before reaching its own fallback —
  # the exact situation the fallback exists for. A live check missed it because the directory had
  # already been created by hand.
  if [ -n "$kit34" ]; then
    rm -rf /tmp/t34absent /tmp/t34cache2
    mkdir -p /tmp/t34remote && cp "$kit34" /tmp/t34remote/ && cp "$kit34.sha256" /tmp/t34remote/ 2>/dev/null || true
    # readable by the unprivileged caller, whatever umask an earlier test left: the fake lists it
    # AS that user, and an unreadable fixture reads as an empty remote
    chmod 755 /tmp/t34remote && chmod 644 /tmp/t34remote/*
    cat > /usr/local/bin/rclone <<'FAKE'
#!/bin/bash
case "$*" in
  *" lsf "*) ls /tmp/t34remote | grep '\.tar\.zst\.gpg$' ;;
  *" copyto "*) for a in "$@"; do :; done; src=$(echo "$*" | awk '{print $(NF-1)}'); dst=$(echo "$*" | awk '{print $NF}'); cp "/tmp/t34remote/$(basename "$src")" "$dst" 2>/dev/null || exit 1 ;;
esac
exit 0
FAKE
    chmod 755 /usr/local/bin/rclone
    setpriv --reuid=1 --regid=1 --clear-groups env HOME=/tmp XDG_CACHE_HOME=/tmp/t34cache2 \
      TIMECRATE_STAGING=/tmp/t34absent/staging TIMECRATE_REMOTE=fake:kits \
      "$TC" verify --all >/tmp/t34w.out 2>&1 || true
    grep -qi 'mkdir.*permission denied' /tmp/t34w.out \
      && no "verify died in mkdir before its fallback when staging did not exist" \
      || ok "verify does not die creating a staging directory it cannot create"
    [ -d /tmp/t34cache2/timecrate ] \
      && ok "and the fallback directory is the caller's cache" \
      || no "the cache fallback did not fire: $(tail -1 /tmp/t34w.out)"
    rm -f /usr/local/bin/rclone; rm -rf /tmp/t34remote /tmp/t34absent /tmp/t34cache2
  fi
  rm -rf /tmp/t34stage /tmp/t34victim /tmp/t34cache /tmp/t34kit.tar.zst.gpg*
else
  ok "no nobody user here (skipped)"
fi

echo "== T35: root never chowns the rclone config, and a refreshed token still gets home =="
# The chown this replaces was a check-then-act on a path under the user's home: readlink -f then
# chown -h, with the ancestors re-resolved in between. Nothing tested it in either form.
if id -u nobody >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
  rm -rf /tmp/t35; mkdir -p /tmp/t35/userhome/.config/rclone
  # An earlier test leaves umask 077, which would make /tmp/t35 root-owned 700 and unreachable to
  # nobody — the write-back would then fail on path traversal, not on anything the tool does. Make
  # the fixture explicit rather than inheriting whatever umask happens to be in force.
  chmod 755 /tmp/t35 /tmp/t35/userhome /tmp/t35/userhome/.config /tmp/t35/userhome/.config/rclone
  printf 'token = original\n' > /tmp/t35/userhome/.config/rclone/rclone.conf
  chown -R nobody /tmp/t35/userhome
  # a root-owned file the old primitive could have handed over via an ancestor swap
  printf 'root only\n' > /tmp/t35/victim; chown root:root /tmp/t35/victim; chmod 600 /tmp/t35/victim
  v35_before="$(stat -c '%U' /tmp/t35/victim)"
  # fake rclone that REFRESHES ITS TOKEN, i.e. rewrites the config it was handed
  cat > /usr/local/bin/rclone <<'FAKE'
#!/bin/bash
cfg=""; prev=""
for a in "$@"; do [ "$prev" = --config ] && cfg="$a"; prev="$a"; done
[ -n "$cfg" ] && [ -f "$cfg" ] && printf 'token = refreshed\n' > "$cfg"
exit 0
FAKE
  chmod +x /usr/local/bin/rclone
  TIMECRATE_USER=nobody TIMECRATE_RCLONE_CONF=/tmp/t35/userhome/.config/rclone/rclone.conf \
    "$TC" list >/tmp/t35.out 2>&1 || true

  [ "$(stat -c '%U' /tmp/t35/userhome/.config/rclone/rclone.conf)" = nobody ] \
    && ok "the config is still owned by the user after a root-run rclone" \
    || no "root left the config owned by $(stat -c '%U' /tmp/t35/userhome/.config/rclone/rclone.conf)"
  # the refresh must actually be propagated: a fix that simply drops the write is a token
  # silently lost, and the failure shows up as a surprise re-authentication weeks later
  grep -q 'refreshed' /tmp/t35/userhome/.config/rclone/rclone.conf \
    && ok "and a refreshed token was written back" \
    || no "the refreshed token was DROPPED — config says: $(cat /tmp/t35/userhome/.config/rclone/rclone.conf) | tool said: $(tail -2 /tmp/t35.out)"
  [ "$(stat -c '%U' /tmp/t35/victim)" = "$v35_before" ] \
    && ok "no root-owned file changed hands" || no "PRIVILEGE ESCALATION: /tmp/t35/victim is now $(stat -c '%U' /tmp/t35/victim)"

  # THE MECHANISM, not the symptom. The assertions above pass for the vulnerable implementation
  # too: a chown to TC_USER also leaves the config owned by TC_USER, and the fake rclone writing
  # straight to the real path also leaves the token refreshed. What separates the two is whether
  # root RESOLVES a path whose ancestors somebody else controls. So give it one: a symlinked
  # ancestor pointing at a root-owned file. chown follows it; reading and writing as the user
  # cannot.
  mkdir -p /tmp/t35/rootdir; chmod 755 /tmp/t35/rootdir
  printf 'root only\n' > /tmp/t35/rootdir/rclone.conf
  chown root:root /tmp/t35/rootdir/rclone.conf; chmod 600 /tmp/t35/rootdir/rclone.conf
  ln -sfn /tmp/t35/rootdir /tmp/t35/link
  TIMECRATE_USER=nobody TIMECRATE_RCLONE_CONF=/tmp/t35/link/rclone.conf \
    "$TC" list >/tmp/t35b.out 2>&1 || true
  [ "$(stat -c '%U' /tmp/t35/rootdir/rclone.conf)" = root ] \
    && ok "a root-owned file behind a symlinked ancestor is NOT handed over" \
    || no "PRIVILEGE ESCALATION: root chowned through the symlinked ancestor — /tmp/t35/rootdir/rclone.conf is now $(stat -c '%U' /tmp/t35/rootdir/rclone.conf)"
  rm -f /usr/local/bin/rclone; rm -rf /tmp/t35
else ok "no nobody/runuser available for the rclone-config test (skipped)"; fi

echo "== T36: pause skips backups without ever looking like a healthy one =="
# A pause makes backups not happen while everything else still reports fine — the exact silent
# success class the founding audit was about. Every guard against that gets its own assertion.
export TIMECRATE_STATE=/tmp/tm36/state
rm -rf /tmp/tm36; mkdir -p /tmp/tm36/state /tmp/tiny36
head -c 30000000 /dev/zero > /tmp/tiny36/blob
printf 'tmp/tiny36\n' > /tmp/inc36; printf '.git\n' > /tmp/exc36
bk36(){ TIMECRATE_INCLUDE=/tmp/inc36 TIMECRATE_EXCLUDE=/tmp/exc36 \
        TIMECRATE_STAGING=/tmp/tm36/stage "$TC" backup --no-upload "$@"; }

# a) no duration, or a silly one, is refused — an indefinite pause is the trap
"$TC" pause >/tmp/t36a.out 2>&1 && grep -q 'not paused' /tmp/t36a.out \
  && ok "bare 'pause' reports state rather than pausing" || no "bare pause: $(tail -1 /tmp/t36a.out)"
"$TC" pause forever >/tmp/t36b.out 2>&1 && no "pause accepted a non-duration" \
  || { grep -qE 'usage:|unknown duration unit' /tmp/t36b.out && ok "a non-duration is refused" \
       || no "wrong error: $(tail -1 /tmp/t36b.out)"; }
"$TC" pause 99d >/tmp/t36c.out 2>&1 && no "pause accepted 99 days" \
  || { grep -q 'refusing to pause for longer' /tmp/t36c.out \
       && ok "a pause beyond the ceiling is refused, and points at the visible alternative" \
       || no "wrong error for 99d: $(tail -1 /tmp/t36c.out)"; }

# b) a live pause actually skips the backup, and exits 0 so a timer does not page
"$TC" pause 2h >/tmp/t36d.out 2>&1
grep -q 'PAUSED until' /tmp/t36d.out && ok "pause reports its deadline" || no "pause said: $(tail -1 /tmp/t36d.out)"
grep -q '\[timecrate\]\[WARN\]' /tmp/t36d.out \
  && ok "setting a pause is a WARNING, so the window floats it above the success banner" \
  || no "pause was logged as routine, not as a reduction in protection"
if bk36 >/tmp/t36e.out 2>&1; then
  grep -q 'skipping this run' /tmp/t36e.out && ok "a paused backup skips and exits 0 (a deliberate pause is not a page)" \
    || no "backup ran while paused: $(tail -1 /tmp/t36e.out)"
else no "a paused backup exited NON-ZERO — a scheduled run would page for a state the operator chose"; fi
[ -z "$(find /tmp/tm36/stage -name 'timecrate-*' 2>/dev/null)" ] \
  && ok "and no kit was built" || no "a kit was built despite the pause"

# c) it must be VISIBLE — this is the whole safety argument
"$TC" status >/tmp/t36f.out 2>&1 || true
grep -q 'PAUSED until' /tmp/t36f.out && ok "status says PAUSED, first line of the report" \
  || no "status did not mention the pause at all: $(head -3 /tmp/t36f.out)"
"$TC" status --json 2>/dev/null | grep -q '"paused_until": *"20' \
  && ok "status --json carries paused_until for the GUI" || no "paused_until missing from status --json"

# d) --force overrides, and says so
if bk36 --force >/tmp/t36g.out 2>&1; then
  grep -q 'running anyway because --force' /tmp/t36g.out \
    && ok "--force overrides the pause, loudly" || no "--force ran with no mention of the pause"
else no "--force could not override the pause: $(tail -2 /tmp/t36g.out)"; fi

# e) THE EXPIRY. A pause that outlives its own deadline is the silent trap wearing a deadline.
printf '%s\n' "$(date -Is -d '@1')" > /tmp/tm36/state/paused
"$TC" status >/tmp/t36h.out 2>&1 || true
grep -q 'PAUSED' /tmp/t36h.out && no "an EXPIRED pause still reports as paused" \
  || ok "an expired pause is not a pause"
[ ! -e /tmp/tm36/state/paused ] && ok "and the lapsed file is cleaned up" || no "the expired pause file survived"
printf 'not-a-date\n' > /tmp/tm36/state/paused
"$TC" status >/tmp/t36i.out 2>&1 || true
grep -q 'PAUSED' /tmp/t36i.out && no "an UNREADABLE deadline was treated as paused-forever" \
  || ok "a deadline that cannot be read means over, never forever"

# f) pause off, and the drill is untouched throughout
"$TC" pause 2h >/dev/null 2>&1
"$TC" pause off >/tmp/t36j.out 2>&1
grep -q 'pause cleared' /tmp/t36j.out && ok "pause off clears it" || no "pause off: $(tail -1 /tmp/t36j.out)"
bk36 >/tmp/t36k.out 2>&1 && grep -q 'backup complete' /tmp/t36k.out \
  && ok "and backups run again afterwards" || no "backup did not resume: $(tail -2 /tmp/t36k.out)"
grep -qi 'pause' <<<"$(sed -n '/^cmd_recovery_drill()/,/^}/p' "$TC")" \
  && no "the drill consults the pause — the one thing that proves kits are restorable must keep running" \
  || ok "the drill never consults the pause"
# g) THE UMASK TRAP. `pause` runs as root; `status` is documented as needing no root. If the pause
# file inherits a restrictive umask it is root-only: root-run backups read it and skip, while an
# unprivileged status cannot read it and reports NO pause. Backups silently not happening behind a
# healthy-looking screen is the precise failure this feature exists to prevent.
# The parent must be traversable (that is the harness's job), but STATE_DIR is left at 0700 ON
# PURPOSE: making it reachable is the CODE's job, and the earlier version of this test pre-chmod'd
# it to 0755 and so never exercised the thing under test.
chmod 755 /tmp/tm36 2>/dev/null || true
chmod 700 /tmp/tm36/state 2>/dev/null || true
( umask 077; "$TC" pause 2h >/dev/null 2>&1 )
# Structural, and honestly so. write_status ALSO chmods STATE_DIR to 755, so after `pause` returns
# no end-state check can tell the guard apart from that — an earlier version of this assertion
# passed with the guard deleted. What must actually hold is the ORDER: the pause file is never
# published while the directory is unreachable. Assert that.
pl36="$(sed -n '/^cmd_pause()/,/^}/p' "$TC")"
g36=$(printf '%s' "$pl36" | grep -n 'could not be made traversable' | head -1 | cut -d: -f1)
mv36=$(printf '%s' "$pl36" | grep -n 'mv -f "\$tmpf"' | head -1 | cut -d: -f1)
if [ -n "$g36" ] && [ -n "$mv36" ] && [ "$g36" -lt "$mv36" ]; then
  ok "the traversability guard runs BEFORE the pause file is published"
else
  no "pause publishes without first proving STATE_DIR is reachable (guard=${g36:-absent} publish=${mv36:-absent})"
fi
[ "$(stat -c '%a' /tmp/tm36/state/paused 2>/dev/null)" = 644 ] \
  && ok "the pause file is 0644 whatever the umask" \
  || no "pause file is mode $(stat -c '%a' /tmp/tm36/state/paused 2>/dev/null) — unreadable to an unprivileged status"
if id -u nobody >/dev/null 2>&1; then
  out36="$(setpriv --reuid=nobody --regid=nogroup --clear-groups \
      env TIMECRATE_STATE=/tmp/tm36/state HOME=/tmp "$TC" status 2>&1 || true)"
  printf '%s' "$out36" | grep -q 'PAUSED' \
    && ok "an unprivileged status still reports the pause" \
    || no "SILENT PAUSE — backups would skip while status looks healthy: $(printf '%s' "$out36" | head -2)"
else ok "no nobody user for the unprivileged-status check (skipped)"; fi
"$TC" pause off >/dev/null 2>&1

export TIMECRATE_STATE=/tmp/tm/state
rm -rf /tmp/tm36 /tmp/tiny36 /tmp/inc36 /tmp/exc36

echo "== T37: the capstone job verifies effects, not exit codes (v2.9.0) =="
# This job runs a real VM, so the suite cannot run it end to end. What it CAN pin down is the bug
# that actually shipped: `multipass transfer` returned zero for a source that did not exist, the
# `||` fallback chain therefore never ran, the guard never fired, and the run died inside the VM
# with "No such file or directory" — a silent success in the script written to catch silent
# successes. Everything below is driven with a fake multipass.
CAP="$REPO/deploy/capstone-and-alert.sh"
rm -rf /tmp/t37; mkdir -p /tmp/t37/bin /tmp/t37/conf /tmp/t37/home
chmod 755 /tmp/t37 /tmp/t37/home
printf 'key\n'  > /tmp/t37/conf/timecrate-secret.asc
printf 'pub\n'  > /tmp/t37/conf/timecrate-signing-public.asc
printf 'rc\n'   > /tmp/t37/rclone.conf

# a) preflight must NAME a missing prerequisite rather than dying quietly
out37="$(TIMECRATE_USER=root TIMECRATE_CONF=/tmp/t37/conf \
    TIMECRATE_RCLONE_CONF=/tmp/t37/rclone.conf PATH=/usr/bin:/bin \
    bash "$CAP" --preflight 2>&1 || true)"
printf '%s' "$out37" | grep -q 'multipass not installed' \
  && ok "preflight names the missing prerequisite instead of failing silently" \
  || no "preflight said: $(printf '%s' "$out37" | head -1)"

# b) with everything stubbed it passes AND reports which recover-in-vm.sh it resolved — the value
#    the old version never decided up front
cat > /tmp/t37/bin/timecrate <<'FAKE'
#!/bin/bash
[ "$1" = list ] && { echo "timecrate-2026-01-01_00-00-00.tar.zst.gpg"; exit 0; }
exit 0
FAKE
chmod +x /tmp/t37/bin/timecrate
cat > /tmp/t37/bin/multipass <<'FAKE'
#!/bin/bash
case "$1" in
  list)     echo "Name,State,IPv4,Image"; echo "timecrate-capstone-vm,Running,192.0.2.2,Ubuntu";;
  launch)   exit 0;;
  transfer) exit 0;;                 # THE BUG: reports success, moves nothing
  exec)     shift; case "$*" in *"stat -c %s"*) exit 0;; esac; exit 0;;
  stop|delete) exit 0;;
esac
exit 0
FAKE
chmod +x /tmp/t37/bin/multipass
out37b="$(TIMECRATE_USER=root TIMECRATE_CONF=/tmp/t37/conf \
    TIMECRATE_RCLONE_CONF=/tmp/t37/rclone.conf PATH=/tmp/t37/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    bash "$CAP" --preflight 2>&1 || true)"
printf '%s' "$out37b" | grep -q 'PREFLIGHT OK' \
  && ok "preflight passes once prerequisites exist" || no "preflight: $(printf '%s' "$out37b" | head -1)"
printf '%s' "$out37b" | grep -q 'recover=.*recover-in-vm.sh' \
  && ok "and it resolves recover-in-vm.sh up front, naming the path it will use" \
  || no "preflight did not report a resolved recover-in-vm.sh: $out37b"

# c) THE REGRESSION. A transfer that exits 0 and moves nothing must be caught, not trusted.
#    The fake above returns success for `transfer` and reports NO size for the destination.
mkdir -p /tmp/t37/state
cat > /tmp/t37/bin/rclone <<'FAKE'
#!/bin/bash
# pretend the fetch worked so the run reaches the staging step under test
for a in "$@"; do last="$a"; done
printf 'kit\n' > "$last" 2>/dev/null || true
exit 0
FAKE
chmod +x /tmp/t37/bin/rclone
out37c="$(TIMECRATE_USER=root TIMECRATE_CONF=/tmp/t37/conf \
    TIMECRATE_RCLONE_CONF=/tmp/t37/rclone.conf PATH=/tmp/t37/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    bash "$CAP" 2>&1 || true)"
printf '%s' "$out37c" | grep -q 'did not land' \
  && ok "a transfer that exits 0 but moves nothing is CAUGHT (the bug that shipped)" \
  || no "the run trusted a lying transfer: $(printf '%s' "$out37c" | tail -2)"
printf '%s' "$out37c" | grep -q 'CAPSTONE FAILED' \
  && ok "and the failure is printed to the journal, not only to the alert gateway" \
  || no "nothing was printed for a failed run — journalctl would show an empty failed unit"

# d) the VM holds the escrowed key, so a cleanup that cannot prove removal must SAY so
cat > /tmp/t37/bin/multipass <<'FAKE'
#!/bin/bash
case "$1" in
  list) echo "Name,State,IPv4,Image"; echo "timecrate-capstone-vm,Running,192.0.2.2,Ubuntu";;  # never goes away
  *) exit 0;;
esac
exit 0
FAKE
chmod +x /tmp/t37/bin/multipass
out37d="$(TIMECRATE_USER=root TIMECRATE_CONF=/tmp/t37/conf \
    TIMECRATE_RCLONE_CONF=/tmp/t37/rclone.conf PATH=/tmp/t37/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TIMECRATE_CAPSTONE_VM=timecrate-capstone-vm bash "$CAP" 2>&1 || true)"
printf '%s' "$out37d" | grep -q 'ESCROWED SECRET KEY' \
  && ok "an undestroyable VM is reported as holding key material, not left silently" \
  || no "cleanup could not remove the VM and said nothing about the key inside it"
rm -rf /tmp/t37

echo "== T38: staging lands where the confined snap can actually read it (v2.10.0) =="
# multipass is a STRICTLY CONFINED snap with its own private /tmp, so a `mktemp -d` staging dir is
# invisible to it: `transfer` reports "[sftp] cannot access <path>: No such file or directory" for
# a file that plainly exists. v2.9.0 staged into /tmp and so could never pass against a real
# multipass — every input failed to land, on a quarterly timer, for the one test that proves this
# machine can be rebuilt. T37's fake accepts any source, which is exactly why it missed this.
# This fake refuses /tmp the way the real snap does, and answers `stat` only for what it accepted.
rm -rf /tmp/t38; mkdir -p /tmp/t38/bin /tmp/t38/conf /tmp/t38/landed
printf 'key\n' > /tmp/t38/conf/timecrate-secret.asc
printf 'pub\n' > /tmp/t38/conf/timecrate-signing-public.asc
printf 'rc\n'  > /tmp/t38/rclone.conf
cat > /tmp/t38/bin/timecrate <<'FAKE'
#!/bin/bash
[ "$1" = list ] && { echo "timecrate-2026-01-01_00-00-00.tar.zst.gpg"; exit 0; }
exit 0
FAKE
cat > /tmp/t38/bin/rclone <<'FAKE'
#!/bin/bash
for a in "$@"; do last="$a"; done
printf 'kit\n' > "$last" 2>/dev/null || true
exit 0
FAKE
cat > /tmp/t38/bin/multipass <<'FAKE'
#!/bin/bash
key(){ echo "$1" | tr / _; }
case "$1" in
  list)   echo "Name,State,IPv4,Image"; echo "timecrate-capstone-vm,Running,192.0.2.2,Ubuntu";;
  launch) exit 0;;
  transfer)
    echo "$2" >> /tmp/t38/sources
    # Model the snap's confinement instead of accepting any path (T37's fake accepts anything,
    # which is precisely why it missed all of this). The `home` interface covers $HOME only, and
    # excludes dotfiles; /tmp is private to the snap. Everything else is genuinely invisible, and
    # this is the exact wording multipass emits for it.
    case "$2" in
      "$HOME"/.*|"$HOME"/*/.*) echo "[sftp] cannot access $2: No such file or directory" >&2; exit 2;;
      "$HOME"/*) ;;
      *)                       echo "[sftp] cannot access $2: No such file or directory" >&2; exit 2;;
    esac
    stat -c %s "$2" > "/tmp/t38/landed/$(key "${3#*:}")" 2>/dev/null; exit 0;;
  exec)
    # NOT ${*##* } to get the last argument: on $*/$@ the ## strips the pattern from EVERY
    # positional parameter and rejoins them, so it yields the whole arg string, not the tail.
    shift; for a in "$@"; do last="$a"; done
    case "$*" in *"stat -c %s"*) cat "/tmp/t38/landed/$(key "$last")" 2>/dev/null || exit 1;; esac
    exit 0;;
  stop|delete) exit 0;;
esac
exit 0
FAKE
chmod +x /tmp/t38/bin/*
out38="$(TIMECRATE_USER=root TIMECRATE_CONF=/tmp/t38/conf \
    TIMECRATE_RCLONE_CONF=/tmp/t38/rclone.conf PATH=/tmp/t38/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TIMECRATE_CAPSTONE_VM=timecrate-capstone-vm bash "$CAP" 2>&1 || true)"
printf '%s' "$out38" | grep -q 'did not land' \
  && no "staging is invisible to the confined snap — every input failed to land: $(printf '%s' "$out38" | head -1)" \
  || ok "every staged input lands where the confined snap can read it"
grep -qv "^/root/" /tmp/t38/sources 2>/dev/null \
  && no "staged from outside \$HOME, where the snap cannot read: $(grep -m1 -v '^/root/' /tmp/t38/sources)" \
  || ok "and every source sat under \$HOME, not /tmp and not /opt"
# The staging dir is owned by TC_USER (it must be: rclone writes there as that user, and the
# confined snap reads it as that user). So root must never write into it — a root `cp` there
# follows a symlink the owner can plant between mktemp and copy, and a wildcard `chown` without
# -h would hand them the target. Source-level invariant: privileged copies go through asuser,
# and no wildcard chown exists. Behavioural proof needs a second uid, which this container has not.
grep -qE '^\s*cp "\$CONF|^\s*cp "\$RECOVER_SRC' "$CAP" \
  && no "root copies directly into the TC_USER-owned staging dir (symlink-follow on the destination)" \
  || ok "privileged copies into the staging dir all run as TC_USER, not root"
grep -q 'chown "\$TC_USER" "\$WORK"/\*' "$CAP" \
  && no "wildcard chown over a user-owned dir — chown follows symlinks without -h" \
  || ok "and no wildcard chown walks entries the owner could have added"
rm -rf /tmp/t38 /root/timecrate-capstone-work.* 2>/dev/null

echo "== T39: the capstone rebuilds the kit it was ASKED for (v2.10.0) =="
# overnight-suite.sh has always run T2 with TIMECRATE_CAPSTONE_KIT=oldest to prove that kits written by
# older releases are still restorable — and capstone-and-alert.sh read that variable NOWHERE,
# taking `list | tail -1`. `list` is oldest-first, so every "oldest kit" rebuild ever performed was
# a rebuild of the NEWEST kit. The test asked, nothing checked, and the answer was wrong for the
# entire life of the check. Assert the kit actually FETCHED, which is the only observable effect.
rm -rf /tmp/t39; mkdir -p /tmp/t39/bin /tmp/t39/conf
printf 'key\n' > /tmp/t39/conf/timecrate-secret.asc
printf 'pub\n' > /tmp/t39/conf/timecrate-signing-public.asc
printf 'rc\n'  > /tmp/t39/rclone.conf
cat > /tmp/t39/bin/timecrate <<'FAKE'
#!/bin/bash
# `list` is sorted OLDEST FIRST — that ordering is the whole trap
[ "$1" = list ] && { printf 'timecrate-2026-01-01_00-00-00.tar.zst.gpg\ntimecrate-2026-05-05_00-00-00.tar.zst.gpg\ntimecrate-2026-09-09_00-00-00.tar.zst.gpg\n'; exit 0; }
exit 0
FAKE
cat > /tmp/t39/bin/rclone <<'FAKE'
#!/bin/bash
for a in "$@"; do prev="$last"; last="$a"; done
echo "$prev" >> /tmp/t39/fetched      # the remote source of the copyto
printf 'kit\n' > "$last" 2>/dev/null || true
exit 0
FAKE
cat > /tmp/t39/bin/multipass <<'FAKE'
#!/bin/bash
case "$1" in list) echo "Name,State,IPv4,Image";; esac
exit 0
FAKE
chmod +x /tmp/t39/bin/*
t39run(){ env TIMECRATE_USER=root TIMECRATE_CONF=/tmp/t39/conf \
  TIMECRATE_RCLONE_CONF=/tmp/t39/rclone.conf PATH=/tmp/t39/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  TIMECRATE_CAPSTONE_VM=timecrate-capstone-vm "$@" bash "$CAP" 2>&1 || true; }

: > /tmp/t39/fetched; t39run TIMECRATE_CAPSTONE_KIT=oldest >/dev/null
grep -q '2026-01-01' /tmp/t39/fetched \
  && ok "TIMECRATE_CAPSTONE_KIT=oldest fetches the OLDEST kit" \
  || no "asked for the oldest, fetched: $(head -1 /tmp/t39/fetched 2>/dev/null || echo nothing)"

: > /tmp/t39/fetched; t39run TIMECRATE_CAPSTONE_KIT=newest >/dev/null
grep -q '2026-09-09' /tmp/t39/fetched \
  && ok "and the default/newest selection still takes the newest" \
  || no "asked for the newest, fetched: $(head -1 /tmp/t39/fetched 2>/dev/null || echo nothing)"

out39="$(t39run TIMECRATE_CAPSTONE_KIT=timecrate-not-a-real-kit.tar.zst.gpg)"
printf '%s' "$out39" | grep -q 'is not a kit on' \
  && ok "and an unknown kit name is refused by name, not silently ignored" \
  || no "an unknown TIMECRATE_CAPSTONE_KIT was not rejected: $(printf '%s' "$out39" | head -1)"
rm -rf /tmp/t39 /root/timecrate-capstone-work.* 2>/dev/null

echo "== T40: a VM that never comes back is a failure, not a hang (v2.10.0) =="
# The reboot check was `mp restart` followed by a blind `sleep 20`, and no multipass call had a
# timeout. On 2026-08-04 the guest sat in "Restarting" with the daemon idle and the run waited
# forever — the same shape as the thirty-hour hang recorded on 2026-08-03. A blind sleep calls a
# slow-but-healthy reboot a failure and a wedged guest a success; the run must decide, and finish.
rm -rf /tmp/t40; mkdir -p /tmp/t40/bin /tmp/t40/conf
printf 'key\n' > /tmp/t40/conf/timecrate-secret.asc
printf 'pub\n' > /tmp/t40/conf/timecrate-signing-public.asc
printf 'rc\n'  > /tmp/t40/rclone.conf
cp /tmp/t39/bin/rclone /tmp/t40/bin/ 2>/dev/null || printf '#!/bin/bash\nfor a in "$@"; do last="$a"; done\nprintf "kit\\n" > "$last" 2>/dev/null\nexit 0\n' > /tmp/t40/bin/rclone
printf '#!/bin/bash\n[ "$1" = list ] && { echo "timecrate-2026-01-01_00-00-00.tar.zst.gpg"; exit 0; }\nexit 0\n' > /tmp/t40/bin/timecrate
cat > /tmp/t40/bin/multipass <<'FAKE'
#!/bin/bash
key(){ echo "$1" | tr / _; }
case "$1" in
  list)   echo "Name,State,IPv4,Image"; echo "timecrate-capstone-vm,Running,192.0.2.2,Ubuntu";;
  launch) exit 0;;
  transfer) stat -c %s "$2" > "/tmp/t40/landed/$(key "${3#*:}")" 2>/dev/null; exit 0;;
  exec)
    shift; for a in "$@"; do last="$a"; done
    # After the reboot the guest does not merely fail — it BLOCKS, like a wedged daemon. If the
    # readiness probe inherited the long mp() timeout, 36 iterations of this would take hours.
    # A fake that fails instantly (the first cut of T40) cannot tell those two apart. The sleep
    # holds no output pipe, so a timed-out probe's command substitution returns with it.
    [ -f /tmp/t40/rebooted ] && { sleep 300 >/dev/null 2>&1; exit 1; }
    case "$*" in *"stat -c %s"*) cat "/tmp/t40/landed/$(key "$last")" 2>/dev/null || exit 1;;
                 *boot_id*) echo 00000000-0000-4000-8000-000000000001;;
                 *"systemctl reboot"*) touch /tmp/t40/rebooted;;   # accepted — and the guest never returns
                 *recover-in-vm*) echo "==== IN-VM RESULT: 12 PASS / 0 FAIL ====";; esac
    exit 0;;
  stop|delete) exit 0;;
esac
exit 0
FAKE
mkdir -p /tmp/t40/landed; chmod +x /tmp/t40/bin/*
start40=$(date +%s)
out40="$(env TIMECRATE_USER=root TIMECRATE_CONF=/tmp/t40/conf \
  TIMECRATE_RCLONE_CONF=/tmp/t40/rclone.conf PATH=/tmp/t40/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  TIMECRATE_CAPSTONE_VM=timecrate-capstone-vm TIMECRATE_CAPSTONE_REBOOT_TRIES=2 bash "$CAP" 2>&1 || true)"
el40=$(( $(date +%s) - start40 ))
printf '%s' "$out40" | grep -q 'never answered after its reboot' \
  && ok "a guest that never answers is REPORTED, not waited on forever" \
  || no "the wedged reboot was not reported: $(printf '%s' "$out40" | head -1)"
[ "$el40" -lt 120 ] \
  && ok "and the run terminated on its own (${el40}s), rather than hanging" \
  || no "the run took ${el40}s — the reboot wait is not bounded"
grep -q 'timeout "\$MP_TIMEOUT" multipass' "$CAP" \
  && ok "and every multipass call is timeout-bounded in one place, not per call site" \
  || no "multipass calls are not bounded in mp()"
# The readiness probe must NOT inherit the long mp() bound: 36 iterations x 900s is nine hours,
# which is the original hang with extra steps. The fake above blocks for 300s per probe, so a
# probe using mp() could not have finished inside the elapsed-time assertion.
grep -q 'boot_id(){ mp_probe exec "\$VM"' "$CAP" \
  && ok "and readiness probes use their own short bound, not the 900s launch/restart one" \
  || no "the reboot probe inherits the long mp() timeout — 36 x 900s is a nine-hour wait"
rm -rf /tmp/t40 /root/timecrate-capstone-work.* 2>/dev/null

echo "== T41: the unattended suite has no unbounded external call (v2.10.0) =="
# This script runs while nobody is watching, and every hang it has ever had came from a single
# un-timeout-ed call: an unbounded `multipass restart` (thirty hours), an unbounded teardown, and
# an unbounded `timecrate list` that sat OUTSIDE the deadline budget it was there to serve.
# Rather than re-audit by eye each time, assert the invariant: anything reaching the engine, the
# remote or the hypervisor is wrapped in `timeout`. Comments and the asuser definition are exempt.
SUITE="$REPO/deploy/overnight-suite.sh"
if [ ! -f "$SUITE" ]; then
  no "overnight-suite.sh is not in the repo — it cannot be reviewed or restored if the host dies"
else
  # Reporting lines are exempt too: an operator message naming `multipass list` as the thing to run
  # by hand is not a call this script makes. Without this the check fired on its own failure text,
  # which is a detector that gets louder the better the code gets.
  scan_unbounded(){ grep -nE '"\$TC"|multipass |bash "\$CAPSTONE"' "$1" \
                      | grep -vE '^[0-9]+:[[:space:]]*#' \
                      | grep -vE '^[0-9]+:[[:space:]]*(say|ok|no|skip|echo)[[:space:]]' \
                      | grep -v 'asuser()' \
                      | grep -v 'timeout' || true; }
  unbounded="$(scan_unbounded "$SUITE")"
  [ -z "$unbounded" ] \
    && ok "every engine/remote/hypervisor call in the unattended suite is timeout-bounded" \
    || no "unbounded call(s) in the unattended suite: $(printf '%s' "$unbounded" | head -2 | tr '\n' ' ')"
  # FALSIFICATION: every exemption above is a blind spot until proven narrow. Same detector, run
  # against a file holding one real unbounded call and one message that merely names the command.
  t41="$(mktemp -d)"
  printf 'asuser multipass delete "$vm" --purge\nno "check by hand: multipass list"\n' > "$t41/fake.sh"
  [ "$(scan_unbounded "$t41/fake.sh" | grep -c .)" = 1 ] \
    && ok "and the detector still catches a real unbounded call while ignoring message text" \
    || no "the exemptions blinded the unbounded-call detector"
  rm -rf "$t41"
  # ...and the bounds must derive from the deadline, not be fixed constants that can outlive it.
  grep -q 'budget 3600' "$SUITE" \
    && ok "and the long tests draw their timeout from the remaining deadline budget" \
    || no "test timeouts are fixed constants, so a test can still outrun the deadline"
fi

echo "== T42: an incomplete kit pages instead of uploading quietly (v2.10.0) =="
# Every write in generate_manifests is best-effort, so a failed command and a box that genuinely
# has none of that thing produce the identical empty file. Nothing asserted the result, so
# thirteen kits shipped without dpkg-foreign-architectures.txt and each would have restored a
# machine with ZERO packages. The gap was invisible for weeks because the backup itself was, by
# its own definition, a complete success: it encrypted, uploaded and hash-verified.
TCBIN="$REPO/timecrate"
grep -q 'kit is INCOMPLETE' "$TCBIN" \
  && ok "backup asserts the manifest set a restore actually needs" \
  || no "nothing checks kit completeness — an incomplete kit still reports success"
# It must page, not abort: the files are the irreplaceable half, and a night with no package list
# beats no night at all. REMOTE-ALERT is the marker backup-and-alert.sh escalates as critical.
grep -q 'REMOTE-ALERT: kit is INCOMPLETE' "$TCBIN" \
  && ok "and it pages via REMOTE-ALERT rather than aborting the backup" \
  || no "kit-completeness failure does not reach the alert path"
# Manifests that are legitimately empty on a healthy box must be checked for ABSENCE, not size,
# or every machine without a foreign architecture would page every single night.
grep -q '\[ -f "\$man/\$m" \]' "$TCBIN" \
  && ok "and legitimately-empty manifests are checked for absence, not emptiness" \
  || no "an empty-but-valid manifest would page nightly on a healthy box"

echo "== T43: a failed hypervisor query is never read as 'the VM is gone' (v2.10.0) =="
# The capstone VM holds a copy of the ESCROWED SECRET KEY, so cleanup reporting success is a
# security claim, not a status line. The version this replaces piped `multipass list` straight into
# `grep -qx`, which returns nonzero both when the VM is absent and when the daemon never answered —
# and the daemon wedge this same MR self-heals from is exactly when it does not answer. So the one
# scenario the code was written for was the scenario that silently certified an undeleted VM.
#
# Behavioural, not grep: the functions are pulled out of the shipped script and run against a stub.
CAP="$REPO/deploy/capstone-and-alert.sh"
# No EXIT trap here: T33 already owns one that deletes the test user it created, and a second
# `trap ... EXIT` REPLACES it rather than adding to it — which would strand that account.
t43=$(mktemp -d)
sed -n '/^vm_names(){/,/^}/p;/^vm_exists(){/,/^}/p;/^purge_vm(){/,/^}/p' "$CAP" > "$t43/fns.sh"
grep -qc 'vm_names' "$t43/fns.sh" || no "could not extract the VM helpers from the capstone"
# $MPMODE drives the stub: ok=one instance, empty=host with no instances, fail=daemon not answering.
cat > "$t43/harness.sh" <<'H'
VM=timecrate-capstone-vm
mp_probe(){ case "$MPMODE" in
    ok)    printf 'Name,State,IPv4,IPv6,Release,AllIPv4\ntimecrate-capstone-vm,Running,192.0.2.5,,24.04,\n'; return 0 ;;
    empty) printf 'Name,State,IPv4,IPv6,Release,AllIPv4\n'; return 0 ;;
    fail)  return 124 ;;                       # timeout: no output, nonzero — a wedged daemon
    quiet) return 0 ;;                         # answered 0 but printed nothing: still not an answer
  esac; }
mp_tear(){ return 0; }
sleep(){ :; }
H
# Appended rather than substituted into the heredoc: `sed -i` takes a mandatory argument on BSD
# and none on GNU, so an in-place edit here would work in CI and break on a macOS dev box.
printf '. %s\n' "$t43/fns.sh" >> "$t43/harness.sh"
t43rc(){ MPMODE="$1" bash -c ". $t43/harness.sh; $2; echo \$?" 2>/dev/null | tail -1; }
[ "$(t43rc ok    'vm_exists')" = 0 ] && ok "vm_exists reports PRESENT when the VM is listed" \
                                     || no "vm_exists did not detect a listed VM"
[ "$(t43rc empty 'vm_exists')" = 1 ] && ok "and CONFIRMED ABSENT on a host that answered with no instances" \
                                     || no "an empty-but-successful list was not read as confirmed absence"
# The two that matter: a query that could not complete must be its own answer, not "absent".
[ "$(t43rc fail  'vm_exists')" = 2 ] && ok "and UNKNOWN (not absent) when the daemon does not answer" \
                                     || no "a failed hypervisor query is still read as 'the VM is gone'"
[ "$(t43rc quiet 'vm_exists')" = 2 ] && ok "and UNKNOWN when the query exits 0 but returns no header" \
                                     || no "a headerless success is read as an answer"
# ...and cleanup must not certify key removal it could not verify.
[ "$(t43rc fail 'purge_vm')" != 0 ] && ok "purge_vm refuses to report success it cannot verify" \
                                    || no "purge_vm reported the key-bearing VM destroyed without confirming it"
[ "$(t43rc empty 'purge_vm')" = 0 ] && ok "and still succeeds on confirmed absence" \
                                    || no "purge_vm fails even when absence is confirmed"
# FALSIFICATION: restore the old one-line implementation and prove these checks catch it. An
# assertion never seen to fail is not a check — six vacuous ones were found this way earlier.
printf 'vm_exists(){ mp_probe list --format csv 2>/dev/null | cut -d, -f1 | grep -qx "$VM"; }\n' >> "$t43/fns.sh"
[ "$(t43rc fail 'vm_exists')" = 2 ] \
  && no "T43 is vacuous: the old pipeline implementation also passes" \
  || ok "and the check fails against the old implementation (proven, not assumed)"

echo "== T44: a manifest generator that fails leaves no file to mistake for output (v2.10.0) =="
# `cmd > file` creates the file before cmd runs, so T42's -f completeness checks passed on the
# empty file a failed generator left behind — the check and the bug agreed with each other.
t44=$(mktemp -d)
sed -n '/  gen(){ local out=/,/fi; }/p' "$REPO/timecrate" > "$t44/gen.sh"
t44run(){ bash -c ". $t44/gen.sh; $1" >/dev/null 2>&1; }
t44run "gen $t44/good.txt printf 'x\n'"
[ -s "$t44/good.txt" ] && ok "a generator that succeeds leaves its output" || no "gen lost the output of a working generator"
t44run "gen $t44/none.txt true"
[ -f "$t44/none.txt" ] && [ ! -s "$t44/none.txt" ] \
  && ok "and one that succeeds with no output leaves an EMPTY file (a box with none of that thing)" \
  || no "gen cannot express 'this box genuinely has none'"
t44run "gen $t44/bad.txt false"
[ ! -e "$t44/bad.txt" ] \
  && ok "and one that FAILS leaves no file at all, so -f distinguishes broken from empty" \
  || no "a failed generator still leaves a file that passes the completeness check"
[ ! -e "$t44/bad.txt.part" ] && ok "and the partial file is cleaned up" || no "gen left a .part file behind"
# FALSIFICATION: the plain redirect this replaced must fail the check above.
t44run "false > $t44/old.txt 2>/dev/null || true"
[ ! -e "$t44/old.txt" ] \
  && no "T44 is vacuous: the old redirect form also leaves no file" \
  || ok "and the check fails against the old redirect form (proven, not assumed)"
rm -rf "$t44"

echo "== T45: a capstone failure can still send its alert (v2.10.0) =="
# The script runs `set -u`, so a variable the alert block expands but that is assigned only on ONE
# failure path takes the whole alert down on every other one. That is how INFRA shipped: set only
# when the VM launch failed, expanded always — so a missing kit, a bad checksum, a failed restore
# or a dead reboot died on "unbound variable" BEFORE the alert, suppressing it exactly when
# recovery is broken. Checked as a CLASS: every variable the alert block reads must have a
# top-level assignment (the block's own locals excepted).
alert_vars(){ sed -n '/^# ---- the alert/,$p' "$1" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' \
                | tr -d '${' | sort -u | grep -vxE 'SEV|TITLE|HERE' || true; }
blockvars="$(alert_vars "$CAP")"
if [ -z "$blockvars" ]; then
  no "cannot locate the capstone alert block"
else
  missing=""
  for v in $blockvars; do grep -qE "^${v}=" "$CAP" || missing="$missing $v"; done
  [ -z "$missing" ] \
    && ok "every variable the alert block reads is initialised at top level ($(echo $blockvars))" \
    || no "alert block reads variable(s) with no unconditional init — set -u will suppress the alert:$missing"
fi
# FALSIFICATION: strip the initialisation and the check must fire.
t45="$(mktemp -d)"; grep -v '^INFRA=0$' "$CAP" > "$t45/cap.sh"
m2=""
for v in $(alert_vars "$t45/cap.sh"); do grep -qE "^${v}=" "$t45/cap.sh" || m2="$m2 $v"; done
[ -n "$m2" ] && ok "and the check fails without the initialisation (proven, not assumed)" \
             || no "T45 is vacuous: it passes even with the initialisation removed"
rm -rf "$t45"

echo "== T46: a timed-out capstone actually stops (v2.10.0) =="
# `trap cleanup EXIT INT TERM` does not stop a script on SIGTERM: bash runs the handler and RESUMES.
# VERIFIED — that shape prints "STILL RUNNING past the timeout" and runs cleanup TWICE. The overnight
# suite wraps each capstone in `timeout "$(budget 3600)"` precisely so a test cannot still hold the
# engine flock when the 03:00 backup wants it, so this defeated the deadline it was enforcing.
# Behavioural: the shipped on_signal is pulled out of the capstone and driven by a real timeout.
t46="$(mktemp -d)"
sed -n '/^on_signal(){/p' "$CAP" > "$t46/sig.sh"
[ -s "$t46/sig.sh" ] || no "the capstone has no on_signal handler — a SIGTERM will not stop it"
mk46(){ { printf 'cleanup(){ echo CLEANUP; }\n'; cat "$1"; printf '%s\n' "$2"; \
          printf 'sleep 5\necho STILL_RUNNING\n'; } > "$t46/run.sh"; }
mk46 "$t46/sig.sh" "trap cleanup EXIT; trap 'on_signal INT' INT; trap 'on_signal TERM' TERM"
out46="$(timeout 1 bash "$t46/run.sh" 2>/dev/null || true)"
printf '%s' "$out46" | grep -q STILL_RUNNING \
  && no "the capstone keeps running after the timeout fires — its deadline is not enforceable" \
  || ok "a SIGTERM from the caller's timeout actually terminates the capstone"
[ "$(printf '%s' "$out46" | grep -c CLEANUP)" = 1 ] \
  && ok "and cleanup runs exactly once (it purges a VM holding the escrowed key)" \
  || no "cleanup ran $(printf '%s' "$out46" | grep -c CLEANUP) times, not once"
# FALSIFICATION: the shape this replaced must fail the check above.
: > "$t46/empty.sh"; mk46 "$t46/empty.sh" "trap cleanup EXIT INT TERM"
timeout 1 bash "$t46/run.sh" 2>/dev/null | grep -q STILL_RUNNING \
  && ok "and the old EXIT-INT-TERM shape fails it (proven, not assumed)" \
  || no "T46 is vacuous: the shape it replaced also passes"
rm -rf "$t46"

echo "== T47: an unverified key-bearing VM is a capstone FAILURE, not a warning (v2.10.0) =="
# The VM holds a copy of the escrowed secret key. Teardown used to live only in the EXIT trap, which
# runs AFTER `exit 0` has already been chosen — so cleanup could discover it was unable to confirm
# the VM was destroyed, write a warning to stderr that changed no status, and the quarterly run
# would still print CAPSTONE PASSED and page nobody.
grep -q '^cleanup$' "$CAP" \
  && ok "teardown runs before the verdict, not only from the EXIT trap" \
  || no "teardown is still only an EXIT-trap afterthought — it cannot affect the result"
grep -q 'PURGE_FAILED' "$CAP" && grep -qE 'PURGE_FAILED" = 0 \]? *\\?$|PURGE_FAILED" = 0 \]' "$CAP" \
  && ok "and a purge it could not confirm is folded into the failure list" \
  || no "a failed purge does not reach the verdict"
# The verdict must be decided AFTER teardown, or folding it in achieves nothing. Compare positions.
t47c=$(grep -n '^cleanup$' "$CAP" | head -1 | cut -d: -f1)
t47v=$(grep -n 'CAPSTONE PASSED' "$CAP" | head -1 | cut -d: -f1)
[ -n "$t47c" ] && [ -n "$t47v" ] && [ "$t47c" -lt "$t47v" ] \
  && ok "and it happens before the success message is printed (line $t47c < $t47v)" \
  || no "teardown runs after the verdict is decided, so its result cannot change it"

echo "== T48: the quarterly capstone bounds its REMOTE calls too (v2.10.0) =="
# The hypervisor was bounded; the remote was not. The quarterly systemd job runs this script
# directly — the overnight suite's budget only covers runs IT starts — and the unit's
# TimeoutStartSec is a kill, not a report: systemd SIGTERMs the script and notify.send() at the
# bottom never runs. A wedged Dropbox therefore produced a failed unit and NO alert.
scan_remote(){ grep -nE '(^|[^_a-z])(rclone|"\$TC") ' "$1" \
                 | grep -vE '^[0-9]+:[[:space:]]*#' \
                 | grep -vE '^[0-9]+:[[:space:]]*(echo|fail)[[:space:]]' \
                 | grep -vE '\[ -[a-zA-Z] ' \
                 | grep -vE 'rem |timeout |RCONF=|rem\(\)' || true; }
unb="$(scan_remote "$CAP")"
[ -z "$unb" ] \
  && ok "every engine and rclone call in the capstone goes through the bounded helper" \
  || no "unbounded remote call(s) in the quarterly capstone: $(printf '%s' "$unb" | head -2 | tr '\n' ' ')"
# FALSIFICATION: the `[ -x ]` exemption must not swallow a real unbounded call.
t48="$(mktemp -d)"
printf 'runuser -u "$TC_USER" -- rclone --config "$RCONF" copyto a b\n[ -x "$TC" ] || fail "nope"\n' > "$t48/f.sh"
[ "$(scan_remote "$t48/f.sh" | grep -c .)" = 1 ] \
  && ok "and the detector still catches a real unbounded remote call (proven, not assumed)" \
  || no "the file-test exemption blinded the remote-call detector"
rm -rf "$t48"
grep -qE '^rem\(\)\{ *asuser timeout' "$CAP" \
  && ok "and the helper bounds by time rather than merely dropping privileges" \
  || no "the remote helper does not apply a timeout"

echo "== T49: the overnight suite only destroys VMs it created (v2.10.0) =="
# timecrate-capstone-vm is the default name of the SEPARATELY scheduled quarterly capstone, and T2/T3
# always override it with timecrate-overnight-*. Deleting it here could therefore only ever destroy a VM
# belonging to a run this suite does not own — mid-drill, while that run holds the escrowed key.
grep -qE '^for vm in tm-overnight[^;]*timecrate-capstone-vm' "$SUITE" \
  && no "overnight teardown still deletes timecrate-capstone-vm, which belongs to the quarterly capstone" \
  || ok "overnight teardown is scoped to the timecrate-overnight-* VMs it creates"
grep -q "grep -E '\^timecrate-overnight-'" "$SUITE" \
  && ok "and its survivor check is scoped the same way, so a live capstone is not reported as a leak" \
  || no "the survivor check still matches VMs this suite did not create"

echo "== T50: 'every kit verified' needs a clean exit AND a complete count (v2.10.0) =="
# T1 treated only rc=124 as failure and accepted the OK marker on any other status, so a run that
# verified some kits, printed its summary and then died on a later remote or integrity error was
# reported as a pass. Behavioural: the shipped verify_verdict is extracted and driven directly.
t50="$(mktemp -d)"
sed -n '/^verify_verdict(){/,/^}/p' "$SUITE" > "$t50/vv.sh"
[ -s "$t50/vv.sh" ] || no "the overnight suite has no extractable verify_verdict"
vv(){ bash -c ". $t50/vv.sh; verify_verdict \"\$1\" \"\$2\"; echo \$?" _ "$1" "$2" 2>/dev/null | tail -1; }
[ "$(vv 0 'VERIFY OK: 15/15 kits')" = 0 ] \
  && ok "a clean run that verified every kit passes" || no "a genuine all-kits pass was rejected"
[ "$(vv 1 'VERIFY OK: 15/15 kits')" = 1 ] \
  && ok "and a NONZERO exit is a failure even with an OK summary already printed" \
  || no "a failed run is reported as a pass whenever the OK summary appears"
[ "$(vv 0 'VERIFY OK: 3/15 kits')" = 1 ] \
  && ok "and a partial count is a failure even on a clean exit" \
  || no "3 of 15 kits verified is being reported as a pass"
[ "$(vv 0 'nothing useful here')" = 1 ] \
  && ok "and a missing summary is a failure, not a pass by default" || no "absent output passed"
# FALSIFICATION: the logic this replaced must accept the case that matters.
printf 'verify_verdict(){ [ "$1" = 124 ] && return 1; printf "%%s" "$2" | grep -qE "VERIFY OK: [0-9]+/[0-9]+ kit"; }\n' > "$t50/vv.sh"
[ "$(vv 1 'VERIFY OK: 15/15 kits')" = 1 ] \
  && no "T50 is vacuous: the old rc-blind logic also fails this case" \
  || ok "and the old rc-blind logic accepts it (proven, not assumed)"
rm -rf "$t50"

echo "== T51: the package carries the recovery drill, and arms the timers (3.0.0) =="
# The package must carry everything the timers run -- engine, helpers, the capstone and the script
# it runs inside the guest -- or "installed from apt" and "can prove this machine is rebuildable"
# are two different things.
RULES="$REPO/debian/rules"
for want in capstone-and-alert.sh overnight-suite.sh recover-in-vm.sh alert.sh; do
  grep -q "$want" "$RULES" \
    && ok "the package installs $want" \
    || no "$want is not installed by the package"
done
grep -q 'deploy/\*.service deploy/\*.timer' "$RULES" \
  && ok "and every unit in deploy/ ships with it" || no "the units are not packaged"
# THE UPGRADE TRAP. A package built with --no-start and without --restart-after-upgrade gets a
# preinst that stops every unit on upgrade and nothing that starts them again: an `apt upgrade`
# that silently ends the nightly backup. tests/upgrade.sh proves the behaviour on a real systemd;
# this pins the one line it depends on.
grep -qE '^[[:space:]]+dh_installsystemd --restart-after-upgrade$' "$RULES" \
  && ok "units are started on install and restarted, never stopped, across an upgrade" \
  || no "dh_installsystemd is not --restart-after-upgrade — an upgrade could disarm the backup"
grep -qE 'dh_installsystemd.*--no-(enable|start)' "$RULES" \
  && no "a unit is installed disabled or not started — the timers must be armed on install" \
  || ok "and nothing is installed disabled or left stopped"
# A machine without multipass cannot run the capstone at all: it must be skipped there, not fail
# every quarter -- and a condition in the wrong section is ignored the same way OnFailure is.
grep -q '^ConditionPathExists=|/snap/bin/multipass' "$REPO/deploy/timecrate-capstone.service" \
  && [ "$(awk '/^\[/{sec=$0} /^ConditionPathExists=/{print sec}' "$REPO/deploy/timecrate-capstone.service" | sort -u)" = "[Unit]" ] \
  && ok "the capstone is skipped, not failed, where multipass is absent" \
  || no "the capstone would fail every quarter on a machine without multipass"
# recover-in-vm.sh must land where the capstone looks for it, or packaging it achieves nothing.
grep -q 'usr/share/timecrate/recover-in-vm.sh' "$RULES" \
  && grep -q '/usr/share/timecrate/recover-in-vm.sh' "$CAP" \
  && ok "and recover-in-vm.sh lands on the capstone's search path" \
  || no "recover-in-vm.sh is packaged somewhere the capstone does not look"
grep -q '^ExecStart=/usr/libexec/timecrate/capstone-and-alert.sh' "$REPO/deploy/timecrate-capstone.service" \
  && ok "the capstone unit names the packaged path" || no "the capstone unit names another path"
grep -q '/usr/libexec/timecrate/capstone-and-alert.sh' "$SUITE" \
  && ok "and the overnight suite finds the packaged capstone" \
  || no "the overnight suite does not know the packaged capstone path"

echo "== T53: the shipped scope covers what a rebuild actually needs (v2.12.0) =="
# Measured on a real host 2026-08-04: the shipped list captured 5,844 files and 11.7 MB/night while
# omitting /usr/local entirely — software that comes from no package, so the dpkg replay cannot
# recreate it. A restore would have produced a machine missing 58M of its own binaries and every
# desktop setting outside a hand-picked list of thirteen .config entries.
# The tilde is LITERAL in these lists: the engine expands "~/" itself against the configured
# user's home (build_include), so the file contains the character, not a path. Built from a
# variable so no quoted "~/..." appears — shellcheck rightly flags those, and silencing it
# line-by-line would leave the next author guessing which ones were deliberate.
TIL="~"
INCF="$REPO/timecrate.include"
EXCF="$REPO/timecrate.exclude"
for want in usr/local var/lib/AccountsService "$TIL/.config" "$TIL/.secrets" "$TIL/.pki"; do
  grep -qxF "$want" "$INCF" \
    && ok "the shipped include covers $want" \
    || no "$want is absent from the shipped include — a rebuilt box would not have it"
done
# ...and the giants it pulls in must be excluded, or every host ships browser profiles nightly.
for want in "$TIL/.config/google-chrome" "$TIL/.config/BraveSoftware"; do
  grep -qxF "$want" "$EXCF" \
    && ok "and $want is excluded" \
    || no "$want would be backed up nightly — kits balloon by gigabytes"
done
# The exclusion must not swallow the settings beside it. Code/User is included explicitly and
# tar --exclude beats --files-from, so excluding "$TIL/.config/Code" wholesale would silently
# drop it — verified on a real kit: Code/User is PRESENT with the cache-scoped exclusion.
# Bare cache names would apply to the WHOLE archive. `Cache` unanchored drops any directory of
# that name under /usr/local, /etc or a personal tree — silently, because the backup still
# succeeds. Every cache exclusion must therefore be path-qualified.
bare=""
for pat in Cache CachedData "Code Cache" GPUCache blob_storage Crashpad "Service Worker" CacheStorage WebStorage; do
  grep -qxF "$pat" "$EXCF" && bare="$bare $pat"
done
[ -z "$bare" ] \
  && ok "every cache exclusion is path-qualified, so none can drop data from another tree" \
  || no "unanchored cache pattern(s) apply to the whole archive:$bare"
grep -qxF "$TIL/.config/Code" "$EXCF" \
  && no "excluding the Code tree wholesale also drops Code/User — VS Code settings would be lost" \
  || ok "and the Code exclusion is cache-scoped, so Code/User survives"

echo "== T54: coverage reports what is SKIPPED, not just what is kept (v2.13.0) =="
# The include list is an allowlist, so anything unnamed is absent from every kit and nothing said
# so. That is how /usr/local — software no package can recreate — stayed missing while the backup
# reported success nightly. This command is the standing answer; it must classify against the same
# build_include/build_exclude the backup feeds to tar, or the view and the kit drift apart.
t54="$(mktemp -d)"
mkdir -p "$t54/root/etc" "$t54/root/kept/sub" "$t54/root/dropped" "$t54/root/nobody" "$t54/root/half/in" "$t54/root/half/out"
printf 'x\n' > "$t54/root/kept/sub/f"; printf 'x\n' > "$t54/root/dropped/f"
printf 'x\n' > "$t54/root/nobody/f"; printf 'x\n' > "$t54/root/half/in/f"; printf 'x\n' > "$t54/root/half/out/f"
printf '%s\n' "${t54#/}/root/kept" "${t54#/}/root/half/in" > "$t54/inc"
printf '%s\n' "${t54#/}/root/dropped" > "$t54/exc"
cov(){ env TIMECRATE_INCLUDE="$t54/inc" TIMECRATE_EXCLUDE="$t54/exc" TIMECRATE_USER="$(id -un)" \
         "$TCBIN" coverage --root "$t54/root" --no-size 2>/dev/null; }
state(){ cov | awk -v p="${t54#/}/root/$1" '$3==p{print $1}'; }
[ "$(state kept)"    = included ] && ok "a listed path reports included"       || no "listed path not reported included (got '$(state kept)')"
[ "$(state dropped)" = excluded ] && ok "and an excluded path names its rule"  || no "excluded path misreported (got '$(state dropped)')"
[ "$(state half)"    = partial  ] && ok "and a tree with only part included reports partial" || no "partial coverage misreported (got '$(state half)')"
# The one that matters: a directory nothing mentions must be reported, loudly, not omitted.
[ "$(state nobody)"  = UNLISTED ] && ok "and a path NOTHING covers reports UNLISTED" \
                                  || no "an uncovered directory is invisible — the whole point of this command"
# Glob and bare-component rules must classify the way tar actually applies them, or the report
# and the kit disagree — which is the single thing this command promises cannot happen.
mkdir -p "$t54/root/globby" "$t54/root/deep/node_modules"
printf 'x\n' > "$t54/root/globby/a.pyc"; printf 'x\n' > "$t54/root/deep/node_modules/f"
printf '%s\n' "*.pyc" "node_modules" "${t54#/}/root/glob*" >> "$t54/exc"
[ "$(state globby)" = excluded ] \
  && ok "and a wildcard exclude rule is honoured" || no "wildcard exclude rules are not applied (got '$(state globby)')"
# An unreadable directory must not end the report early: silence would read as "nothing left".
mkdir -p "$t54/root/locked/inner"; chmod 000 "$t54/root/locked" 2>/dev/null || true
lines_now="$(cov | grep -c . || true)"
chmod 755 "$t54/root/locked" 2>/dev/null || true
[ "${lines_now:-0}" -ge 5 ] \
  && ok "and an unreadable directory does not truncate the report" \
  || no "the report stopped early on an unreadable directory — it would look like nothing is uncovered"
# FALSIFICATION: add the uncovered path to the include list and the report must change.
printf '%s\n' "${t54#/}/root/nobody" >> "$t54/inc"
[ "$(state nobody)" = included ] \
  && ok "and the classification tracks the list rather than being hardcoded (proven)" \
  || no "T54 is vacuous: the state did not change after the path was included"
rm -rf "$t54"

echo "== T56: a VM that never existed raises no key-exposure alarm (v2.14.1) =="
# OBSERVED on a real run 2026-08-05: multipass never created an instance, none existed, and the
# capstone still reported "could not confirm the recovery VM was destroyed — it holds a copy of the
# escrowed secret key". A wedged daemon answers "unknown" rather than "absent", and cleanup could
# not tell "I could not check" from "there is something to worry about". A false key-exposure alarm
# is worse than none: it teaches the operator to discount the real one.
grep -q 'VM_EVER_EXISTED=1' "$CAP" && grep -q 'VM_EVER_EXISTED" = 0' "$CAP" \
  && ok "cleanup distinguishes 'never created' from 'could not verify'" \
  || no "a run that never created a VM can still raise a key-exposure alarm"
# The flag must be latched where existence is CONFIRMED, not where a launch was merely attempted.
awk '/^vm_exists\(\)/,/^}/' "$CAP" | grep -q 'VM_EVER_EXISTED=1' \
  && ok "and it latches only on confirmed presence" \
  || no "the existence flag is set somewhere other than a confirmed sighting"
# After a daemon restart, readiness must be OBSERVED, not slept through.
awk '/looks wedged/,/mp launch/' "$CAP" | grep -q 'vm_names >/dev/null' \
  && ok "and a restarted daemon is waited for until it answers, not for a fixed interval" \
  || no "the retry still sleeps a guess after restarting the daemon"

echo "== T57: the changelog is strictly descending and matches the engine (v2.13.2) =="
# A rebase that renumbered a release left an ORPHAN entry behind: master carried a 2.14.0 section
# describing post-quantum work whose code was on an unmerged branch, sitting BELOW a 2.13.1 entry.
# Two failures in one — the changelog advertised a release that did not exist, and the ordering was
# invalid. It survived my own check because I verified the TOP version only, which was correct.
CHLOG="$REPO/debian/changelog"
vers="$(grep -oE '^timecrate \(([0-9.]+)\)' "$CHLOG" | sed -E 's/.*\(([0-9.]+)\)/\1/')"
bad=""
prev=""
while read -r v; do
  [ -n "$v" ] || continue
  if [ -n "$prev" ] && ! dpkg --compare-versions "$prev" gt "$v" 2>/dev/null; then
    bad="$bad $prev<=$v"
  fi
  prev="$v"
done <<< "$vers"
[ -z "$bad" ] \
  && ok "every changelog entry is newer than the one below it" \
  || no "changelog versions are not strictly descending:$bad"
# ...and the engine must claim the version the package is built as, or `publish_apt` rejects the tag.
evers="$(grep -m1 '^VERSION=' "$REPO/timecrate" | cut -d'"' -f2)"
tvers="$(printf '%s\n' "$vers" | head -1)"
[ "$evers" = "$tvers" ] \
  && ok "and the engine version matches the top changelog entry ($evers)" \
  || no "engine says $evers, changelog says $tvers — the tag pipeline asserts these agree"
# The man pages print the version in their footer; nothing in the release pipeline reads them.
for man57 in "$REPO"/docs/*.1; do
  grep -qE "^\.TH .* \"timecrate $evers\" " "$man57" \
    && ok "$(basename "$man57") names $evers in its .TH line" \
    || no "$(basename "$man57") .TH does not name timecrate $evers: $(head -1 "$man57")"
done

echo "== T58: a kit contains the tool that opens it (v2.14.0) =="
# Once the tool is installed from a package it lives in /usr, which nothing else in the list
# names; MEASURED on the first host converted to the package, all three paths were ABSENT from the
# newest kit. A restored machine would have come up without the tool, and opening a kit would have
# needed the package archive and a network -- part of what the kit exists to survive losing.
for want in usr/bin/timecrate usr/libexec/timecrate usr/share/timecrate; do
  grep -qxF "$want" "$INCF" \
    && ok "the kit carries $want" \
    || no "$want is not in the kit — a restored machine cannot open its own backups without apt"
done

echo "== T59: every unit that declares OnFailure puts it where systemd reads it (v2.14.0) =="
# OnFailure is a [Unit] directive. In [Service] systemd silently ignores it — no warning, no error,
# the unit still starts and still fails, and simply pages nobody. The capstone shipped that way:
# the one job whose entire purpose is to tell you recovery is broken had no alert path at all.
for u in "$REPO"/deploy/timecrate-*.service; do
  grep -q '^OnFailure=' "$u" || continue
  sect="$(awk '/^\[/{s=$0} /^OnFailure=/{print s; exit}' "$u")"
  [ "$sect" = "[Unit]" ] \
    && ok "$(basename "$u"): OnFailure is in [Unit]" \
    || no "$(basename "$u"): OnFailure is in $sect — systemd ignores it and the unit pages nobody"
done

echo "== T60: kits written before 3.0.0 are one series with the new ones (3.0.0) =="
# Releases before 3.0.0 named kits timemachine-<ts>. A remote holding them is the common case on
# an upgraded machine, and every command has to treat them as the same series: listed, verified,
# restored, drilled and pruned together, ordered by timestamp. By NAME the two prefixes sort apart
# ("timecrate" < "timemachine"), and a retention that sorted by name would keep the old kits as
# the "newest" and delete the new ones -- the failure this group exists to rule out.
rm -rf /tmp/fr60 /tmp/t60; mkdir -p /tmp/fr60/kits /tmp/t60/src/sub /tmp/t60/state
printf 'legacy-content\n' > /tmp/t60/src/a; printf 'deeper\n' > /tmp/t60/src/sub/b
# A directory-backed rclone: lsf with --include (brace alternation too), --format and --separator,
# copyto in both directions, delete. <name>:<path> maps to /tmp/fr60/<path>. Like the real one run
# without a config file, it writes a NOTICE to standard error every time -- which must never be
# read as a kit.
cat > /usr/local/bin/rclone <<'FAKE'
#!/usr/bin/env python3
import fnmatch, os, re, shutil, sys
print('2026/01/01 00:00:00 NOTICE: Config file "/nowhere/rclone.conf" not found - using defaults', file=sys.stderr)
args, inc, fmt, sep = [], [], "", ";"
it = iter(sys.argv[1:])
for a in it:
    if a == "--config": next(it, None)
    elif a == "--include": inc.append(next(it, ""))
    elif a == "--format": fmt = next(it, "")
    elif a == "--separator": sep = next(it, ";")
    else: args.append(a)
def local(p):
    return os.path.join("/tmp/fr60", p.split(":", 1)[1]) if ":" in p else p
def expand(pat):
    m = re.match(r"\{([^}]*)\}(.*)", pat)
    return [a + m.group(2) for a in m.group(1).split(",")] if m else [pat]
cmd = args[0] if args else ""
if cmd == "lsf":
    d = local(args[1])
    if not os.path.isdir(d):
        print("directory not found", file=sys.stderr); sys.exit(3)
    for n in sorted(os.listdir(d)):
        if inc and not any(fnmatch.fnmatchcase(n, x) for p in inc for x in expand(p)):
            continue
        f = os.path.join(d, n)
        cols = {"s": str(os.path.getsize(f)), "t": "2026-01-01 00:00:00", "p": n}
        print(sep.join(cols[c] for c in fmt) if fmt else n)
elif cmd == "copyto":
    src, dst = local(args[1]), local(args[2])
    if not os.path.isfile(src): sys.exit(1)
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True); shutil.copyfile(src, dst)
elif cmd in ("delete", "deletefile"):
    try: os.remove(local(args[1]))
    except FileNotFoundError: pass
elif cmd == "about":
    sys.exit(1)
FAKE
chmod +x /usr/local/bin/rclone
EFPR60=$(cat /tmp/tm/conf/recipients.txt); SFPR60=$(cat /tmp/tm/conf/signing.txt)
LK="$REPO/tests/legacy-kit.sh"
for ts in 2025-11-02_03-00-00 2025-12-01_03-00-00 2026-01-01_03-00-00 \
          2026-09-28_03-00-00 2026-09-29_03-00-00 2026-09-30_03-00-00; do
  bash "$LK" /tmp/fr60/kits "$ts" /tmp/tm/conf/gnupg "$EFPR60" "$SFPR60" tmp/t60/src >/dev/null 2>/tmp/t60/lk.err \
    || no "could not write a pre-3.0.0 kit: $(tail -1 /tmp/t60/lk.err)"
done
export TIMECRATE_REMOTE=fake:kits TIMECRATE_STATE=/tmp/t60/state
# what a machine migrated from 2.14.0 carries: its anchor names the newest OLD kit
printf 'timemachine-2026-09-30_03-00-00.tar.zst.gpg 6\n' > /tmp/t60/state/expected
printf 'tmp/t60/src\n' > /tmp/t60/inc; printf '.git\n' > /tmp/t60/exc

# a) listed, oldest first
l60="$("$TC" list 2>/dev/null)"
[ "$(printf '%s\n' "$l60" | grep -c '^timemachine-')" = 6 ] && ok "list shows the six pre-3.0.0 kits" \
  || no "list did not show the old kits: $l60"
[ "$(printf '%s\n' "$l60" | grep -c .)" = 6 ] && ! "$TC" list --long 2>/dev/null | grep -q NOTICE \
  && ok "and nothing rclone says on standard error is taken for a kit" \
  || no "rclone's notice was listed as a kit: $(printf '%s' "$l60" | grep -v '^time' | head -1)"
# b) a backup against that remote: the anchor check must read the old anchor correctly
if TIMECRATE_INCLUDE=/tmp/t60/inc TIMECRATE_EXCLUDE=/tmp/t60/exc "$TC" backup --force >/tmp/t60/b1.out 2>&1; then
  ok "a backup uploads beside the pre-3.0.0 kits"
  grep -q 'REMOTE-ALERT' /tmp/t60/b1.out && no "an anchor naming an old kit raised a false alarm: $(grep REMOTE-ALERT /tmp/t60/b1.out)" \
    || ok "an anchor written before 3.0.0 reads as the same series (no false ROLLBACK or DELETION)"
else no "backup against a remote of old kits failed: $(tail -3 /tmp/t60/b1.out)"; fi
new60="$(find /tmp/fr60/kits -maxdepth 1 -name 'timecrate-*.tar.zst.gpg' -printf '%f\n' | sort | tail -1)"
l60="$("$TC" list 2>/dev/null)"
[ -n "$new60" ] && [ "$(printf '%s\n' "$l60" | tail -1)" = "$new60" ] \
  && ok "the new kit lists as the NEWEST, although its name sorts before every old one" \
  || no "list order is by name, not by time: $(printf '%s' "$l60" | tr '\n' ' ')"
[ "$("$TC" list --long 2>/dev/null | tail -1 | cut -f3)" = "$new60" ] \
  && ok "and list --long agrees" || no "list --long orders by name"
[ "$(awk '{print $1}' /tmp/t60/state/expected)" = "$new60" ] && [ "$(awk '{print $2}' /tmp/t60/state/expected)" = 7 ] \
  && ok "the anchor now records the new kit and counts both series (7)" \
  || no "anchor after the backup: $(cat /tmp/t60/state/expected)"
"$TC" status --json 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["cloud_kits"]=="7" else 1)' \
  && ok "status counts both series" || no "status did not count the old kits"
# c) every kit verifies
"$TC" verify --all >/tmp/t60/v.out 2>&1 && grep -q 'VERIFY OK: 7/7' /tmp/t60/v.out \
  && ok "verify --all authenticates and decrypts old and new kits alike (7/7)" \
  || no "verify --all: $(tail -2 /tmp/t60/v.out)"
"$TC" verify --remote 2025-12-01_03-00-00 >/tmp/t60/v2.out 2>&1 \
  && ok "verify --remote finds an old kit by its bare timestamp" || no "verify by timestamp: $(tail -1 /tmp/t60/v2.out)"
# d) restore: an old kit is OLDER than the anchor, so it needs --force -- by timestamp, not by name
"$TC" restore 2025-12-01_03-00-00 >/tmp/t60/r1.out 2>&1 \
  && no "an old kit restored without --force past a newer anchor" \
  || { grep -q 'ROLLBACK GUARD' /tmp/t60/r1.out && ok "the rollback guard compares old and new kits by timestamp" \
       || no "restore of an old kit failed for the wrong reason: $(tail -1 /tmp/t60/r1.out)"; }
rm -rf /tmp/tm/staging/restored-*
if "$TC" restore timemachine-2025-12-01_03-00-00.tar.zst.gpg --force >/tmp/t60/r2.out 2>&1; then
  ext="$(find /tmp/tm/staging -path '*extracted/tmp/t60/src/sub/b' 2>/dev/null | head -1)"
  [ -n "$ext" ] && diff -r /tmp/t60/src "${ext%/sub/b}" >/dev/null \
    && ok "an old kit restores by its full name, content intact" || no "restored content differs from the source"
  find /tmp/tm/staging -path '*extracted/TIMEMACHINE-MANIFESTS/BACKUP-INFO.txt' | grep -q . \
    && ok "and its TIMEMACHINE-MANIFESTS came with it" || no "the old manifests directory is missing"
else no "restore of an old kit failed: $(tail -2 /tmp/t60/r2.out)"; fi
rm -rf /tmp/tm/staging/restored-*
# e) --to-root on an old kit puts the files back and keeps its manifests off /
rm -rf /tmp/t60/src.saved; cp -a /tmp/t60/src /tmp/t60/src.saved; rm -rf /tmp/t60/src
if "$TC" restore 2026-09-29_03-00-00 --to-root --force >/tmp/t60/r3.out 2>&1; then
  diff -r /tmp/t60/src.saved /tmp/t60/src >/dev/null && ok "restore --to-root of an old kit puts its files back" \
    || no "--to-root of an old kit did not restore the files"
  [ ! -e /TIMEMACHINE-MANIFESTS ] && ok "and an old kit's manifests are kept off /" \
    || { no "/TIMEMACHINE-MANIFESTS was extracted onto the root filesystem"; rm -rf /TIMEMACHINE-MANIFESTS; }
else no "restore --to-root of an old kit failed: $(tail -2 /tmp/t60/r3.out)"; cp -a /tmp/t60/src.saved /tmp/t60/src; fi
# f) the drill takes the newest of either series and sweeps them all
if "$TC" recovery-drill >/tmp/t60/d.out 2>&1; then
  ts60="${new60#timecrate-}"; ts60="${ts60%.tar.zst.gpg}"
  grep -q "fetching kit $ts60 " /tmp/t60/d.out \
    && ok "the drill decrypts the newest kit, of either series" || no "the drill fetched another kit: $(grep fetching /tmp/t60/d.out)"
  grep -q 'remote sweep: 7 kits, 7 signature-verified' /tmp/t60/d.out \
    && ok "and its sweep authenticates every old kit too" || no "sweep line: $(grep 'remote sweep' /tmp/t60/d.out)"
else no "the drill failed on a mixed remote: $(tail -3 /tmp/t60/d.out)"; fi
printf 'timemachine-2026-09-30_03-00-00.tar.zst.gpg 6\n' > /tmp/t60/state/expected
"$TC" recovery-drill >/tmp/t60/d2.out 2>&1 \
  && ok "a drill against an anchor written before 3.0.0 passes (no false ROLLBACK or DELETION)" \
  || no "the old anchor failed the drill: $(grep -E 'ROLLBACK|DELETION' /tmp/t60/d2.out | head -1)"
# g) init must refuse a remote that holds only old kits: a new key would orphan all of them
mkdir -p /tmp/t60/only-old && cp /tmp/fr60/kits/timemachine-2025-11-02_03-00-00.tar.zst.gpg /tmp/t60/only-old/
TIMECRATE_REMOTE=fake:../t60/only-old TIMECRATE_CONF=/tmp/t60/newconf TIMECRATE_STATE=/tmp/t60/newstate \
  "$TC" init >/tmp/t60/i.out 2>&1 \
  && no "init MINTED A KEY on a remote holding only pre-3.0.0 kits (they are now unreadable)" \
  || { grep -q 'import-key' /tmp/t60/i.out && ok "init refuses a remote that holds only old kits" \
       || no "init failed for the wrong reason: $(tail -1 /tmp/t60/i.out)"; }
# h) retention: one series, by timestamp. The oracle is an independent GFS over the listing taken
#    just before the prune, so the check holds on whatever date the suite runs.
find /tmp/fr60/kits -maxdepth 1 -name '*.tar.zst.gpg' -printf '%f\n' > /tmp/t60/before
if TIMECRATE_KEEP=2 TIMECRATE_KEEP_MONTHLY=2 TIMECRATE_KEEP_YEARLY=1 \
   TIMECRATE_INCLUDE=/tmp/t60/inc TIMECRATE_EXCLUDE=/tmp/t60/exc "$TC" backup --force >/tmp/t60/b2.out 2>&1; then
  find /tmp/fr60/kits -maxdepth 1 -name '*.tar.zst.gpg' -printf '%f\n' | sort > /tmp/t60/after
  new2="$(comm -13 <(sort /tmp/t60/before) /tmp/t60/after)"
  python3 - /tmp/t60/before "$new2" 2 2 1 > /tmp/t60/expect <<'ORACLE'
import sys
names = [l.strip() for l in open(sys.argv[1]) if l.strip()] + [sys.argv[2]]
daily, mon, yr = (int(x) for x in sys.argv[3:6])
names.sort(key=lambda n: n.split("-", 1)[1])        # the timestamp after the prefix
keep = set(names[-daily:])
months, years = {}, {}
for n in names:                                      # oldest first: first seen = first of period
    ts = n.split("-", 1)[1]
    months.setdefault(ts[:7], n); years.setdefault(ts[:4], n)
keep |= set(list(months.values())[-mon:]) | set(list(years.values())[-yr:])
print("\n".join(sorted(keep)))
ORACLE
  diff /tmp/t60/expect /tmp/t60/after >/tmp/t60/diff \
    && ok "retention keeps exactly the one-series GFS set ($(grep -c . /tmp/t60/after) kits, old and new)" \
    || no "retention kept the wrong set: $(tr '\n' ' ' < /tmp/t60/diff)"
  grep -qx "$new2" /tmp/t60/after && ok "and the kit just uploaded survives it" || no "the new kit was pruned"
  orphans=""
  for f in /tmp/fr60/kits/*.sha256 /tmp/fr60/kits/*.meta.json; do
    k="${f%.sha256}"; k="${k%.meta.json}"; [ "$k" = "${f%.meta.json}" ] && k="$k.tar.zst.gpg"
    [ -e "$k" ] || orphans="$orphans $(basename "$f")"
  done
  [ -z "$orphans" ] && ok "a pruned kit takes its own sidecars with it, whichever name it carries" \
    || no "sidecars left behind:$orphans"
else no "the pruning backup failed: $(tail -3 /tmp/t60/b2.out)"; fi
# i) the pre-3.0.0 key directory never rides in a kit (a migrated machine keeps it for a while)
mkdir -p /root/.config/time-machine && printf 'secret\n' > /root/.config/time-machine/timemachine-secret.asc
printf 'root/.config\ntmp/t60/src\n' > /tmp/t60/inc2
if TIMECRATE_INCLUDE=/tmp/t60/inc2 TIMECRATE_EXCLUDE=/tmp/t60/exc "$TC" backup --no-upload --force >/tmp/t60/b3.out 2>&1; then
  k3="$(ls -t /tmp/tm/staging/timecrate-*.tar.zst.gpg | head -1)"
  GNUPGHOME=/tmp/tm/conf/gnupg gpg --batch --no-tty -d "$k3" 2>/dev/null | zstd -dc --long=27 2>/dev/null | tar -tf - > /tmp/t60/b3.list 2>/dev/null
  [ -s /tmp/t60/b3.list ] || no "T60i kit did not list (harness broken)"
  grep -q 'root/.config/time-machine' /tmp/t60/b3.list \
    && no "the pre-3.0.0 key directory is INSIDE the kit" || ok "the pre-3.0.0 key directory is excluded by derivation"
  rm -f "$k3" "$k3.sha256" "${k3%.tar.zst.gpg}.meta.json"
else no "T60i backup failed: $(tail -2 /tmp/t60/b3.out)"; fi
rm -rf /root/.config/time-machine
unset TIMECRATE_REMOTE
export TIMECRATE_STATE=/tmp/tm/state

echo "== T61: include lines may be globs, and ~/ entries are not reported missing (3.0.0) =="
# The engine used to add a handful of patterns under the home at run time. They are gone; a line
# of the list is a glob instead, so any machine can name its own. And the missing-entry check
# used to test "~/x" raw, so every ~/ line warned nightly and the one real warning drowned.
rm -rf /root/t61; mkdir -p /root/t61/dir "/root/t61/lit[1]"
: > /root/t61/one.env; : > /root/t61/two.env; : > /root/t61/keep.txt
TIL="~"
printf '%s\n' "$TIL/t61/*.env" "$TIL/t61/lit[1]" "$TIL/t61/none-*.x" "$TIL/t61/dir" "tmp/t61-missing" > /tmp/t61.inc
sed -n '/^build_include()/,/^}/p' "$TC" > /tmp/t61.fn
got61="$(bash -c ". /tmp/t61.fn; INCLUDE_FILE=/tmp/t61.inc USER_HOME=/root build_include")"
printf '%s\n' "$got61" | grep -qx 'root/t61/one.env' && printf '%s\n' "$got61" | grep -qx 'root/t61/two.env' \
  && ok "a glob line expands to every match" || no "glob not expanded: $(printf '%s' "$got61" | tr '\n' ' ')"
printf '%s\n' "$got61" | grep -q 'keep.txt' && no "a glob matched a file it does not name" || ok "and only to its matches"
printf '%s\n' "$got61" | grep -qxF 'root/t61/lit[1]' \
  && ok "a line naming an existing file literally is taken literally, brackets and all" \
  || no "a literal path with brackets was treated as a glob"
printf '%s\n' "$got61" | grep -q 'none-' && no "a glob that matches nothing was passed through" || ok "a glob that matches nothing adds nothing"
printf '%s\n' "$got61" | grep -qx 'root/t61/dir' && ok "plain home-relative lines still expand" || no "home-relative expansion broke"
TIMECRATE_INCLUDE=/tmp/t61.inc "$TC" backup --dry-run >/tmp/t61.out 2>&1 || true
grep -q 'missing on disk: /~/' /tmp/t61.out && no "an existing ~/ entry is still reported missing" \
  || ok "existing ~/ entries are not reported missing"
grep -q 'missing on disk: /tmp/t61-missing' /tmp/t61.out && ok "a genuinely missing entry still is" \
  || no "a missing entry went unreported"
grep -q 'missing on disk: .*none-' /tmp/t61.out && no "a glob that matches nothing was reported missing" \
  || ok "and a glob that matches nothing is not"
: > /tmp/t61.empty
[ -z "$(bash -c ". /tmp/t61.fn; INCLUDE_FILE=/tmp/t61.empty USER_HOME=/root build_include")" ] \
  && ok "an empty include list yields an empty kit list: nothing is added that the list does not name" \
  || no "the engine adds paths the include list does not name"
rm -rf /root/t61 /tmp/t61.inc /tmp/t61.fn /tmp/t61.out /tmp/t61.empty

echo "== T62: an armed timer from the previous package blocks uploads (3.0.0) =="
# Two tools pruning one remote each count the other's kits and delete kits early, so while the
# previous package's timer is armed this refuses to upload. A local run is unaffected.
rm -rf /tmp/t62; mkdir -p /tmp/t62/bin /tmp/t62/remote
cat > /tmp/t62/bin/systemctl <<'FAKE'
#!/bin/sh
case "$*" in *"is-active --quiet time-machine-backup.timer"*) exit "${OLD_TIMER_ACTIVE:-1}";; esac
exit 1
FAKE
chmod +x /tmp/t62/bin/systemctl
printf 'tmp/tiny\n' > /tmp/t62/inc
OLD_TIMER_ACTIVE=0 PATH="/tmp/t62/bin:$PATH" TIMECRATE_REMOTE=fake:../t62/remote TIMECRATE_INCLUDE=/tmp/t62/inc \
  TIMECRATE_EXCLUDE=/tmp/exc.small TIMECRATE_STATE=/tmp/t62/state "$TC" backup --force >/tmp/t62/a.out 2>&1 \
  && no "a backup uploaded while the previous package's timer was armed" \
  || { grep -q "previous package's backup timer" /tmp/t62/a.out && ok "an armed previous-package timer stops the upload, and says how to disarm it" \
       || no "wrong refusal: $(tail -1 /tmp/t62/a.out)"; }
[ -z "$(ls /tmp/t62/remote)" ] && ok "and nothing reached the remote" || no "a kit was uploaded anyway"
OLD_TIMER_ACTIVE=0 PATH="/tmp/t62/bin:$PATH" TIMECRATE_INCLUDE=/tmp/t62/inc TIMECRATE_EXCLUDE=/tmp/exc.small \
  TIMECRATE_STATE=/tmp/t62/state TIMECRATE_STAGING=/tmp/t62/stage "$TC" backup --no-upload --force >/tmp/t62/b.out 2>&1 \
  && ok "a local run is unaffected by the guard" || no "the guard blocked a local run: $(tail -1 /tmp/t62/b.out)"
OLD_TIMER_ACTIVE=1 PATH="/tmp/t62/bin:$PATH" TIMECRATE_REMOTE=fake:../t62/remote TIMECRATE_INCLUDE=/tmp/t62/inc \
  TIMECRATE_EXCLUDE=/tmp/exc.small TIMECRATE_STATE=/tmp/t62/state "$TC" backup --force >/tmp/t62/c.out 2>&1 \
  && ok "with the old timer disarmed the upload goes ahead" || no "a disarmed old timer still blocked the upload: $(tail -1 /tmp/t62/c.out)"
rm -rf /tmp/t62 /tmp/fr60 /tmp/t60

echo "== T63: harden can prove the off-box copy through a command (3.0.0) =="
# The secret-store integration is a command of your own now. harden must accept a command whose
# key has the configured fingerprint -- and refuse one whose key does not, or that prints nothing.
rm -rf /tmp/t63; mkdir -p /tmp/t63
printf '#!/bin/sh\ncat /tmp/tm/conf/timecrate-secret.asc\n' > /tmp/t63/good; chmod 755 /tmp/t63/good
printf '#!/bin/sh\ncat /tmp/t63/other.asc\n' > /tmp/t63/other; chmod 755 /tmp/t63/other
printf '#!/bin/sh\nexit 0\n' > /tmp/t63/empty; chmod 755 /tmp/t63/empty
mkdir -p /tmp/t63/ring && chmod 700 /tmp/t63/ring
GNUPGHOME=/tmp/t63/ring gpg --batch --quick-gen-key --passphrase '' other@t63.example rsa2048 default never >/dev/null 2>&1
GNUPGHOME=/tmp/t63/ring gpg --batch --armor --export-secret-keys other@t63.example > /tmp/t63/other.asc 2>/dev/null
[ -s /tmp/t63/other.asc ] || no "could not make a second key for T63 (harness broken)"
"$TC" escrow-confirm >/dev/null 2>&1
echo no | TIMECRATE_ESCROW_KEY_CMD=/tmp/t63/good "$TC" harden >/tmp/t63/a.out 2>&1
grep -q 'Off-box escrow verified: TIMECRATE_ESCROW_KEY_CMD returns secret key' /tmp/t63/a.out \
  && ok "a command returning the configured key satisfies harden's off-box check" \
  || no "the escrow-key command was not accepted: $(grep -E 'ERROR|verified' /tmp/t63/a.out | head -1)"
grep -q 'nothing deleted' /tmp/t63/a.out && [ -s /tmp/tm/conf/timecrate-secret.asc ] \
  && ok "and answering anything but SHRED still deletes nothing" || no "harden did not stop at the confirmation"
for bad in other empty; do
  echo no | TIMECRATE_ESCROW_KEY_CMD="/tmp/t63/$bad" "$TC" harden >/tmp/t63/b.out 2>&1
  grep -q 'could not verify ANY off-box escrow copy' /tmp/t63/b.out && [ -s /tmp/tm/conf/timecrate-secret.asc ] \
    && ok "a command returning $( [ "$bad" = other ] && echo 'the wrong key' || echo nothing) is refused before anything is shredded" \
    || no "harden with a $bad escrow command: $(tail -1 /tmp/t63/b.out)"
done
rm -rf /tmp/t63
rm -f /usr/local/bin/rclone

echo "== T64: the capstone decrypts on disk and fails closed; the guest reboots itself (3.0.1) =="
# Ubuntu 26.04 mounts /tmp as a tmpfs of half the RAM, under 1 GiB in the 2 GB capstone VM, and
# kits outgrew it. The in-VM decrypt to /tmp ran out of space and wrote no signature record; the
# script read "no record" as a kit from before signing and went on, ignored the exit codes of zstd
# and tar, and the run failed steps later on manifests it never checked had come out.
RIV="$REPO/deploy/recover-in-vm.sh"
code64="$(grep -vE '^[[:space:]]*#' "$RIV")"
dline64="$(printf '%s\n' "$code64" | grep -E 'gpg .* -d ')"
dec64="$(printf '%s\n' "$code64" | sed -n 's/^DEC=\([^;[:space:]]*\).*/\1/p')"
if [ -z "$dline64" ]; then no "no gpg decrypt found in recover-in-vm.sh — this check no longer sees it"
elif printf '%s %s\n' "$dline64" "$dec64" | grep -qE '(^|[^[:alnum:]_])/(tmp|dev/shm)/'; then
  no "recover-in-vm.sh decrypts into /tmp, a RAM-backed tmpfs smaller than a kit"
else ok "recover-in-vm.sh decrypts to disk-backed space, not /tmp"; fi
printf '%s\n' "$code64" | grep -qiE 'unsigned|signature check n/a' \
  && no "recover-in-vm.sh has a branch for an 'unsigned' kit again — a full disk produces exactly that" \
  || ok "and no branch lets a kit through without a signature record"
printf '%s\n' "$code64" | grep -q 'DECRYPTION_OKAY' && printf '%s\n' "$code64" | grep -q 'VALIDSIG' \
  && printf '%s\n' "$code64" | grep -q 'PIPESTATUS' \
  && ok "it requires DECRYPTION_OKAY and VALIDSIG, and reads the exit codes of zstd and tar" \
  || no "recover-in-vm.sh no longer checks DECRYPTION_OKAY, VALIDSIG and the extract's exit codes"
printf '%s\n' "$code64" | grep -qE "bash -c '[^']*[\$]M" \
  && no "a single-quoted bash -c reads \$M, which is unset in the child shell" \
  || ok "and no single-quoted child shell reads a variable it does not have"
# The engine's own kit-fetching commands have the same exposure: verify and recovery-drill pull a
# whole kit and decrypt it in their work dir, so that dir must not be a bare mktemp -d (/tmp).
for fn64 in cmd_verify cmd_recovery_drill; do
  body64="$(sed -n "/^$fn64(){/,/^}/p" "$REPO/timecrate")"
  if [ -z "$body64" ]; then no "$fn64 not found in the engine — this check no longer sees it"
  elif printf '%s\n' "$body64" | grep -q 'disk_workdir' && ! printf '%s\n' "$body64" | grep -qE 'mktemp -d\)'; then
    ok "$fn64 fetches and decrypts kits in a disk-backed work dir"
  else no "$fn64 works in a bare mktemp -d, which is /tmp — a tmpfs smaller than a kit"; fi
done

# The same script, run: a kit with no signature must stop it before anything is extracted, and a
# signed one must still pass. It installs packages and writes under /etc, as it does in the VM.
rm -rf /tmp/t64 /home/ubuntu/timecrate-in /restore; mkdir -p /tmp/t64/bin /home/ubuntu/timecrate-in
IN64=/home/ubuntu/timecrate-in
cp /tmp/tm/conf/timecrate-secret.asc "$IN64/escrow-key.asc"
cp /tmp/tm/conf/timecrate-signing-public.asc "$IN64/signing-pub.asc"
stage64(){ cp "$1" "$IN64/kit.tar.zst.gpg"; (cd "$IN64" && sha256sum kit.tar.zst.gpg > kit.sha256); }
echo evil > /tmp/t64/evil
tar -cf - -C /tmp/t64 evil | zstd -q --long=27 \
  | GNUPGHOME=/tmp/tm/conf/gnupg gpg --batch --yes --trust-model always --cipher-algo AES256 \
      --compress-algo none -e -r "$(cat /tmp/tm/conf/recipients.txt)" -o /tmp/t64/forged.gpg 2>/dev/null
stage64 /tmp/t64/forged.gpg
out64="$(bash "$RIV" 2>&1)"; rc64=$?
[ "$rc64" != 0 ] && printf '%s' "$out64" | grep -q '\[FAIL\] kit NOT authenticated' \
  && ok "a kit that decrypts but carries no signature FAILS in the VM" \
  || no "an unsigned kit was not failed: rc=$rc64 $(printf '%s' "$out64" | grep -E 'S4|FAIL|PASS' | tail -3)"
! printf '%s' "$out64" | grep -q '^S5' && [ ! -e /restore/evil ] \
  && ok "and the run stops there, with nothing extracted" \
  || no "the run went on past an unauthenticated kit"
TIMECRATE_INCLUDE=/tmp/inc.small TIMECRATE_EXCLUDE=/tmp/exc.small TIMECRATE_STAGING=/tmp/t64/staging \
  "$TC" backup --no-upload --force >/tmp/t64/bk.out 2>&1
good64="$(ls /tmp/t64/staging/timecrate-*.tar.zst.gpg 2>/dev/null | head -1)"
if [ -z "$good64" ]; then no "could not write a signed kit for T64: $(tail -1 /tmp/t64/bk.out)"
else
  rm -rf /restore; stage64 "$good64"
  out64g="$(bash "$RIV" 2>&1)"
  printf '%s' "$out64g" | grep -q '\[PASS\] kit decrypted, signed by' \
    && printf '%s' "$out64g" | grep -q '\[PASS\] extracted (.*TIMECRATE-MANIFESTS)' \
    && ok "and a signed kit still decrypts, verifies and extracts whole" \
    || no "a signed kit no longer passes S4: $(printf '%s' "$out64g" | grep -A3 '^S4' | tail -3)"
  [ ! -e "$IN64/kit.tar.zst.gpg" ] && [ ! -e "$IN64/kit.tar.zst" ] \
    && ok "and neither the kit nor its plaintext is left taking up the VM's disk" \
    || no "the verified kit or its plaintext was left on the VM's disk"
fi
rm -rf /home/ubuntu/timecrate-in /restore /etc/timecrate-capstone-marker /etc/timecrate-capstone-restored

# The reboot. `multipass restart` waits on the daemon's own SSH session, and that wait has run out
# its bound while the guest booted fine. The guest now reboots itself, and only an answer from a
# NEW boot counts. When none comes, one forced stop and start tells a guest that cannot boot from
# a multipass that lost its way back in, and the alert carries what that boot logged.
mkdir -p /tmp/t64/conf /tmp/t64/landed
printf 'key\n' > /tmp/t64/conf/timecrate-secret.asc
printf 'pub\n' > /tmp/t64/conf/timecrate-signing-public.asc
printf 'rc\n'  > /tmp/t64/rclone.conf
printf '#!/bin/bash\nfor a in "$@"; do last="$a"; done\nprintf "kit\\n" > "$last" 2>/dev/null\nexit 0\n' > /tmp/t64/bin/rclone
printf '#!/bin/bash\n[ "$1" = list ] && { echo "timecrate-2026-01-01_00-00-00.tar.zst.gpg"; exit 0; }\nexit 0\n' > /tmp/t64/bin/timecrate
cat > /tmp/t64/bin/multipass <<'FAKE'
#!/bin/bash
S=/tmp/t64; key(){ echo "$1" | tr / _; }
echo "$*" >> $S/calls
case "$1" in
  list)     echo "Name,State,IPv4,Image"; [ -f $S/deleted ] || echo "timecrate-capstone-vm,Running,192.0.2.2,Ubuntu";;
  launch)   rm -f $S/deleted;;
  transfer) stat -c %s "$2" > "$S/landed/$(key "${3#*:}")" 2>/dev/null;;
  delete)   touch $S/deleted;;
  start)    echo 00000000-0000-4000-8000-0000000000ff > $S/boot;;
  exec)
    shift; for a in "$@"; do last="$a"; done
    case "$*" in
      *"stat -c %s"*)       cat "$S/landed/$(key "$last")" 2>/dev/null || exit 1;;
      *boot_id*)            cat $S/boot;;
      *"systemctl reboot"*) [ "$(cat $S/mode)" = healthy ] && echo 00000000-0000-4000-8000-000000000002 > $S/boot; exit 255;;
      *--after-reboot*)     echo "  [PASS] marker"; echo "==== AFTER-REBOOT RESULT: 1 PASS / 0 FAIL ====";;
      *recover-in-vm*)      if [ "$(cat $S/mode)" != failed ]; then echo "==== IN-VM RESULT: 9 PASS / 0 FAIL ===="
                            else printf '  [FAIL] first thing\n  [FAIL] second thing\n==== IN-VM RESULT: 7 PASS / 2 FAIL ====\n'; fi;;
      *journalctl*)         echo "kernel: a warning from the boot that never answered";;
      *"systemctl --failed"*) echo "broken.service loaded failed failed Broken";;
    esac;;
esac
exit 0
FAKE
chmod +x /tmp/t64/bin/*
t64run(){ rm -f /tmp/t64/deleted /tmp/t64/calls; echo 00000000-0000-4000-8000-000000000001 > /tmp/t64/boot; echo "$1" > /tmp/t64/mode
  env TIMECRATE_USER=root TIMECRATE_CONF=/tmp/t64/conf TIMECRATE_RCLONE_CONF=/tmp/t64/rclone.conf \
    PATH=/tmp/t64/bin:/usr/sbin:/usr/bin:/sbin:/bin TIMECRATE_CAPSTONE_VM=timecrate-capstone-vm \
    TIMECRATE_CAPSTONE_REBOOT_TRIES=2 bash "$CAP" 2>&1; }
out64h="$(t64run healthy)"
printf '%s' "$out64h" | grep -q 'CAPSTONE PASSED' && printf '%s' "$out64h" | grep -q 'AFTER-REBOOT RESULT' \
  && ok "a guest that reboots itself and answers from a new boot passes, after-reboot checks and all" \
  || no "the healthy reboot did not pass: $(printf '%s' "$out64h" | tail -2)"
grep -q '^restart' /tmp/t64/calls \
  && no "the capstone still calls multipass restart" || ok "and multipass restart is never called"
out64f="$(t64run failed)"
printf '%s' "$out64f" | grep -q 'CAPSTONE FAILED.*first thing; second thing' \
  && ok "the alert lists every in-VM [FAIL] line, not only the first" \
  || no "the in-VM failures were not all reported: $(printf '%s' "$out64f" | grep 'CAPSTONE FAILED')"
# A recovery that stopped early wrote no marker: rebooting it only adds a false second cause.
! grep -q 'systemctl reboot' /tmp/t64/calls && ! printf '%s' "$out64f" | grep 'CAPSTONE FAILED' | grep -q reboot \
  && ok "and a failed in-VM run is not rebooted, so the alert names only the real cause" \
  || no "a failed in-VM run was still rebooted: $(printf '%s' "$out64f" | grep 'CAPSTONE FAILED')"
out64w="$(t64run wedged)"
printf '%s' "$out64w" | grep -q 'never answered after its reboot, but did after a forced stop and start' \
  && grep -q '^stop --force' /tmp/t64/calls \
  && ok "a guest still on its old boot is not taken as rebooted; one forced stop and start follows" \
  || no "the no-new-boot path did not force a stop and start: $(printf '%s' "$out64w" | grep 'CAPSTONE FAILED')"
printf '%s' "$out64w" | grep -q 'a warning from the boot that never answered' \
  && printf '%s' "$out64w" | grep -q 'broken.service' \
  && ok "and the alert carries that boot's warnings and the failed units" \
  || no "the forced boot's journal and failed units are not in the alert"
rm -rf /tmp/t64 /root/timecrate-capstone-work.* 2>/dev/null

echo "== T65: the drill's unprivileged verify keeps the rclone password command =="
# sudo env_reset drops RCLONE_PASSWORD_COMMAND, so `verify --all` under
# `sudo -u user env HOME=...` met an encrypted rclone config with no way to
# answer its password prompt and died on EOF, while the root-run backup
# worked. The stub sudo models env_reset (env -i); only what the drill
# passes explicitly can reach the stub timecrate.
mkdir -p /tmp/t65/bin /tmp/t65/conf
cat > /tmp/t65/bin/sudo <<'T65SUDO'
#!/bin/bash
[ "$1" = "-u" ] && shift 2
exec env -i PATH="$PATH" "$@"
T65SUDO
cat > /tmp/t65/bin/timecrate <<'T65TC'
#!/bin/bash
case "$1" in
  recovery-drill) echo "RECOVERY DRILL PASSED";;
  verify) printf 'marker=%s\n' "${RCLONE_PASSWORD_COMMAND:-}" > /tmp/t65/mark; echo ok;;
esac
T65TC
chmod +x /tmp/t65/bin/*
env -u TIMECRATE_ESCROW_KEY_CMD -u TIMECRATE_ESCROW_SSH \
  PATH=/tmp/t65/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  TIMECRATE_USER="$(id -un)" TIMECRATE_CONF=/tmp/t65/conf \
  RCLONE_PASSWORD_COMMAND=t65-marker \
  bash "$REPO/deploy/drill-and-alert.sh" >/tmp/t65/out 2>&1; drc=$?
[ "$drc" = 0 ] && grep -q '^marker=t65-marker$' /tmp/t65/mark \
  && ok "RCLONE_PASSWORD_COMMAND reaches the unprivileged verify across sudo" \
  || no "verify lost the rclone password command: rc=$drc mark=$(cat /tmp/t65/mark 2>/dev/null)"
rm -rf /tmp/t65

echo "==== RESULT: $PASS PASS / $FAIL FAIL ===="
[ "$FAIL" -eq 0 ]
