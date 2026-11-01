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
windows_prepare() { :; }
windows_unschedule() { :; }
windows_release() { :; }
windows_unprivilege() { :; }

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
