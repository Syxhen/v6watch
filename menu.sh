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
  s=$(( $(now_s) - $1 ))
  if [ "$s" -lt 120 ]; then echo "$s s ago"
  elif [ "$s" -lt 7200 ]; then echo "$((s / 60)) min ago"
  else echo "$((s / 3600)) h ago"
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
  item 3 "Show the settings"
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

# Every setting with its current value; the ones changed in the config are marked
show_settings() {
  printf '%sSettings%s (edit %s, comments explain each one)\n\n' "$BOLD" "$OFF" "$CONF"
  for n in $SETTINGS; do
    v='' def=''
    eval "v=\$$n def=\$default_$n"
    if [ "$v" = "$def" ]; then
      printf '  %-22s %s\n' "$n" "$v"
    else
      printf '  %-22s %s%s%s  %s(default: %s)%s\n' "$n" "$YELLOW" "$v" "$OFF" "$DIM" "$def" "$OFF"
    fi
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
      3) show_settings; pause ;;
      4) toggle_monitoring; pause ;;
      q|Q) exit 0 ;;
    esac
  done
}
