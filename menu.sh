# shellcheck shell=sh
# v6watch interactive menu, sourced by v6watch.sh when it is started by hand
# with no arguments (or with "menu"). It uses the functions and settings that
# v6watch.sh has already loaded; cron never loads this file.
#
# Copyright (C) 2026 Syxhen
# SPDX-License-Identifier: GPL-3.0-or-later

# Colors only when the output is a terminal that wants them: not in a pipe or
# a file, not with NO_COLOR set (https://no-color.org), not on a dumb terminal
setup_colors() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
    esc=$(printf '\033')
    BOLD="${esc}[1m" DIM="${esc}[2m" OFF="${esc}[0m"
    RED="${esc}[31m" GREEN="${esc}[32m" YELLOW="${esc}[33m" CYAN="${esc}[36m"
  else
    BOLD='' DIM='' OFF='' RED='' GREEN='' YELLOW='' CYAN=''
  fi
}

banner() {
  printf '%s' "$CYAN"
  cat <<'EOF'
         __                     _          _
__   __ / /_  __      __  __ _ | |_   ___ | |__
\ \ / /| '_ \ \ \ /\ / / / _` || __| / __|| '_ \
 \ V / | (_) | \ V  V / | (_| || |_ | (__ | | | |
  \_/   \___/   \_/\_/   \__,_| \__| \___||_| |_|
EOF
  printf '%s' "$OFF"
  printf '%s IPv6 prefix delegation watchdog - v%s%s\n\n' "$DIM" "$VERSION" "$OFF"
}

# The cru job is the watchdog: without it nothing runs every 5 minutes
monitoring_on() {
  cru l 2>/dev/null | grep -q '#v6watch#'
}

# "12 min ago" from a time in seconds of uptime
ago() {
  case $1 in ''|*[!0-9]*) echo "unknown time"; return ;; esac
  s=$(( $(now_s) - $1 ))
  if [ "$s" -lt 0 ]; then echo "unknown time"
  elif [ "$s" -lt 120 ]; then echo "$s s ago"
  elif [ "$s" -lt 7200 ]; then echo "$((s / 60)) min ago"
  elif [ "$s" -lt 172800 ]; then echo "$((s / 3600)) h ago"
  else echo "$((s / 86400)) days ago"
  fi
}

status_panel() {
  if monitoring_on; then
    mon="${GREEN}ON${OFF}, every 5 minutes"
    [ "$CRON_SCHEDULE" = "*/5 * * * *" ] || mon="${GREEN}ON${OFF} ($CRON_SCHEDULE)"
  else
    mon="${YELLOW}PAUSED${OFF} until the next reboot or option 4"
  fi

  lan=$(global_addr "$LAN_IF")
  [ -n "$lan" ] || lan="${RED}no global address${OFF}"

  # Written by every run: "ok <uptime>" or "fail <uptime>"
  # shellcheck disable=SC2046  # split on purpose into $1 and $2
  set -- $(cat "$STATUS_FILE" 2>/dev/null)
  case ${1:-} in
    ok) last="${GREEN}routed${OFF} ($(ago "$2"))" ;;
    fail) last="${RED}NOT routed${OFF} ($(ago "$2"))" ;;
    *) last="${DIM}none since boot${OFF}" ;;
  esac

  event=$(tail -n 1 "$LOG_FILE" 2>/dev/null)

  printf '  %-12s %s\n' "Monitoring" "$mon" "LAN address" "$lan ($LAN_IF)" "Last check" "$last"
  [ -n "$event" ] && printf '  %-12s %s%s%s\n' "Last event" "$DIM" "$event" "$OFF"
  echo
}

# One menu line: the key in bold color, then the label
item() {
  printf '  %s[%s]%s %s\n' "$BOLD$CYAN" "$1" "$OFF" "$2"
}

menu_items() {
  item 1 "Check the prefix now"
  item 2 "Show the log"
  item 3 "Settings"
  if monitoring_on; then item 4 "Pause monitoring"; else item 4 "Resume monitoring"; fi
  item q "Quit"
  echo
}

# Waits for Enter; end of input (Ctrl-D, or a pipe that ran dry) quits
pause() {
  printf '\n%sPress Enter to go back%s ' "$DIM" "$OFF"
  read -r _ || exit 0
}

# The last lines of the persistent log, colored by what happened
show_log() {
  if [ ! -s "$LOG_FILE" ]; then
    echo "The log is empty: nothing has happened yet."
    return
  fi
  printf '%sLast 20 lines of %s%s\n\n' "$BOLD" "$LOG_FILE" "$OFF"
  tail -n 20 "$LOG_FILE" | awk -v red="$RED" -v yellow="$YELLOW" -v green="$GREEN" -v off="$OFF" '
    /not routed|no global address|No usable/ { print red $0 off; next }
    /restarting the WAN|prefix changed/      { print yellow $0 off; next }
    /routed again|, routed|Renew worked/      { print green $0 off; next }
                                              { print }'
}

