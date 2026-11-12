#!/bin/sh
# v6watch - IPv6 prefix delegation watchdog for Asuswrt-Merlin
#
# Checks that the delegated IPv6 prefix (DHCPv6-PD) used on the LAN is really
# routed upstream. If it is not, it first asks odhcp6c for a DHCPv6 renew and,
# if the prefix is still dead at the following checks, restarts the WAN (rate
# limited, less and less often while restarts do not help). Prefix changes,
# failures and a daily check go to syslog and to a persistent log on /jffs.
#
# Usage: v6watch.sh [run|check|cron|uncron|version]
#   run      check and recover if needed (default, run by cron)
#   check    test the current prefix and print the result; no recovery, no log
#   cron     (re)create the cru job, called from /jffs/scripts/services-start
#   uncron   remove the cru job
#
# Copyright (C) 2026 Syxhen
# SPDX-License-Identifier: GPL-3.0-or-later

VERSION=0.2.0
ADDON_DIR=/jffs/addons/v6watch.d
CONF=${V6WATCH_CONF:-$ADDON_DIR/v6watch.conf}

# Runtime state, kept in RAM
STAMP_FILE=/tmp/v6watch.last   # time of the last WAN restart
FAIL_FILE=/tmp/v6watch.fail    # start time of the current outage
COUNT_FILE=/tmp/v6watch.count  # consecutive failed checks of the current outage
TRIES_FILE=/tmp/v6watch.tries  # WAN restarts of the current outage
LOCK_DIR=/tmp/v6watch.lock

# Defaults; override them in $CONF
LAN_IF=br0
TARGETS="2606:4700:4700::1111 2001:4860:4860::8888"
PING_COUNT=2
PING_TIMEOUT=3
RENEW_WAIT=30
RESTART_WAIT=90
FAIL_THRESHOLD=2
RESTART_MIN_INTERVAL=3600
RESTART_MAX_INTERVAL=86400
RESTART_ON_WAN_FAIL=1
DAILY_CHECK=1200
CRON_SCHEDULE="*/5 * * * *"
LOG_FILE=$ADDON_DIR/v6watch.log
LOG_LINES=1000
STATE_FILE=$ADDON_DIR/v6watch.prefix

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

# Event: syslog and persistent log
log() {
  logger -t v6watch "$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
  tail -n "$LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
}

# Repeated message during an outage: syslog only, to spare the flash
note() {
  logger -t v6watch "$1"
}

# First global, non-deprecated address of an interface, excluding ULA (fc00::/7)
global_addr() {
  ip -6 addr show dev "$1" scope global 2>/dev/null |
    awk '/inet6/ && !/deprecated/ && $2 !~ /^f[cd]/ {sub(/\/.*/, "", $2); print $2; exit}'
}

# Interface of the IPv6 default route
wan_if() {
  ip -6 route show default 2>/dev/null |
    awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}

uptime_h() {
  awk '{printf "%dh", $1 / 3600}' /proc/uptime
}

# Looks a command up in $PATH: the BusyBox sh on some firmwares lacks `command -v`
have() {
  (IFS=:; for d in $PATH; do [ -x "$d/$1" ] && exit 0; done; exit 1)
}

ping_from() {
  if have ping6; then
    ping6 -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$1" "$2"
  else
    ping -6 -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$1" "$2"
  fi >/dev/null 2>&1
}

# Succeeds if at least one target answers to source address $1
routed() {
  for t in $TARGETS; do
    ping_from "$1" "$t" && return 0
  done
  return 1
}

# Tells a dead delegated prefix apart from a general IPv6 outage.
# Returns 0 if the WAN address works, 1 if it fails too, 2 if there is none to test
wan_status() {
  w=$(wan_if)
  if [ -z "$w" ]; then echo "no IPv6 default route"; return 2; fi
  a=$(global_addr "$w")
  if [ -z "$a" ]; then echo "no global address on $w"; return 2; fi
  if routed "$a"; then echo "WAN address $a works"; return 0; fi
  echo "WAN address $a fails too"
  return 1
}

# Seconds that must pass after the last WAN restart before the next one:
# RESTART_MIN_INTERVAL, doubled for every restart of the current outage ($1)
# after the first, up to RESTART_MAX_INTERVAL
restart_interval() {
  n=$1
  i=$RESTART_MIN_INTERVAL
  while [ "$n" -gt 1 ] && [ "$i" -lt "$RESTART_MAX_INTERVAL" ]; do
    i=$((i * 2))
    n=$((n - 1))
  done
  [ "$i" -gt "$RESTART_MAX_INTERVAL" ] && i=$RESTART_MAX_INTERVAL
  [ "$i" -lt "$RESTART_MIN_INTERVAL" ] && i=$RESTART_MIN_INTERVAL
  echo "$i"
}

# Reads a number of seconds from a file, 0 if missing or invalid
read_time() {
  v=$(cat "$1" 2>/dev/null)
  case $v in ''|*[!0-9]*) v=0 ;; esac
  echo "$v"
}

lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && exit 0
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  fi
  echo $$ > "$LOCK_DIR/pid"
  trap 'rm -rf "$LOCK_DIR"' EXIT
  trap 'exit 1' HUP INT TERM
}

