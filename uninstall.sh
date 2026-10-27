#!/bin/sh
# v6watch uninstaller for Asuswrt-Merlin
#
# Removes the cru job, the v6watch line from /jffs/scripts/services-start
# (other lines are left alone) and /jffs/addons/v6watch.d.
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
[ -f "$HOOK" ] && sed -i '/# v6watch$/d' "$HOOK"
rm -rf /tmp/v6watch.lock /tmp/v6watch.last /tmp/v6watch.fail

if [ "$1" = --keep-log ] && [ -f "$ADDON_DIR/v6watch.log" ]; then
  for f in "$ADDON_DIR"/*; do
    [ "$f" = "$ADDON_DIR/v6watch.log" ] || rm -rf "$f"
  done
  echo "v6watch removed; log kept in $ADDON_DIR/v6watch.log"
else
  rm -rf "$ADDON_DIR"
  echo "v6watch removed"
fi