# The settings the menu can change, in the order of the config file. The two
# paths are left to the config file: a wrong one breaks the log or the state
EDITABLE="LAN_IF TARGETS PING_COUNT PING_TIMEOUT RENEW_WAIT RESTART_WAIT FAIL_THRESHOLD RESTART_MIN_INTERVAL RESTART_MAX_INTERVAL RESTART_ON_WAN_FAIL DAILY_CHECK CRON_SCHEDULE LOG_LINES"

# What a setting does and what it accepts, in $help and $rule
about() {
  case $1 in
    LAN_IF) help="LAN interface that carries the delegated prefix"
            rule="an interface name, like br0" ;;
    TARGETS) help="hosts pinged from the delegated prefix; one reply is enough"
             rule="IPv6 addresses or host names, separated by spaces" ;;
    PING_COUNT) help="pings sent to each target"
                rule="a whole number, 1 or more" ;;
    PING_TIMEOUT) help="seconds to wait for a reply"
                  rule="a whole number, 1 or more" ;;
    RENEW_WAIT) help="seconds to wait after a DHCPv6 renew before checking again"
                rule="seconds, 0 or more" ;;
    RESTART_WAIT) help="seconds to wait after a WAN restart before checking again"
                  rule="seconds, 0 or more" ;;
    FAIL_THRESHOLD) help="consecutive failed checks before a WAN restart"
                    rule="a whole number, 1 or more" ;;
    RESTART_MIN_INTERVAL) help="minimum seconds between two WAN restarts"
                          rule="seconds, 0 or more" ;;
    RESTART_MAX_INTERVAL) help="longest wait between WAN restarts: it doubles after each one that does not help"
                          rule="seconds, 0 or more" ;;
    RESTART_ON_WAN_FAIL) help="restart the WAN also when the router's own WAN address fails too"
                         rule="1 (yes) or 0 (no)" ;;
    DAILY_CHECK) help="time of the daily \"prefix still works\" log entry"
                 rule="a time as HHMM, like 1200, or off" ;;
    CRON_SCHEDULE) help="when the check runs, in cron format"
                   rule="5 cron fields, like */5 * * * *" ;;
    LOG_LINES) help="lines kept in the persistent log"
               rule="a whole number, 1 or more" ;;
  esac
}

# A value as the list shows it
shown() {
  if [ -n "$1" ]; then echo "$1"; else echo "(none)"; fi
}

# The config line that sets $1 to $2: quoted only when it has to be
conf_line() {
  case $2 in
    *[!A-Za-z0-9._:/-]*) printf '%s="%s"\n' "$1" "$2" ;;
    *) printf '%s=%s\n' "$1" "$2" ;;
  esac
}

# Succeeds if the shell, reading file $1 on top of the defaults, gets value $3
# for setting $2. In a subshell, so the menu's own settings stay as they are
reads_back() {
  (
    eval "$2=\$default_$2"
    # shellcheck source=/dev/null
    . "$1" >/dev/null 2>&1
    eval "[ \"\$$2\" = \"\$3\" ]"
  )
}

# Saves setting $1 in $CONF: line $2 replaces its active line or, with $2
# empty, the setting goes back to its default. $3 is the value expected after.
# The new file is written next to the old one and checked first, then renamed
# over it: a rename is atomic, so a power cut leaves either the old file or the
# new one, never half of it. The previous version is kept as $CONF.bak
write_setting() {
  [ -f "$CONF" ] || : > "$CONF" || return 1
  eval "def=\$default_$1"
  # Two passes over the file: the first one only looks for the lines of the
  # setting, an active one (NAME=) and a commented one (#NAME=)
  if awk -v n="$1" -v line="$2" -v commented="#$(conf_line "$1" "$def")" '
       BEGIN { act = "^[ \t]*" n "="; com = "^#[ \t]*" n "=" }
       FNR == NR { if ($0 ~ act) hasact = 1; else if ($0 ~ com) hascom = 1; next }
       $0 ~ act {
         # The first active line is replaced; a later one would win, so it goes
         if (!done) { if (line != "") print line; else if (!hascom) print commented }
         done = 1; next
       }
       { print }
       # No active line yet: the new one goes under the commented one...
       line != "" && !hasact && !done && $0 ~ com { print line; done = 1 }
       # ...or, without that either, at the end
       END { if (line != "" && !done) print line }
     ' "$CONF" "$CONF" > "$CONF.new" &&
     reads_back "$CONF.new" "$1" "$3" &&
     cp "$CONF" "$CONF.bak" &&
     mv "$CONF.new" "$CONF"; then
    return 0
  fi
  rm -f "$CONF.new"
  return 1
}

