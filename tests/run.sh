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
# cru: the job lives in $SC/cron, in the format "cru l" prints
stub cru 'case $1 in
  l) cat "$SC/cron" 2>/dev/null ;;
  a) echo "$3 #$2#" > "$SC/cron" ;;
  d) : > "$SC/cron" ;;
esac; exit 0'
# date: the hour and the day come from $SC/hm and $SC/day when they exist
stub date 'case $1 in
  +%H%M) [ -f "$SC/hm" ] && { cat "$SC/hm"; exit 0; } ;;
  +%Y%m%d) [ -f "$SC/day" ] && { cat "$SC/day"; exit 0; } ;;
esac
PATH="$REAL_PATH" exec date "$@"'
export REAL_PATH=$PATH
NOW=100000   # router uptime, in seconds, during the tests

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
  echo "$NOW.42 345678.90" > "$SC/uptime"
  mkdir -p "$SC/net/br0" "$SC/net/eth1"
  cat > "$SC/conf" <<EOF
LOG_FILE=$SC/log
STATE_FILE=$SC/state
STAMP_FILE=$SC/last
FAIL_FILE=$SC/fail
COUNT_FILE=$SC/count
TRIES_FILE=$SC/tries
LOCK_DIR=$SC/lock
DAY_FILE=$SC/daily
STATUS_FILE=$SC/status
UPTIME_FILE=$SC/uptime
NET_DIR=$SC/net
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
ago() { echo $((NOW - $1)) > "$SC/last"; }   # last WAN restart $1 s ago

ok() { # description, actual, expected
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: got '$2', expected '$3'"
    fails=$((fails + 1))
  fi
}
contains() { # description, text, fixed string
  total=$((total + 1))
  case $2 in
    *"$3"*) echo "  ok   $1" ;;
    *) echo "  FAIL $1: '$3' not in the output:"; printf '%s\n' "$2" | sed 's/^/         /'
       fails=$((fails + 1)) ;;
  esac
}
# Feeds keys to the menu, one per line, and captures what it prints
menu() { printf '%s\n' "$@" | v6 menu; }
count() { printf '%s\n' "$1" | grep -c -- "$2"; }
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
  reset; mkdir "$SC/lock"; echo $$ > "$SC/lock/pid"; echo $((NOW - 60)) > "$SC/lock/since"
  prefix_dead; run
  ok "skips while another run is alive" "$(renews)" 0
  echo $((NOW - 1000)) > "$SC/lock/since"; run
  ok "takes over a lock older than any run (reused PID)" "$(renews)" 1
  mkdir "$SC/lock"; echo 999999 > "$SC/lock/pid"; echo "$NOW" > "$SC/lock/since"; run
  ok "takes over the lock of a dead process" "$(renews)" 2
  ok "lock released" "$(exists lock)" no

  echo "uptime clock"
  reset; run; prefix_dead
  echo 1762940000 > "$SC/last"; echo 1762940000 > "$SC/fail"; run; run
  ok "clock time of an older version is ignored" "$(restarts)" 1
  all_good; run
  has "outage measured from 0, not negative" log "routed again (outage lasted"
  ok "no negative duration" "$(grep -c 'lasted -' "$SC/log")" 0
  reset; run; prefix_dead; run; echo "$((NOW + 600)).00 0" > "$SC/uptime"; all_good; run
  has "duration from uptime" log "routed again (outage lasted 10 min)"

  echo "daily check"
  reset; sed -i '/^DAILY_CHECK=/d' "$SC/conf"; echo 20261112 > "$SC/day"
  echo 1159 > "$SC/hm"; run
  ok "not before DAILY_CHECK" "$(grep -c 'Daily check' "$SC/log")" 0
  echo 1203 > "$SC/hm"; run
  has "first good run after it" log "Daily check: $LAN routed (router uptime 27h)"
  echo 1208 > "$SC/hm"; run
  ok "once a day" "$(grep -c 'Daily check' "$SC/log")" 1
  echo 20261113 > "$SC/day"; echo 0005 > "$SC/hm"; run
  ok "next day, before the hour: nothing" "$(grep -c 'Daily check' "$SC/log")" 1
  echo 1200 > "$SC/hm"; run
  ok "next day, at the hour" "$(grep -c 'Daily check' "$SC/log")" 2
  reset; sed -i '/^DAILY_CHECK=/d' "$SC/conf"; echo 19700101 > "$SC/day"; echo 1300 > "$SC/hm"; run
  ok "clock not set yet: skipped" "$(grep -c 'Daily check' "$SC/log")" 0
  reset; echo 20261112 > "$SC/day"; echo 2359 > "$SC/hm"; run
  ok "DAILY_CHECK empty: never" "$(grep -c 'Daily check' "$SC/log")" 0

  echo "invalid settings"
  reset
  printf 'PING_COUNT=two\nFAIL_THRESHOLD=0\nRESTART_ON_WAN_FAIL=yes\nDAILY_CHECK=25:00\nRESTART_MIN_INTERVAL=\n' >> "$SC/conf"
  run; prefix_dead; run
  has "PING_COUNT reported" syslog "Invalid PING_COUNT='two'"
  has "FAIL_THRESHOLD reported" syslog "Invalid FAIL_THRESHOLD='0'"
  has "RESTART_ON_WAN_FAIL reported" syslog "Invalid RESTART_ON_WAN_FAIL='yes'"
  has "DAILY_CHECK reported" syslog "Invalid DAILY_CHECK='25:00'"
  has "empty number reported" syslog "Invalid RESTART_MIN_INTERVAL=''"
  ok "defaults used: no restart at check 1" "$(restarts)" 0
  run
  ok "defaults used: restart at check 2" "$(restarts)" 1
  reset
  printf 'PING_TIMEOUT=03
