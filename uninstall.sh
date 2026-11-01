#!/bin/sh
# Removes claude-coffee, in an order that never leaves sleep switched off: everything that could
# switch it off goes first, then sleep is restored and checked. A failed step doesn't stop the rest;
# it's reported at the end, with exit code 1. Works from a clone and piped: curl -fsSL .../uninstall.sh | sh
set -u
HOOK=~/.claude/hooks/claude-coffee.sh
SETTINGS=~/.claude/settings.json
failed=0
step() { printf '  \033[32m✓\033[0m %-14s %s\n' "$1" "$2"; }
fail() { printf '  \033[31m✗\033[0m %-14s %s\n' "$1" "$2"; failed=1; }

platform() {
  case $(uname -s) in
    Darwin) echo darwin ;;
    Linux) if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

# Each system has <os>_prepare (may adjust HOOK, SETTINGS), <os>_unschedule (the every-minute check),
# <os>_release (sleep back to normal, checked: step or fail) and <os>_unprivilege (whatever the
# installer granted).

# --- macOS ------------------------------------------------------------------------------------------------
LABEL=com.github.ivaruf.claude-coffee
SUDOERS=/etc/sudoers.d/claude-coffee
darwin_prepare() { :; }
darwin_unschedule() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  rm -f ~/Library/LaunchAgents/"$LABEL".plist
  step "launch agent" removed
}
darwin_release() {   # while the passwordless rule still exists
  sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1
  if [ "$(pmset -g | awk '/SleepDisabled/{print $2}')" = 1 ]; then   # the value: the line can read 0
    fail sleep "still switched off; run: sudo pmset -a disablesleep 0"
  else
    step sleep "back to normal"
  fi
}
darwin_unprivilege() {
  if [ -e "$SUDOERS" ]; then
    printf '    sudo may ask for your password to remove %s\n' "$SUDOERS"
    if sudo rm -f "$SUDOERS"; then step sudoers removed; else fail sudoers "still there; run: sudo rm $SUDOERS"; fi
  fi
}

# --- Linux ------------------------------------------------------------------------------------------------
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
linux_prepare() { :; }
linux_unschedule() {
  systemctl --user --quiet disable --now claude-coffee.timer >/dev/null 2>&1
  systemctl --user stop claude-coffee.service >/dev/null 2>&1   # a check in progress
  rm -f "$UNITS/claude-coffee.timer" "$UNITS/claude-coffee.service"
  systemctl --user daemon-reload >/dev/null 2>&1
  step "systemd timer" removed
}
linux_release() {   # stopping the unit releases logind's lock; with the lid closed, logind sleeps then
  systemctl --user stop claude-coffee-awake >/dev/null 2>&1
  if systemctl --user is-active --quiet claude-coffee-awake 2>/dev/null; then
    fail sleep "still kept awake; run: systemctl --user stop claude-coffee-awake"
  else
    step sleep "back to normal"
  fi
}
linux_unprivilege() { :; }   # nothing was granted: no sudo rule, no polkit rule

