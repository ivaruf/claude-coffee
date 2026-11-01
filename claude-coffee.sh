#!/bin/sh
# claude-coffee: keep the Mac awake, lid closed too, while any Claude Code session is mid-turn.
# https://github.com/ivaruf/claude-coffee
#
# usage: claude-coffee.sh on|off   Claude Code hooks (hook JSON on stdin)
#        claude-coffee.sh check    the launch agent, every 5 minutes (reads no stdin)
#        claude-coffee.sh status   for you; changes nothing

C=~/.claude/coffee
STALE_MINUTES=30    # drop a marker no hook has touched for this long (Esc never fires Stop)
REMOTE=1            # 0 = no remote mode
REMOTE_MINUTES=60   # remote mode lapses this long after the last hook event and the SSH login
# shellcheck source=/dev/null
[ -f "$C/config" ] && . "$C/config"
D=$C/busy   # one marker file per session that is mid-turn
L=$C/last   # touched on every hook event
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

# SleepDisabled is missing from pmset -g when it is 0, so an empty value just re-applies 0
have=$(pmset -g | awk '/SleepDisabled/{print $2}')
lid=$(ioreg -r -k AppleClamshellState -d 1 | grep -cE '"AppleClamshell(State|CausesSleep)" = Yes')

if [ "$1" = status ]; then
  ok() { if "$@" >/dev/null 2>&1; then echo ok; else echo "missing (run install.sh)"; fi; }
  # -k: with cached credentials "sudo -n" passes for any admin; only a NOPASSWD rule should count
  nopasswd() { sudo -k -n -l | grep -qE 'NOPASSWD: (ALL$|.*/usr/bin/pmset -a disablesleep 1)'; }
  s=allowed; [ "$have" = 1 ] && s=blocked
  [ "$want" = "${have:-0}" ] || s="$s (the next hook or check flips it)"
  case $remote in
    0) r='off (no SSH login)' ;;
    1) r="lapsed (SSH login, but quiet for $REMOTE_MINUTES min)" ;;
    *) r='on (SSH login)' ;;
  esac
  [ "$REMOTE" = 1 ] || r='disabled in config'
  printf 'claude-coffee\n'
  printf '  sleep          %s\n' "$s"
  printf '  busy sessions  %s\n' "$busy"
  printf '  remote mode    %s\n' "$r"
  printf '  lid            %s\n' "$(if ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'; then echo closed; else echo open; fi)"
  printf '  sudo pmset     %s\n' "$(ok nopasswd)"
  printf '  launch agent   %s\n' "$(ok launchctl print "gui/$(id -u)/com.github.ivaruf.claude-coffee")"
  exit 0
fi

[ "$want" = "$have" ] || sudo -n /usr/bin/pmset -a disablesleep "$want" >/dev/null

# macOS decides on lid sleep only when the lid closes. If it closed while sleep was disabled,
# re-enabling sleep leaves the Mac awake, so sleep now. Skipped when an external display keeps a
# closed Mac running (AppleClamshellCausesSleep = No).
if [ "$want" = 0 ] && [ "$have" = 1 ] && [ "$lid" = 2 ]; then
  sleep 1; pmset sleepnow >/dev/null 2>&1
fi
exit 0
