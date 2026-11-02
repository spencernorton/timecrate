#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright 2026 Spencer Norton
#
# Build the release packages from this tree: timecrate and timecrate-gui, both Architecture: all.
# Reproducible: with SOURCE_DATE_EPOCH unset, dpkg-buildpackage takes it from debian/changelog.
#   scripts/build.sh [out-dir]      (default: dist/)
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=$(realpath -m "${1:-$root/dist}")
version=$(sed -n '1s/^timecrate (\([^)]*\)).*/\1/p' "$root/debian/changelog")
engine=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$root/timecrate" | head -1)
[ "$version" = "$engine" ] || { echo "debian/changelog says $version, the engine says $engine" >&2; exit 1; }
mkdir -p "$out"

(cd "$root" && dpkg-buildpackage -us -uc -b)
for p in timecrate timecrate-gui time-machine-gui; do mv "$root/../${p}_${version}_all.deb" "$out/"; done
rm -f "$root/../timecrate_${version}"_*.buildinfo "$root/../timecrate_${version}"_*.changes
# No grep -q below: it exits at the first match, dpkg-deb dies of SIGPIPE, and pipefail turns a
# good package into a failed build.
dpkg-deb -c "$out/timecrate_${version}_all.deb" | grep -F './usr/bin/timecrate' >/dev/null
dpkg-deb -c "$out/timecrate_${version}_all.deb" | grep -F './usr/lib/systemd/system/timecrate-backup.timer' >/dev/null
dpkg-deb -c "$out/timecrate-gui_${version}_all.deb" | grep -F './usr/bin/timecrate-gui' >/dev/null
# the transitional package exists to ship NO launcher: the old one leaving is its whole job
! dpkg-deb -c "$out/time-machine-gui_${version}_all.deb" | grep -E '\.desktop$|/usr/bin/' >/dev/null
# and it must keep recommending the rollback: the old window depended on it, so where apt pulled
# it in automatically, dropping that edge lets unattended-upgrades autoremove the rollback
[ "$(dpkg-deb -f "$out/time-machine-gui_${version}_all.deb" Recommends)" = time-machine ]
ls -l "$out"
