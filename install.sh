#!/bin/sh
# v6watch installer for Asuswrt-Merlin
#
# Run it from the directory that contains v6watch.sh. Safe to run again: it
# updates the script, keeps an existing config and only appends its own line
# to /jffs/scripts/services-start, never touching lines of other add-ons.
#
# Copyright (C) 2026 Syxhen
# SPDX-License-Identifier: GPL-3.0-or-later

ADDON_DIR=/jffs/addons/v6watch.d
HOOK=/jffs/scripts/services-start
HOOK_LINE="$ADDON_DIR/v6watch.sh cron # v6watch"
SRC_DIR=$(cd "$(dirname "$0")" && pwd)

die() { echo "Error: $1" >&2; exit 1; }
warn() { echo "Warning: $1" >&2; }

# Looks a command up in $PATH: the BusyBox sh on some firmwares lacks `command -v`
have() {
  (IFS=:; for d in $PATH; do [ -x "$d/$1" ] && exit 0; done; exit 1)
}

# Prerequisites
[ -d /jffs ] || die "/jffs not found: this does not look like an Asuswrt-Merlin router"
nvram get rc_support 2>/dev/null | grep -q am_addons ||
  die "this firmware does not support Merlin add-ons (Asuswrt-Merlin 384.15 or later is needed)"
[ "$(nvram get jffs2_scripts)" = 1 ] ||
  die "custom scripts are disabled: enable 'Administration > System > Enable JFFS custom scripts and configs', then run the installer again"
for c in awk cru ip killall logger pidof service; do
  have "$c" || die "required command not found: $c"
done
have ping6 || have ping || die "required command not found: ping6"

for f in v6watch.sh v6watch.conf uninstall.sh; do
  [ -f "$SRC_DIR/$f" ] || die "$f not found in $SRC_DIR"
  # A copy edited or extracted on Windows would break BusyBox sh
  grep -q "$(printf '\r')" "$SRC_DIR/$f" && die "$f has Windows (CRLF) line endings"
done

[ "$(nvram get ipv6_service)" = disabled ] && warn "IPv6 is disabled in the router settings"
pidof odhcp6c >/dev/null 2>&1 ||
  warn "odhcp6c is not running: v6watch needs native IPv6 with DHCPv6 prefix delegation"

# Files
mkdir -p "$ADDON_DIR" || die "cannot create $ADDON_DIR"
cp "$SRC_DIR/v6watch.sh" "$SRC_DIR/uninstall.sh" "$ADDON_DIR/" || die "cannot copy files to $ADDON_DIR"
chmod 755 "$ADDON_DIR/v6watch.sh" "$ADDON_DIR/uninstall.sh"
cp "$SRC_DIR/v6watch.conf" "$ADDON_DIR/v6watch.conf.sample"
if [ -f "$ADDON_DIR/v6watch.conf" ]; then
  echo "Keeping the existing $ADDON_DIR/v6watch.conf"
else
  cp "$SRC_DIR/v6watch.conf" "$ADDON_DIR/v6watch.conf"
fi

# Boot hook: cru jobs are lost on reboot, services-start recreates ours
if [ ! -f "$HOOK" ]; then
  mkdir -p /jffs/scripts
  echo "#!/bin/sh" > "$HOOK"
fi
if ! grep -qxF "$HOOK_LINE" "$HOOK"; then
  sed -i '/# v6watch$/d' "$HOOK"
  [ -n "$(tail -c 1 "$HOOK")" ] && echo >> "$HOOK"
  echo "$HOOK_LINE" >> "$HOOK"
  echo "Added v6watch to $HOOK"
fi
chmod a+x "$HOOK"

"$ADDON_DIR/v6watch.sh" cron || die "cannot create the cru job"
echo "Installed v6watch $("$ADDON_DIR/v6watch.sh" version | cut -d' ' -f2) in $ADDON_DIR"
echo
"$ADDON_DIR/v6watch.sh" check
exit 0
