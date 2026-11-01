#!/bin/sh
# claude-coffee: keep the Mac awake, lid closed too, while any Claude Code session is mid-turn.
# https://github.com/ivaruf/claude-coffee
#
# usage: claude-coffee.sh on|off   Claude Code hooks (hook JSON on stdin)
#        claude-coffee.sh check    the launch agent, every minute (reads no stdin)
#        claude-coffee.sh status   for you; changes nothing

C=~/.claude/coffee
STALE_MINUTES=30    # drop a marker no hook has touched for this long (Esc never fires Stop)
REMOTE=1            # 0 = no remote mode
REMOTE_MINUTES=60   # remote mode lapses this long after the last hook event and the SSH login
HEAT_GUARD=1        # 0 = never let heat end a turn early
HOT_BATTERY_C=45    # with the lid closed, a battery this hot (°C) means sleep, mid-turn or not
# shellcheck source=/dev/null
[ -f "$C/config" ] && . "$C/config"
D=$C/busy   # one marker file per session that is mid-turn
L=$C/last   # touched on every hook event
H=$C/hot    # the heat guard tripped; stays until the lid opens
mkdir -p "$D"

case $1 in
  on|off) json=$(cat); touch "$L" ;;
  check|status) ;;
  *) echo "usage: ${0##*/} on|off|check|status" >&2; exit 1 ;;   # not 2: that would block a PreToolUse
esac

# printf, not echo: macOS sh's echo expands the \n inside the JSON and jq then rejects it
sid=$(printf '%s\n' "${json:-}" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')
bg=$(printf '%s\n' "${json:-}" | jq '.background_tasks // [] | length' 2>/dev/null)
if [ -n "$sid" ]; then case $1 in
  on)  touch "$D/$sid" ;;
  # Stop with background agents or shells still running: stay awake until they report back
  off) if [ "${bg:-0}" -gt 0 ]; then touch "$D/$sid"; else rm -f "$D/$sid"; fi ;;
esac; fi

[ "$1" = status ] || find "$D" -type f -mmin +"$STALE_MINUTES" -delete
busy=$(find "$D" -type f ! -mmin +"$STALE_MINUTES" | wc -l | tr -d ' ')
want=0; [ "$busy" = 0 ] || want=1

# Remote mode: while you're logged in over SSH (say, from your phone), also stay awake between turns
# so the next prompt can arrive. It lapses REMOTE_MINUTES after the later of the last hook event and
# the login, so a dead or forgotten connection can't keep the Mac up for good. The login is the
# user-owned "sshd-session: you@ttysNNN" (OpenSSH 9.8+) or "sshd: you@ttysNNN" (older); the
# root-owned "[priv]" process has no @.
remote=0
if [ "$REMOTE" = 1 ] && ssh=$(pgrep -u "$(id -u)" -f '^sshd(-session)?: [^ ]+@'); then
  remote=1
  if [ -n "$(find "$L" -mmin -"$REMOTE_MINUTES" 2>/dev/null)" ] ||
     ps -o etime= -p "$(printf '%s' "$ssh" | tr '\n' ,)" | awk -v m="$REMOTE_MINUTES" '
       { n = split($1, t, /[-:]/); if (t[n] + 60*t[n-1] + 3600*t[n-2] + 86400*t[n-3] < m*60) young = 1 }
       END { exit !young }'; then
    remote=2; want=1
  fi
fi

# 2 = the lid is closed and that normally means sleep (no external display keeping the Mac up)
lid=$(ioreg -r -k AppleClamshellState -d 1 | grep -cE '"AppleClamshell(State|CausesSleep)" = Yes')