# Called when the prefix works again; closes the current outage, if any
recovered() {
  if [ -f "$FAIL_FILE" ]; then
    start=$(read_time "$FAIL_FILE")
    end=$(date +%s)
    rm -f "$FAIL_FILE" "$COUNT_FILE" "$TRIES_FILE"
    log "$1 (outage lasted $(( (end - start) / 60 )) min)"
  fi
}

cmd_run() {
  lock
  up=$(uptime_h)
  old=$(cat "$STATE_FILE" 2>/dev/null)   # last seen LAN address, if any
  src=$(global_addr "$LAN_IF")

  if [ -n "$src" ]; then
    if [ "$src" != "$old" ]; then
      if [ -n "$old" ]; then
        log "LAN prefix changed: $old -> $src (router uptime $up)"
      else
        log "Watching LAN prefix: $src (router uptime $up)"
      fi
      echo "$src" > "$STATE_FILE"
      old=$src
    fi

    if routed "$src"; then
      recovered "Prefix of $src routed again"
      if [ -n "$DAILY_CHECK" ] && [ "$(date +%H%M)" = "$DAILY_CHECK" ]; then
        log "Daily check: $src routed (router uptime $up)"
      fi
      exit 0
    fi
    what="Prefix of $src not routed"
  else
    # Without odhcp6c no delegated prefix is expected (IPv6 off, 6in4, ...);
    # with it, a LAN left without a usable address is a failure like any other
    pidof odhcp6c >/dev/null 2>&1 || exit 0
    what="No usable global address on $LAN_IF"
  fi

  # Only the first failure of an outage is written to /jffs
  if [ -f "$FAIL_FILE" ]; then
    out=note
  else
    out=log
    date +%s > "$FAIL_FILE"
  fi
  fails=$(( $(read_time "$COUNT_FILE") + 1 ))
  echo "$fails" > "$COUNT_FILE"

  wan=$(wan_status)
  wan_rc=$?
  "$out" "$what ($wan): trying a DHCPv6 renew"
  if pidof odhcp6c >/dev/null 2>&1; then
    killall -USR1 odhcp6c
    sleep "$RENEW_WAIT"
    cur=$(global_addr "$LAN_IF")
    if [ -n "$cur" ] && routed "$cur"; then
      if [ "$cur" != "$old" ]; then
        echo "$cur" > "$STATE_FILE"
        recovered "Renew brought a new prefix: ${old:+$old -> }$cur, routed"
      else
        recovered "Renew worked: $cur routed again"
      fi
      exit 0
    fi
  else
    "$out" "odhcp6c is not running, skipping the renew"
  fi

  # A WAN restart also drops IPv4: not for a short glitch
  if [ "$fails" -lt "$FAIL_THRESHOLD" ]; then
    note "Still not routed (failed check $fails of $FAIL_THRESHOLD before a WAN restart)"
    exit 0
  fi

  if [ "$wan_rc" -eq 1 ] && [ "$RESTART_ON_WAN_FAIL" != 1 ]; then
    note "Still not routed; the WAN address fails too, not restarting the WAN"
    exit 0
  fi

  now=$(date +%s)
  last=$(read_time "$STAMP_FILE")
  tries=$(read_time "$TRIES_FILE")
  gap=$(restart_interval "$tries")
  if [ $((now - last)) -lt "$gap" ]; then
    note "Still not routed; last WAN restart $(( (now - last) / 60 )) min ago, the next one $((gap / 60)) min after it"
    exit 0
  fi

  echo "$now" > "$STAMP_FILE"
  echo $((tries + 1)) > "$TRIES_FILE"
  log "Still not routed: restarting the WAN"
  service restart_wan
  sleep "$RESTART_WAIT"

  new=$(global_addr "$LAN_IF")
  if [ -z "$new" ]; then
    log "After the WAN restart: no global address on $LAN_IF"
    exit 0
  fi
  if [ "$new" != "$old" ]; then
    echo "$new" > "$STATE_FILE"
    msg="After the WAN restart: new prefix ${old:+$old -> }$new"
  else
    msg="After the WAN restart: same prefix $new"
  fi
  if routed "$new"; then
    recovered "$msg, routed"
  else
    log "$msg, still not routed"
  fi
}

cmd_check() {
  echo "v6watch $VERSION"
  src=$(global_addr "$LAN_IF")
  if [ -z "$src" ]; then
    echo "No global IPv6 address on $LAN_IF"
    exit 1
  fi
  echo "LAN address: $src ($LAN_IF)"
  w=$(wan_if)
  wa=
  [ -n "$w" ] && wa=$(global_addr "$w")
  echo "WAN address: ${wa:-none} (${w:-no IPv6 default route})"
  rc=1
  for t in $TARGETS; do
    if ping_from "$src" "$t"; then
      echo "  $t: reply"
      rc=0
    else
      echo "  $t: no reply"
    fi
  done
  if [ $rc -eq 0 ]; then
    echo "Delegated prefix is routed"
  else
    echo "Delegated prefix is NOT routed ($(wan_status))"
  fi
  exit $rc
}

case ${1:-run} in
  run) cmd_run ;;
  check) cmd_check ;;
  cron) cru a v6watch "$CRON_SCHEDULE $ADDON_DIR/v6watch.sh run" ;;
  uncron) cru d v6watch ;;
  version) echo "v6watch $VERSION" ;;
  *) echo "Usage: $0 [run|check|cron|uncron|version]" >&2; exit 2 ;;
esac
