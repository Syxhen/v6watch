#!/bin/bash
# Scenario tests for v6watch.sh.
#
# The router commands (ip, ping6, pidof, killall, service, logger, sleep) are
# replaced by stubs driven by files in a scratch directory, and every path the
# script writes to is moved there through a test config, so the tests touch
# nothing outside it and never sleep.
#
# Usage: tests/run.sh [shell...]
#   The shells v6watch.sh is run with, e.g. dash or "busybox sh"
#   (default: sh). The harness itself needs bash.
#
# Copyright (C) 2026 Syxhen
# SPDX-License-Identifier: GPL-3.0-or-later

# The stub bodies are single-quoted on purpose: they expand when the stubs run
# shellcheck disable=SC2016

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$ROOT/v6watch.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export SC=$WORK/sc
STUBS=$WORK/stubs
mkdir -p "$STUBS"

LAN=2001:db8:0:1::1
LAN2=2001:db8:0:2::1
WAN=2001:db8:ffff::2

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }
stub ip 'case "$*" in
  *"route show default"*) [ -f "$SC/noroute" ] || echo "default via fe80::1 dev wan0 proto ra metric 1024" ;;
  *"dev br0"*) a=$(cat "$SC/lan" 2>/dev/null); [ -n "$a" ] && echo "    inet6 $a/64 scope global dynamic" ;;
  *"dev wan0"*) a=$(cat "$SC/wan" 2>/dev/null); [ -n "$a" ] && echo "    inet6 $a/128 scope global dynamic" ;;
esac; exit 0'
stub ping6 'while [ $# -gt 0 ]; do [ "$1" = -I ] && src=$2; shift; done; grep -qxF "$src" "$SC/good" 2>/dev/null'
stub pidof '[ -f "$SC/odhcp6c" ]'
stub killall 'echo renew >> "$SC/calls"; [ -f "$SC/on_renew" ] && . "$SC/on_renew"; exit 0'
stub service 'echo "$*" >> "$SC/calls"; [ -f "$SC/on_restart" ] && . "$SC/on_restart"; exit 0'
stub logger 'shift 2; echo "$*" >> "$SC/syslog"'
stub sleep 'exit 0'

total=0
fails=0

# Fresh scenario: prefix and WAN address both routed, odhcp6c running
reset() {
  rm -rf "$SC"
  mkdir -p "$SC"
  : > "$SC/calls"; : > "$SC/syslog"; : > "$SC/log"
  touch "$SC/odhcp6c"
  echo "$LAN" > "$SC/lan"
  echo "$WAN" > "$SC/wan"
  printf '%s\n%s\n' "$LAN" "$WAN" > "$SC/good"
  cat > "$SC/conf" <<EOF
LOG_FILE=$SC/log
STATE_FILE=$SC/state
STAMP_FILE=$SC/last
FAIL_FILE=$SC/fail
COUNT_FILE=$SC/count
TRIES_FILE=$SC/tries
LOCK_DIR=$SC/lock
RENEW_WAIT=0
RESTART_WAIT=0
DAILY_CHECK=
EOF
}
v6() { PATH="$STUBS:$PATH" V6WATCH_CONF="$SC/conf" $SH "$SCRIPT" "$@"; }
run() { v6 run; }
restarts() { grep -c restart_wan "$SC/calls"; }
renews() { grep -c renew "$SC/calls"; }
lines() { grep -c . "$SC/$1"; }
exists() { if [ -e "$SC/$1" ]; then echo yes; else echo no; fi; }
prefix_dead() { echo "$WAN" > "$SC/good"; }
all_dead() { : > "$SC/good"; }
all_good() { printf '%s\n%s\n' "$LAN" "$WAN" > "$SC/good"; }
ago() { echo $(( $(date +%s) - $1 )) > "$SC/last"; }   # last WAN restart $1 s ago

ok() { # description, actual, expected
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: got '$2', expected '$3'"
    fails=$((fails + 1))
  fi
}
has() { # description, file, fixed string
  total=$((total + 1))
  if grep -qF -- "$3" "$SC/$2"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: '$3' not in $2:"
    sed 's/^/         /' "$SC/$2"
    fails=$((fails + 1))
  fi
}