# One row of the settings list: key ($1, may be empty), name, value, and the
# default when the value is not the default
setting_row() {
  v='' def=''
  eval "v=\$$2 def=\$default_$2"
  if [ -n "$1" ]; then key="[$1]"; else key=''; fi
  if [ "$v" = "$def" ]; then
    printf '  %s%5s%s %-22s %s\n' "$BOLD$CYAN" "$key" "$OFF" "$2" "$(shown "$v")"
  else
    printf '  %s%5s%s %-22s %s%s%s  %s(default: %s)%s\n' "$BOLD$CYAN" "$key" "$OFF" "$2" \
      "$YELLOW" "$(shown "$v")" "$OFF" "$DIM" "$(shown "$def")" "$OFF"
  fi
}

show_settings() {
  printf '%sSettings%s, saved in %s\n\n' "$BOLD" "$OFF" "$CONF"
  i=0
  for n in $EDITABLE; do
    i=$((i + 1))
    setting_row "$i" "$n"
  done
  printf '\n  %sChanged only by editing the file:%s\n' "$DIM" "$OFF"
  setting_row '' LOG_FILE
  setting_row '' STATE_FILE
}

# The $1-th word of the rest of the arguments, if there is one
nth() {
  case $1 in ''|0*|*[!0-9]*) return 1 ;; esac
  i=$1
  shift
  [ "$i" -le $# ] || return 1
  eval "echo \"\${$i}\""
}

edit_setting() {
  about "$1"
  cur='' def=''
  eval "cur=\$$1 def=\$default_$1"
  printf '\n%s%s%s - %s\n' "$BOLD" "$1" "$OFF" "$help"
  printf '  Current: %s   Default: %s\n' "$(shown "$cur")" "$(shown "$def")"
  printf '  Allowed: %s\n\n' "$rule"
  while :; do
    printf 'New value (Enter: keep, d: back to the default): '
    read -r new || exit 0
    case $new in
      '') echo "Unchanged."; return ;;
      d|D) new=$def line='' ;;
      *)
        [ "$1" = DAILY_CHECK ] && [ "$new" = off ] && new=''
        if ! valid_setting "$1" "$new"; then
          printf '%sNot valid:%s %s\n' "$RED" "$OFF" "$rule"
          continue
        fi
        if [ "$1" = LAN_IF ] && [ -d "$NET_DIR" ] && [ ! -e "$NET_DIR/$new" ]; then
          printf '%sThere is no interface named %s%s\n' "$RED" "$new" "$OFF"
          continue
        fi
        line=$(conf_line "$1" "$new") ;;
    esac
    if ! write_setting "$1" "$line" "$new"; then
      printf '%sCould not save %s: nothing was changed%s\n' "$RED" "$CONF" "$OFF"
      return
    fi
    eval "$1=\$new"
    printf '%sSaved:%s %s = %s, from the next check\n' "$GREEN" "$OFF" "$1" "$(shown "$new")"
    # The schedule lives in the cru job, not in the checks: update it now
    if [ "$1" = CRON_SCHEDULE ] && monitoring_on; then
      cru a v6watch "$CRON_SCHEDULE $ADDON_DIR/v6watch.sh run"
      echo "The cru job now runs at: $CRON_SCHEDULE"
    fi
    return
  done
}

# The settings list, until Enter on an empty line
edit_settings() {
  while :; do
    show_settings
    printf '\n%sNumber to change, Enter to go back:%s ' "$BOLD" "$OFF"
    read -r pick || exit 0
    [ -n "$pick" ] || return 0
    # shellcheck disable=SC2086  # one argument per setting
    if name=$(nth "$pick" $EDITABLE); then
      edit_setting "$name"
    else
      echo "There is no setting number $pick."
    fi
    echo
  done
}

toggle_monitoring() {
  if monitoring_on; then
    cru d v6watch
    echo "Monitoring paused. It starts again at the next reboot, or with option 4."
  else
    cru a v6watch "$CRON_SCHEDULE $ADDON_DIR/v6watch.sh run"
    echo "Monitoring resumed."
  fi
}

cmd_menu() {
  setup_colors
  while :; do
    [ -t 1 ] && printf '\033[H\033[2J'   # clear the screen
    banner
    status_panel
    menu_items
    printf '%sChoose:%s ' "$BOLD" "$OFF"
    read -r choice || { echo; exit 0; }
    echo
    case $choice in
      1) (cmd_check); pause ;;   # in a subshell: cmd_check ends with exit
      2) show_log; pause ;;
      3) edit_settings ;;
      4) toggle_monitoring; pause ;;
      q|Q) exit 0 ;;
    esac
  done
}