# --- Windows, in Git Bash ---------------------------------------------------------------------------------
TASK=claude-coffee
windows_prepare() {   # Claude Code's settings.json: in %USERPROFILE%\.claude (or CLAUDE_CONFIG_DIR), not Git Bash's ~
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then SETTINGS=$(cygpath -u "$CLAUDE_CONFIG_DIR")/settings.json
  elif [ -n "${USERPROFILE:-}" ]; then SETTINGS=$(cygpath -u "$USERPROFILE")/.claude/settings.json; fi
}
windows_unschedule() {   # Git Bash would turn /query into a path
  if ! MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' schtasks /query /tn "$TASK" >/dev/null 2>&1 ||
     MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' schtasks /delete /tn "$TASK" /f >/dev/null 2>&1; then
    step "scheduled task" removed
  else
    fail "scheduled task" "still there; run: schtasks /delete /tn $TASK /f"
  fi
}
# A setting's AC and DC values in the plan, in decimal: the last two hex numbers of powercfg's (localized) text
windows_get() {
  powercfg -query "$1" "$2" "$3" </dev/null 2>/dev/null | tr -d '\r' | grep -oE '0x[0-9a-fA-F]+' | tail -n 2 |
    { read -r v_ac && read -r v_dc && echo "$((v_ac)) $((v_dc))"; }
}
windows_scheme() {
  powercfg -getactivescheme </dev/null 2>/dev/null | grep -oE '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}' | head -n 1
}
# The hook saved the plan's values in win.held before it set them to 0. Put back each one that's still 0
# (one you changed in between stays), then check that none of them is left at 0
windows_release() {
  f=~/.claude/coffee/win.held
  [ -e "$f" ] || { step sleep "back to normal"; return; }
  { read -r scheme
    while read -r sub key ac dc; do
      now=$(windows_get "$scheme" "$sub" "$key")
      case ${now:-0 0} in "0 "*) powercfg -setacvalueindex "$scheme" "$sub" "$key" "$ac" </dev/null >/dev/null 2>&1 ;; esac
      case ${now:-0 0} in *" 0") powercfg -setdcvalueindex "$scheme" "$sub" "$key" "$dc" </dev/null >/dev/null 2>&1 ;; esac
    done
  } <"$f"
  # Changes to the active plan count once it's activated again; another plan you switched to stays
  [ "$(windows_scheme)" != "$scheme" ] || powercfg -setactive "$scheme" </dev/null >/dev/null 2>&1
  left=$(sed 1d "$f" | while read -r sub key ac dc; do
    now=$(windows_get "$scheme" "$sub" "$key")
    if [ -z "$now" ] || { [ "${now%% *}" = 0 ] && [ "$ac" != 0 ]; } || { [ "${now#* }" = 0 ] && [ "$dc" != 0 ]; }; then
      echo "$key"
    fi
  done)
  if [ -z "$left" ]; then
    rm -f "$f"; step sleep "back to normal"
  else   # the state folder goes next, so say what the values were
    was=$(sed 1d "$f" | awk '{ printf "%s%s %s/%s", (NR > 1 ? ", " : ""), ($2 ~ /^5ca83367/ ? "lid action" : "sleep after (s)"), $3, $4 }')
    fail sleep "still switched off; set it in Control Panel > Power Options (plugged in/on battery, it was: $was)"
  fi
}
windows_unprivilege() { :; }   # nothing was granted

# Everything runs from here, called on the last line: a download cut off halfway runs nothing
main() {
  printf '\nclaude-coffee: uninstalling\n\n'
  os=$(platform)
  case $os in
    darwin|linux|windows) ;;
    *) printf '  not supported on %s, so nothing to remove\n\n' "$(uname -s)"; exit 0 ;;
  esac
  "${os}_prepare"

  # 1. The every-minute check
  "${os}_unschedule"

  # 2. Hooks: only claude-coffee's groups; events left empty are dropped
  t=$(mktemp)
  if [ ! -s "$SETTINGS" ]; then
    step hooks "nothing to remove"
  elif jq 'if .hooks then
             .hooks |= (with_entries(.value |= map(select([.hooks[]?.command | strings | test("claude-coffee\\.sh")] | any | not)))
                        | with_entries(select(.value | length > 0)))
             | if .hooks == {} then del(.hooks) else . end
           else . end' "$SETTINGS" >"$t" 2>/dev/null; then
    cat "$t" >"$SETTINGS"; step hooks "removed from $SETTINGS"
  else
    fail hooks "$SETTINGS isn't valid JSON: remove the claude-coffee.sh entries by hand"
  fi
  rm -f "$t"

  # 3. The script. From here on nothing can switch sleep off again, even if step 2 failed
  rm -f "$HOOK"
  step script removed

  # 4. Sleep back to normal, and check that it took
  "${os}_release"

  # 5. Whatever the installer granted
  "${os}_unprivilege"

  # 6. State
  rm -rf ~/.claude/coffee
  step state removed

  if [ "$failed" = 1 ]; then
    printf '\n  Not everything could be undone; see the ✗ lines above.\n\n'
    exit 1
  fi
  printf '\n  Done. Sleep is back to normal.\n\n'
}

main "$@"
