#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Spencer Norton
#
# Capstone: full wiped-OS recovery INSIDE a booted ubuntu:26.04 VM (real systemd/dconf/apt).
# Restores only non-boot-critical /etc so the throwaway VM stays reachable across a reboot.
#   recover-in-vm.sh                  the recovery (run by the capstone before the reboot)
#   recover-in-vm.sh --after-reboot   did what was restored survive the boot, and take effect?
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
PASS=0; FAIL=0
ok(){ echo "  [PASS] $*"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
result(){ echo "==== IN-VM RESULT: $PASS PASS / $FAIL FAIL ===="; [ "$FAIL" -eq 0 ]; exit; }
IN=/home/ubuntu/timecrate-in
KIT=$IN/kit.tar.zst.gpg; KEY=$IN/escrow-key.asc
MARK=/etc/timecrate-capstone-marker
RESTORED=/etc/timecrate-capstone-restored

if [ "${1:-}" = --after-reboot ]; then
  echo "R1: the marker and every restored file survived the reboot"
  [ -f "$MARK" ] && ok "marker written before the reboot is still there" || no "the marker written before the reboot is gone"
  missing=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "/etc/$f" ] || { missing=$((missing+1)); echo "    missing: /etc/$f"; }
  done < "$RESTORED"
  [ "$missing" = 0 ] && ok "all $(grep -c . "$RESTORED" 2>/dev/null || echo 0) restored file(s) are still there" \
    || no "$missing restored file(s) did not survive the reboot"
  echo "R2: restored sysctl values are in effect (TIMECRATE_CAPSTONE_SYSCTL=${TIMECRATE_CAPSTONE_SYSCTL:-})"
  for key in ${TIMECRATE_CAPSTONE_SYSCTL:-}; do
    # the value the restored files set: the last assignment in the order systemd-sysctl reads them
    want=""
    for f in /etc/sysctl.d/*.conf; do
      [ -f "$f" ] || continue
      v="$(sed -nE "s/^[[:space:]]*-?${key//./[.]}[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" "$f" | tail -1)"
      [ -n "$v" ] && want="$v"
    done
    got="$(sysctl -n "$key" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//')"
    want="$(printf '%s' "$want" | tr -s '[:space:]' ' ')"
    if [ -z "$want" ]; then no "$key: no restored /etc/sysctl.d file sets it"
    elif [ "$got" = "$want" ]; then ok "$key = $got, as restored"
    else no "$key is '$got' after the reboot, the restored files set '$want'"; fi
  done
  echo "==== AFTER-REBOOT RESULT: $PASS PASS / $FAIL FAIL ===="
  [ "$FAIL" -eq 0 ]; exit
fi

echo "S1: install recovery tools (gpg, zstd, dconf) on the real OS"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq gpg gpg-agent openssl zstd dconf-cli dbus >/dev/null 2>&1
{ command -v gpg && command -v zstd; } >/dev/null && ok "gpg + zstd installed" || no "tools not installable"

echo "S2: import ONLY the escrowed key"
gpg --batch --import "$KEY" >/dev/null 2>&1; gpgconf --kill gpg-agent >/dev/null 2>&1
gpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec' && ok "secret key imported" || no "key import failed"

echo "S3: checksum"
exp=$(awk '{print $1}' "$IN/kit.sha256" 2>/dev/null); act=$(sha256sum "$KIT" | awk '{print $1}')
[ -n "$exp" ] && [ "$exp" = "$act" ] && ok "sha256 matches" || no "sha256 mismatch"

echo "S4: break-glass decrypt -> VERIFY SIGNATURE -> decompress -> extract"
# The plaintext goes beside the kit, on the VM's disk, and never to /tmp: Ubuntu 26.04 mounts /tmp
# as a tmpfs of half the RAM, under 1 GiB on this VM, and a kit is bigger than that. A decrypt that
# runs out of space ends with no signature record at all, and the version before this read that as
# "the kit predates signing", passed, and went on to extract a truncated archive.
DEC=$IN/kit.tar.zst; ST=$IN/gpg-status
mkdir -p /restore
want=$(gpg --batch --show-keys --with-colons "$IN/signing-pub.asc" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
gpg --batch --import "$IN/signing-pub.asc" >/dev/null 2>&1
# Tool-independent PQ unwrap before the existing signature gate.
if [ "$(head -c 13 "$KIT")" = TIMECRATE-PQ1 ]; then
  if ! (
    set -euo pipefail
    umask 077
    head -n1 "$KIT" | cut -d' ' -f4 | base64 -d > "$IN/kem.ct"
    openssl pkeyutl -decap -inkey "$IN/pq-secret.pem" -in "$IN/kem.ct" -secret "$IN/kem.ss"
    od -An -tx1 -v "$IN/kem.ss" | tr -d ' \n' > "$IN/kem.pass"
    tail -n +2 "$KIT" | gpg --batch --yes --pinentry-mode loopback --passphrase-file "$IN/kem.pass" -o "$IN/inner.gpg" -d
  ) 2>"$IN/pq.err"; then
    rm -f "$IN/kem.ct" "$IN/kem.ss" "$IN/kem.pass" "$IN/inner.gpg"
    no "PQ envelope recovery failed; nothing extracted"; result
  fi
  mv "$IN/inner.gpg" "$KIT"
  rm -f "$IN/kem.ct" "$IN/kem.ss" "$IN/kem.pass"
fi
grc=0; gpg --batch --no-tty --yes --status-file "$ST" -o "$DEC" -d "$KIT" 2>"$IN/gpg.err" || grc=$?
got=$(awk '/^\[GNUPG:\] VALIDSIG /{print $3; exit}' "$ST" 2>/dev/null)
# As the engine decides it: a clean exit, a completed decryption, and a valid signature by the
# staged signing key. Anything else, no signature record at all included, fails, and nothing is
# extracted. Every kit since v1.3.0 is signed.
if [ "$grc" = 0 ] && grep -q '^\[GNUPG:\] DECRYPTION_OKAY' "$ST" && [ -n "$want" ] && [ "$got" = "$want" ]; then
  ok "kit decrypted, signed by $got (authenticated before extract)"
  rm -f "$KIT"   # checked and decrypted: its space goes to the extract and the packages
else
  no "kit NOT authenticated, nothing extracted (gpg=$grc, signer ${got:-none}, expected ${want:-none, no signing-pub.asc}): $(grep '^gpg: ' "$IN/gpg.err" 2>/dev/null | tail -1) [$(df -h "$IN" | awk 'NR==2{print $4}') free on $IN]"
  rm -f "$DEC"; result
fi
zstd -dc --long=27 < "$DEC" 2>"$IN/zstd.err" | tar --numeric-owner -xpf - -C /restore 2>"$IN/tar.err"
x=("${PIPESTATUS[@]}")
rm -f "$DEC"
# The manifests directory is named after the tool that wrote the kit, and the engine writes it
# LAST: both stages exiting clean with the manifests present is what proves the whole kit came out.
M=/restore/TIMECRATE-MANIFESTS; [ -d "$M" ] || M=/restore/TIMEMACHINE-MANIFESTS
if [ "${x[0]}" = 0 ] && [ "${x[1]}" = 0 ] && [ -d "$M" ]; then
  ok "extracted ($(find /restore/etc -type f 2>/dev/null | wc -l) /etc files, and ${M#/restore/})"
else
  err=$(cat "$IN/zstd.err" "$IN/tar.err" 2>/dev/null | tail -1)
  no "extract failed (zstd=${x[0]} tar=${x[1]}, manifests $([ -d "$M" ] && echo present || echo MISSING))${err:+: $err}"
  result
fi

echo "S5: restore apt sources + keyrings, apt update, then REALLY install a sample of manual packages"
cp -a /restore/etc/apt/sources.list /etc/apt/ 2>/dev/null || true
cp -a /restore/etc/apt/sources.list.d/. /etc/apt/sources.list.d/ 2>/dev/null || true
cp -a /restore/etc/apt/trusted.gpg.d/. /etc/apt/trusted.gpg.d/ 2>/dev/null || true
mkdir -p /usr/share/keyrings /etc/apt/keyrings
cp -a /restore/usr/share/keyrings/. /usr/share/keyrings/ 2>/dev/null || true
cp -a /restore/etc/apt/keyrings/. /etc/apt/keyrings/ 2>/dev/null || true
apt-get update -qq >/tmp/upd 2>&1 && ok "apt update OK (base + 3rd-party repos)" || no "apt update: $(grep -iE 'NO_PUBKEY|Err:' /tmp/upd | head -1)"
# Ubuntu 26.04 sources are deb822 (.sources with Signed-By:) — prove the restored tree carries them
ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1 && ok "deb822 .sources restored" || no "no deb822 .sources in restored apt tree"
SAMPLE=$(comm -12 <(sort "$M/apt-manual.txt") <(apt-cache pkgnames | sort) | grep -vE '^(linux-|nvidia-|steam)' | head -8 | tr '\n' ' ')
# an empty sample installs nothing, successfully
if [ -z "$SAMPLE" ]; then no "no installable package from $M/apt-manual.txt — nothing to prove the restored sources with"
elif apt-get install -y -qq --no-install-recommends $SAMPLE >/tmp/inst 2>&1; then ok "actually installed: $SAMPLE"; else no "sample install failed: $(tail -1 /tmp/inst)"; fi

echo "S5b: package replay EXACTLY as the runbook documents (merge-avail -> set-selections -> dselect-upgrade)"
# this is the path RESTORE.md tells a human to type — if a doc regression breaks it
# (e.g. dropping merge-avail, without which set-selections silently records nothing), fail HERE
# Foreign architectures first, exactly as the runbook now says. Without this the replay does not
# degrade, it ABORTS: one selected package with an unavailable i386 dependency makes apt refuse the
# whole transaction and plan zero installs. That is what this step caught on 2026-08-02.
if [ -s "$M/dpkg-foreign-architectures.txt" ]; then
  while read -r a; do [ -n "$a" ] && dpkg --add-architecture "$a"; done \
    < "$M/dpkg-foreign-architectures.txt"
  apt-get update -qq >/dev/null 2>&1
  ok "replayed foreign architectures: $(tr '\n' ' ' < "$M/dpkg-foreign-architectures.txt")"
else
  # Kits written before v2.8.0 carry no foreign-architecture manifest, and on 2026-08-04 that was
  # THIRTEEN of the fifteen kits on the remote — every one of which would replay zero packages.
  # The information is still in the kit though: dpkg records a foreign arch as a `:arch` suffix in
  # the selections, so derive it from there rather than abandoning the replay. Found by the first
  # real run of the oldest-kit capstone, on the 2026-07-22 kit, which planned 0 installs.
  derived="$(awk '{print $1}' "$M/dpkg-selections.txt" 2>/dev/null \
             | sed -n 's/.*:\([a-z0-9][a-z0-9-]*\)$/\1/p' | sort -u \
             | grep -vx "$(dpkg --print-architecture)" || true)"
  if [ -n "$derived" ]; then
    for a in $derived; do dpkg --add-architecture "$a"; done
    apt-get update -qq >/dev/null 2>&1
    ok "no foreign-arch manifest (pre-v2.8.0 kit) — derived from selections: $(echo "$derived" | tr '\n' ' ')"
  elif [ -s "$M/dpkg-selections.txt" ]; then
    ok "no foreign-arch manifest, and no foreign-arch package in the selections — nothing to replay"
  fi
fi
# no selections means no foreign architectures either, and nothing to replay: that is a failure
[ -s "$M/dpkg-selections.txt" ] || no "the kit carries no dpkg-selections.txt — there is no package set to replay"
apt-cache dumpavail | dpkg --merge-avail >/dev/null 2>&1
dpkg --set-selections < "$M/dpkg-selections.txt" 2>/tmp/sel || true
# A simulation (-s) on purpose: it catches the merge-avail/set-selections class of regression, not
# real install failures. A whole machine's packages would not fit a 2 GB VM; if that assurance is
# ever needed, it takes a bigger VM and a real dselect-upgrade.
planned=$(apt-get -s dselect-upgrade 2>/dev/null | grep -c '^Inst')
if [ "${planned:-0}" -gt 50 ]; then ok "dselect-upgrade plans $planned installs (documented replay path works)"
else
  # Report what APT said, not the first line of the selections warnings. The original wording
  # blamed set-selections while the real cause was an unmet i386 dependency aborting the whole
  # transaction — a misdiagnosis that would have sent the next reader down the wrong path.
  aptsay="$(apt-get -s dselect-upgrade 2>&1 | grep -E 'Depends:|E: |broken packages' | head -2 | tr '\n' ' ')"
  no "dselect-upgrade planned only ${planned:-0} installs — apt says: ${aptsay:-nothing}; selections warning: $(head -1 /tmp/sel 2>/dev/null)"
fi

echo "S6: dconf load on a real dbus session + read back"
if dbus-run-session -- dconf load / < "$M/dconf.ini" 2>/tmp/dconf; then
  # The path goes in as $1. Written inside the single quotes, $M belonged to the child shell, where
  # it is unset: the read-back loaded /dconf.ini, which does not exist, and counted a fresh session.
  n=$(dbus-run-session -- bash -c 'dconf load / < "$1" && dconf dump /' _ "$M/dconf.ini" 2>/dev/null | grep -c '=')
  [ "${n:-0}" -gt 0 ] && ok "dconf load OK (${n} keys round-tripped)" || no "dconf load read back no keys from $M/dconf.ini"
else no "dconf load failed: $(tail -1 /tmp/dconf)"; fi

echo "S7: apply non-boot-critical /etc (sysctl.d, modprobe.d) — the reboot-survival test"
cp -a /restore/etc/sysctl.d/. /etc/sysctl.d/ 2>/dev/null || true
cp -a /restore/etc/modprobe.d/. /etc/modprobe.d/ 2>/dev/null || true
echo "timecrate-capstone $(date +%s)" > "$MARK"
# what came back, so the check after the reboot knows what to look for
( cd /restore/etc 2>/dev/null && find sysctl.d modprobe.d -type f 2>/dev/null | sort ) > "$RESTORED"
n="$(grep -c . "$RESTORED" || true)"
[ "${n:-0}" -gt 0 ] && ok "restored $n sysctl.d/modprobe.d file(s) and left a marker for the reboot check" \
  || no "the kit carried no /etc/sysctl.d or /etc/modprobe.d to restore"

result