scenarios() {
  echo "healthy prefix"
  reset; run
  ok "no renew" "$(renews)" 0
  ok "no restart" "$(restarts)" 0
  has "first run logged" log "Watching LAN prefix: $LAN"
  run
  ok "nothing more logged" "$(lines log)" 1

  echo "one-check glitch: renew only, no restart"
  reset; run; prefix_dead; run
  ok "one renew" "$(renews)" 1
  ok "no restart" "$(restarts)" 0
  has "failure in log" log "not routed (WAN address $WAN works): trying a DHCPv6 renew"
  has "threshold note" syslog "failed check 1 of 2"
  all_good; run
  ok "still no restart" "$(restarts)" 0
  has "recovery logged" log "routed again (outage lasted"
  ok "outage state cleared" "$(exists fail)$(exists count)$(exists tries)" nonono

  echo "renew fixes it"
  reset; run; prefix_dead
  echo "echo $LAN >> \"\$SC/good\"" > "$SC/on_renew"; run
  ok "no restart" "$(restarts)" 0
  has "renew worked" log "Renew worked: $LAN routed again"

  echo "persistent failure: restart at the second check, new prefix"
  reset; run; prefix_dead; run
  ok "no restart after check 1" "$(restarts)" 0
  echo "echo $LAN2 > \"\$SC/lan\"; echo $LAN2 >> \"\$SC/good\"" > "$SC/on_restart"; run
  ok "restart after check 2" "$(restarts)" 1
  has "restart result" log "After the WAN restart: new prefix $LAN -> $LAN2, routed (outage lasted"
  ok "state file" "$(cat "$SC/state")" "$LAN2"
  ok "repeated failure only in syslog" "$(grep -c 'trying a DHCPv6 renew' "$SC/log")" 1

  echo "backoff: 1h, 2h, 4h... capped at RESTART_MAX_INTERVAL"
  reset; run; prefix_dead; run; run
  ok "restart 1" "$(restarts)" 1
  run;           ok "rate limited right after" "$(restarts)" 1
  ago 3500; run; ok "3500 s: still waiting" "$(restarts)" 1
  ago 3700; run; ok "3700 s: restart 2" "$(restarts)" 2
  ago 3700; run; ok "3700 s after #2: waiting for 2 h" "$(restarts)" 2
  has "note shows 120 min" syslog "the next one 120 min after it"
  ago 7300; run; ok "7300 s: restart 3" "$(restarts)" 3
  ago 7300; run; ok "7300 s after #3: waiting for 4 h" "$(restarts)" 3
  ago 14500; run; ok "14500 s: restart 4" "$(restarts)" 4
  echo 9 > "$SC/tries"
  ago 86000; run; ok "cap: 86000 s still waits" "$(restarts)" 4
  ago 86500; run; ok "cap: 86500 s restarts" "$(restarts)" 5

  echo "recovery resets the backoff"
  all_good; run
  ok "tries cleared" "$(exists tries)" no
  : > "$SC/calls"; prefix_dead; run; run; ago 3700; run
  ok "next outage restarts after 1 h again" "$(restarts)" 1

  echo "WAN address fails too"
  reset; run; all_dead; run; run
  ok "default: restart" "$(restarts)" 1
  has "log tells it apart" log "WAN address $WAN fails too"
  reset; echo RESTART_ON_WAN_FAIL=0 >> "$SC/conf"; run; all_dead; run; run; run
  ok "RESTART_ON_WAN_FAIL=0: no restart" "$(restarts)" 0
  ok "renews go on" "$(renews)" 3
  has "note" syslog "the WAN address fails too, not restarting the WAN"
  prefix_dead; run
  ok "prefix-only failure still restarts" "$(restarts)" 1

  echo "no address on the LAN"
  reset; run; : > "$SC/lan"; run
  has "logged" log "No usable global address on br0"
  ok "renew tried" "$(renews)" 1
  ok "no restart yet" "$(restarts)" 0
  echo "echo $LAN > \"\$SC/lan\"" > "$SC/on_restart"; run
  ok "restart at check 2" "$(restarts)" 1
  has "same prefix back" log "After the WAN restart: same prefix $LAN, routed"
  reset; rm "$SC/odhcp6c"; : > "$SC/lan"; run
  ok "without odhcp6c: silent" "$(lines log)" 0
  reset; : > "$SC/lan"; run
  echo "echo $LAN > \"\$SC/lan\"" > "$SC/on_renew"; run
  has "prefix that appears after a renew" log "Renew brought a new prefix: $LAN, routed"

  echo "odhcp6c not running"
  reset; run; prefix_dead; rm "$SC/odhcp6c"; run
  has "says so" syslog "odhcp6c is not running, skipping the renew"
  ok "no renew" "$(renews)" 0

  echo "FAIL_THRESHOLD=1 keeps the 0.1 behaviour"
  reset; echo FAIL_THRESHOLD=1 >> "$SC/conf"; run; prefix_dead; run
  ok "restart at check 1" "$(restarts)" 1

  echo "lock"
  reset; mkdir "$SC/lock"; echo $$ > "$SC/lock/pid"; prefix_dead; run
  ok "skips while another run is alive" "$(renews)" 0
  echo 999999 > "$SC/lock/pid"; run
  ok "takes over a stale lock" "$(renews)" 1
  ok "lock released" "$(exists lock)" no

  echo "check command"
  reset
  out=$(v6 check); rc=$?
  ok "exit 0 when routed" "$rc" 0
  case $out in *"Delegated prefix is routed"*) r=yes ;; *) r=no ;; esac
  ok "says routed" "$r" yes
  prefix_dead
  out=$(v6 check); rc=$?
  ok "exit 1 when not routed" "$rc" 1
  case $out in *"NOT routed (WAN address $WAN works)"*) r=yes ;; *) r=no ;; esac
  ok "says NOT routed, WAN works" "$r" yes
  ok "changes nothing" "$(renews)$(restarts)$(lines log)" 000
  : > "$SC/lan"
  v6 check >/dev/null; rc=$?
  ok "exit 1 without a LAN address" "$rc" 1

  echo "command line"
  reset
  ok "version" "$(v6 version)" "v6watch $(sed -n 's/^VERSION=//p' "$SCRIPT")"
  v6 bogus 2>/dev/null; rc=$?
  ok "unknown command: exit 2" "$rc" 2
}

[ $# -eq 0 ] && set -- sh
for SH in "$@"; do
  echo "=== v6watch.sh under: $SH"
  scenarios
  echo
done

if [ "$fails" -eq 0 ]; then
  echo "All $total checks passed"
else
  echo "$fails of $total checks FAILED"
fi
[ "$fails" -eq 0 ]