CRON_SCHEDULE="*/5 * *"
TARGETS="2001:db8::1,2001:db8::2"
LAN_IF="br0; reboot"
' >> "$SC/conf"
  run
  has "leading zero reported" syslog "Invalid PING_TIMEOUT='03'"
  has "short cron schedule reported" syslog "Invalid CRON_SCHEDULE='*/5 * *'"
  has "targets with a comma reported" syslog "Invalid TARGETS='2001:db8::1,2001:db8::2'"
  has "odd interface name reported" syslog "Invalid LAN_IF='br0; reboot'"
  ok "and the defaults work" "$(renews)$(restarts)" 00
  reset; printf 'TARGETS="2001:db8::1  one.one.one.one"
CRON_SCHEDULE="0,30 1-5 * * 1"
RENEW_WAIT=0
' >> "$SC/conf"; run
  ok "valid unusual values accepted" "$(grep -c Invalid "$SC/syslog")" 0

  echo "syntax error in the config"
  # Only "version", which writes nothing: the test paths are in the broken file too
  reset; echo 'TARGETS="2001:db8::1' >> "$SC/conf"
  ok "the script still starts" "$(v6 version)" "v6watch $(sed -n 's/^VERSION=//p' "$SCRIPT")"
  has "and says why it uses the defaults" syslog "Syntax error in $SC/conf, using the defaults"

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

  echo "menu"
  reset; run
  out=$(menu q); rc=$?
  ok "q quits" "$rc" 0
  contains "banner and version" "$out" "IPv6 prefix delegation watchdog - v"
  contains "monitoring paused without the cru job" "$out" "PAUSED"
  contains "last check from the status file" "$out" "Last check   routed"
  contains "last event from the log" "$out" "Watching LAN prefix: $LAN"
  ok "no color codes outside a terminal" "$(count "$out" "$(printf '\033')")" 0
  out=$(printf '' | v6 menu); rc=$?
  ok "end of input quits" "$rc" 0
  out=$(menu x q)
  ok "unknown key: menu shown again" "$(count "$out" "Choose:")" 2

  out=$(menu 4 '' q)
  contains "option 4 resumes" "$out" "Monitoring resumed."
  has "cru job created" cron "#v6watch#"
  contains "then shown as ON" "$(menu q)" "ON, every 5 minutes"
  out=$(menu 4 '' q)
  contains "option 4 pauses" "$out" "Monitoring paused."
  ok "cru job removed" "$(lines cron)" 0

  out=$(menu 1 '' q)
  contains "option 1 runs check" "$out" "Delegated prefix is routed"
  ok "the menu survives the check" "$(count "$out" "Choose:")" 2
  ok "the check changes nothing" "$(renews)$(restarts)" 00

  prefix_dead; run
  contains "failed run shown" "$(menu q)" "Last check   NOT routed"
  all_good; out=$(menu 1 '' q)
  ok "a check from the menu updates the last check" "$(count "$out" "Last check   routed")" 1
  prefix_dead; v6 check >/dev/null
  contains "and so does check from the command line" "$(menu q)" "Last check   NOT routed"
  echo "ok garbage" > "$SC/status"
  contains "bad status file" "$(menu q)" "routed (unknown time)"
  echo "ok $((NOW + 1000))" > "$SC/status"
  contains "time after the uptime: unknown" "$(menu q)" "routed (unknown time)"
  echo "ok 1000" > "$SC/status"; echo "260000.00 0" > "$SC/uptime"
  contains "old check shown in whole days" "$(menu q)" "routed (2 days ago)"
  echo "$NOW.42 0" > "$SC/uptime"
  echo "ok $((NOW - 7300))" > "$SC/status"
  contains "recent one in hours" "$(menu q)" "routed (2 h ago)"
  run
  out=$(menu 2 '' q)
  contains "option 2 shows the log" "$out" "not routed (WAN address $WAN works)"

  echo FAIL_THRESHOLD=3 >> "$SC/conf"
  out=$(menu 3 '' q)
  ok "option 3 marks a changed setting" "$(printf '%s\n' "$out" | grep FAIL_THRESHOLD | grep -c "(default: 2)")" 1
  ok "and not an unchanged one" "$(printf '%s\n' "$out" | grep PING_COUNT | grep -c "(default:")" 0
  contains "unchanged ones are listed too" "$out" "PING_COUNT"

  echo "settings editor"
  # The shipped config under the test lines: the editor must keep its comments
  reset; cat "$ROOT/v6watch.conf" >> "$SC/conf"; cp "$SC/conf" "$SC/orig"
  out=$(menu 3 7 3 '' q)
  contains "asks with the help" "$out" "FAIL_THRESHOLD - consecutive failed checks before a WAN restart"
  contains "shows current and default" "$out" "Current: 2   Default: 2"
  contains "saved" "$out" "Saved: FAIL_THRESHOLD = 3"
  ok "active line under the commented one" "$(grep -A1 '^#FAIL_THRESHOLD=2' "$SC/conf" | tail -n 1)" "FAIL_THRESHOLD=3"
  ok "the list after it shows the new value" "$(printf '%s\n' "$out" | grep FAIL_THRESHOLD | grep -c "3  (default: 2)")" 1
  ok "backup of the previous file" "$(cmp -s "$SC/conf.bak" "$SC/orig" && echo same)" same
  ok "no temporary file left" "$(exists conf.new)" no
  prefix_dead; run; run
  ok "the watchdog uses it: no restart at check 2" "$(restarts)" 0
  run
  ok "restart at check 3" "$(restarts)" 1
  menu 3 7 5 '' q >/dev/null
  ok "replaced, not added" "$(grep -c '^FAIL_THRESHOLD=' "$SC/conf")" 1
  ok "with the new value" "$(grep '^FAIL_THRESHOLD=' "$SC/conf")" "FAIL_THRESHOLD=5"
  out=$(menu 3 7 d '' q)
  contains "back to the default" "$out" "Saved: FAIL_THRESHOLD = 2"
  ok "the file is the shipped one again, byte for byte" "$(cmp -s "$SC/conf" "$SC/orig" && echo same)" same

  out=$(menu 3 2 '2001:db8::1 2001:db8::2' '' q)
  ok "values with spaces are quoted" "$(grep '^TARGETS=' "$SC/conf")" 'TARGETS="2001:db8::1 2001:db8::2"'
  contains "and read back" "$(menu 3 '' q)" '2001:db8::1 2001:db8::2  (default:'
  menu 3 2 d '' q >/dev/null

  out=$(menu 3 3 two 0 07 '' '' q)
  ok "invalid values refused, asked again" "$(count "$out" "Not valid: a whole number, 1 or more")" 3
  contains "Enter keeps the value" "$out" "Unchanged."
  ok "file untouched" "$(cmp -s "$SC/conf" "$SC/orig" && echo same)" same
  menu 3 2 '$(touch "$SC/pwned")' '`touch $SC/pwned`' 'a"b' '' '' q >/dev/null
  ok "shell code refused" "$(exists pwned)" no
  ok "file still untouched" "$(cmp -s "$SC/conf" "$SC/orig" && echo same)" same
  out=$(menu 3 1 eth9 eth1 '' q)
  contains "unknown interface refused" "$out" "There is no interface named eth9"
  ok "known one saved" "$(grep '^LAN_IF=' "$SC/conf")" "LAN_IF=eth1"
  out=$(menu 3 99 x '' q)
  ok "no such number" "$(count "$out" "There is no setting number")" 2
  out=$(menu 3 '' q)
  contains "read-only paths listed" "$out" "LOG_FILE"
  ok "and not numbered" "$(printf '%s\n' "$out" | grep LOG_FILE | grep -c '\[')" 0

  echo "settings editor: odd config files"
  reset; sed -i '/^DAILY_CHECK=/d' "$SC/conf"
  menu 3 11 off '' q >/dev/null
  ok "DAILY_CHECK off: an empty value" "$(grep '^DAILY_CHECK' "$SC/conf")" "DAILY_CHECK="
  ok "added at the end, no commented line to go under" "$(tail -n 1 "$SC/conf")" "DAILY_CHECK="
  menu 3 11 d '' q >/dev/null
  ok "reset without a commented line leaves one" "$(grep '^#*DAILY_CHECK' "$SC/conf")" "#DAILY_CHECK=1200"
  printf 'PING_COUNT=4\nPING_COUNT=5\n' >> "$SC/conf"
  menu 3 3 6 '' q >/dev/null
  ok "duplicates merged into one line" "$(grep -c '^PING_COUNT=' "$SC/conf")" 1
  ok "with the new value" "$(grep '^PING_COUNT=' "$SC/conf")" "PING_COUNT=6"
  printf '  RESTART_WAIT=5  # mine\n' >> "$SC/conf"
  menu 3 6 7 '' q >/dev/null
  ok "indented lines found too" "$(grep -c 'RESTART_WAIT=' "$SC/conf")" 1
  rm -f "$SC/conf.bak"; echo 'true && PING_COUNT=9' >> "$SC/conf"; cp "$SC/conf" "$SC/orig"
  out=$(menu 3 3 2 '' q)
  contains "a later line that would undo it: not saved" "$out" "Could not save"
  ok "file untouched" "$(cmp -s "$SC/conf" "$SC/orig" && echo same)" same
  ok "no backup either" "$(exists conf.bak)$(exists conf.new)" nono
  reset; printf '3\n7\n' | v6 menu >/dev/null; rc=$?
  ok "end of input while editing quits" "$rc" 0

  echo "settings editor: the cron schedule"
  reset; menu 4 '' q >/dev/null
  out=$(menu 3 12 '*/10 * * * *' '' q)
  contains "the cru job follows" "$out" "The cru job now runs at: */10 * * * *"
  has "cru job updated" cron "*/10 * * * * "
  ok "saved quoted" "$(grep '^CRON_SCHEDULE=' "$SC/conf")" 'CRON_SCHEDULE="*/10 * * * *"'
  contains "status panel shows it" "$(menu q)" 'ON (*/10 * * * *)'
  menu 4 '' q >/dev/null
  menu 3 12 d '' q >/dev/null
  ok "paused: the job is not created" "$(lines cron)" 0
  out=$(menu 3 12 '*/10 * *' '' '' q)
  contains "short schedule refused" "$out" "Not valid: 5 cron fields"

  reset; rm -f "$SC/log"
  contains "empty log" "$(menu 2 '' q)" "The log is empty"
  reset; : > "$SC/lan"
  contains "no LAN address" "$(menu q)" "no global address"
  contains "no check since boot" "$(menu q)" "none since boot"

  reset; prefix_dead; run; v6 < /dev/null
  ok "no command and no terminal: a run, not the menu" "$(renews)" 2

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