# Heat guard: a closed Mac that keeps working in a bag can't get rid of its heat. With the lid
# closed, macOS reporting serious thermal pressure or a battery at HOT_BATTERY_C allows sleep and
# sleeps now, even mid-turn. It stays tripped until the lid opens, so a dark wake in the bag can't
# start the heat up again. With the lid open, heat is macOS's own business.
heat() {   # thermal state 0-3 (nominal, fair, serious, critical) and battery °C; neither needs root.
  # The battery's "Temperature" is in 0.1 K (see docs/verification.md); "VirtualTemperature" is a model
  thermal=$(osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSProcessInfo.processInfo.thermalState' 2>/dev/null | tr -cd 0-9)
  battery=$(ioreg -r -n AppleSmartBattery -d 1 | awk '/"Temperature" = / { print int($3 / 10 - 273.15) }')
}
hot=0
if [ "$lid" != 2 ]; then
  [ "$1" = status ] || rm -f "$H"
elif [ -e "$H" ]; then
  hot=1
elif [ "$want" = 1 ] && [ "$HEAT_GUARD" = 1 ] && [ "$1" != status ]; then
  heat
  if [ "${thermal:-0}" -ge 2 ] || [ "${battery:-0}" -ge "$HOT_BATTERY_C" ]; then
    hot=1
    echo "$(date '+%Y-%m-%d %H:%M'), thermal state ${thermal:-?}, battery ${battery:-?} °C" >"$H"
    osascript -e 'display notification "Your Mac got hot with the lid closed, so it went to sleep. Open the lid to carry on." with title "claude-coffee"' >/dev/null 2>&1
  fi
fi
[ "$hot" = 1 ] && want=0

# pmset -g shows "SleepDisabled 1", "SleepDisabled 0", or no line when it is 0: read the value, never the line
have=$(pmset -g | awk '/SleepDisabled/{print $2}')

if [ "$1" = status ]; then
  ok() { if "$@" >/dev/null 2>&1; then echo ok; else echo "missing (run install.sh)"; fi; }
  # -k: with cached credentials "sudo -n" passes for any admin; only a NOPASSWD rule should count
  # shellcheck disable=SC2317  # called through ok()
  nopasswd() { sudo -k -n -l | grep -qE 'NOPASSWD: (ALL$|.*/usr/bin/pmset -a disablesleep 1)'; }
  s=allowed; [ "$have" = 1 ] && s=blocked
  [ "$want" = "${have:-0}" ] || s="$s (the next hook or check flips it)"
  case $remote in
    0) r='off (no SSH login)' ;;
    1) r="lapsed (SSH login, but quiet for $REMOTE_MINUTES min)" ;;
    *) r='on (SSH login)' ;;
  esac
  [ "$REMOTE" = 1 ] || r='disabled in config'
  heat
  case ${thermal:-} in 0) tn=nominal ;; 1) tn=fair ;; 2) tn=serious ;; 3) tn=critical ;; *) tn=unknown ;; esac
  h="battery ${battery:-?} °C, thermal state $tn"
  if [ -e "$H" ]; then g="tripped $(cat "$H"); resets when the lid opens"
  elif [ "$HEAT_GUARD" = 1 ]; then g="armed: lid closed and serious thermal state or battery ${HOT_BATTERY_C} °C → sleep"
  else g='disabled in config'; fi
  printf 'claude-coffee\n'
  printf '  sleep          %s\n' "$s"
  printf '  busy sessions  %s\n' "$busy"
  printf '  remote mode    %s\n' "$r"
  printf '  lid            %s\n' "$(if ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'; then echo closed; else echo open; fi)"
  printf '  heat           %s\n' "$h"
  printf '  heat guard     %s\n' "$g"
  printf '  sudo pmset     %s\n' "$(ok nopasswd)"
  printf '  launch agent   %s\n' "$(ok launchctl print "gui/$(id -u)/com.github.ivaruf.claude-coffee")"
  exit 0
fi

[ "$want" = "${have:-0}" ] || sudo -n /usr/bin/pmset -a disablesleep "$want" >/dev/null

# macOS decides on lid sleep only when the lid closes. If it closed while sleep was disabled,
# re-enabling sleep leaves the Mac awake, so sleep now. Skipped when an external display keeps a
# closed Mac running (AppleClamshellCausesSleep = No).
if [ "$want" = 0 ] && [ "$have" = 1 ] && [ "$lid" = 2 ]; then
  sleep 1
  # Unless it's too hot: a turn may have started during that second (a marker, or another hook's
  # disablesleep 1). Then stay up
  if [ "$hot" = 1 ] || { [ -z "$(ls "$D")" ] && [ "$(pmset -g | awk '/SleepDisabled/{print $2}')" != 1 ]; }; then
    pmset sleepnow >/dev/null 2>&1
  fi
fi
exit 0
