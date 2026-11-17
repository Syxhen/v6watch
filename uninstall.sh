#!/bin/sh
# v6watch uninstaller for Asuswrt-Merlin
#
# Removes the cru job, the v6watch lines from /jffs/scripts/services-start,
# /jffs/configs/profile.add and /etc/profile (other lines are left alone) and
# /jffs/addons/v6watch.d.
# With --keep-log the persistent log stays in /jffs/addons/v6watch.d.
#
# Copyright (C) 2026 Syxhen
# SPDX-License-Identifier: GPL-3.0-or-later

ADDON_DIR=/jffs/addons/v6watch.d
HOOK=/jffs/scripts/services-start

case $1 in
  ''|--keep-log) ;;
  *) echo "Usage: $0 [--keep-log]" >&2; exit 2 ;;
esac

cru d v6watch 2>/dev/null
for f in "$HOOK" /jffs/configs/profile.add /etc/profile; do
  [ -w "$f" ] && sed -i '/# v6watch$/d' "$f"
done
rm -rf /tmp/v6watch.lock /tmp/v6watch.last /tmp/v6watch.fail /tmp/v6watch.count /tmp/v6watch.tries /tmp/v6watch.day /tmp/v6watch.status

if [ "$1" = --keep-log ] && [ -f "$ADDON_DIR/v6watch.log" ]; then
  for f in "$ADDON_DIR"/*; do
    [ "$f" = "$ADDON_DIR/v6watch.log" ] || rm -rf "$f"
  done
  echo "v6watch removed; log kept in $ADDON_DIR/v6watch.log"
else
  rm -rf "$ADDON_DIR"
  echo "v6watch removed"
fi
