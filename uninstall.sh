#!/bin/sh
# Removes claude-coffee, in an order that never leaves sleep switched off: everything that could
# switch it off goes first, then sleep is restored and checked. A failed step doesn't stop the rest;
# it's reported at the end, with exit code 1.
set -u
LABEL=com.github.ivaruf.claude-coffee
SETTINGS=~/.claude/settings.json
SUDOERS=/etc/sudoers.d/claude-coffee
failed=0
step() { printf '  \033[32m✓\033[0m %-14s %s\n' "$1" "$2"; }
fail() { printf '  \033[31m✗\033[0m %-14s %s\n' "$1" "$2"; failed=1; }

printf '\nclaude-coffee: uninstalling\n\n'

# 1. Launch agent
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f ~/Library/LaunchAgents/"$LABEL".plist
step "launch agent" removed

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
rm -f ~/.claude/hooks/claude-coffee.sh
step script removed

# 4. Sleep back to normal while the passwordless rule still exists, and check that it took
sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1
if [ "$(pmset -g | awk '/SleepDisabled/{print $2}')" = 1 ]; then   # the value: the line can read 0
  fail sleep "still switched off; run: sudo pmset -a disablesleep 0"
else
  step sleep "back to normal"
fi

# 5. The sudoers rule
if [ -e "$SUDOERS" ]; then
  printf '    sudo asks for your password to remove %s\n' "$SUDOERS"
  if sudo rm -f "$SUDOERS"; then step sudoers removed; else fail sudoers "still there; run: sudo rm $SUDOERS"; fi
fi

# 6. State
rm -rf ~/.claude/coffee
step state removed

if [ "$failed" = 1 ]; then
  printf '\n  Not everything could be undone; see the ✗ lines above.\n\n'
  exit 1
fi
printf '\n  Done. Sleep is back to normal.\n\n'
