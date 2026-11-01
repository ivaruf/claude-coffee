#!/bin/sh
# Removes claude-coffee, in an order that never leaves sleep switched off.
set -eu
LABEL=com.github.ivaruf.claude-coffee
SETTINGS=~/.claude/settings.json
SUDOERS=/etc/sudoers.d/claude-coffee
step() { printf '  \033[32m✓\033[0m %-14s %s\n' "$1" "$2"; }

printf '\nclaude-coffee: uninstalling\n\n'

# 1. Launch agent first, so it can't switch sleep off again halfway through
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/"$LABEL".plist
step "launch agent" removed

# 2. Hooks: only claude-coffee's groups; events left empty are dropped
if [ -s "$SETTINGS" ]; then
  t=$(mktemp)
  jq 'if .hooks then
        .hooks |= (with_entries(.value |= map(select([.hooks[]?.command | strings | test("claude-coffee\\.sh")] | any | not)))
                   | with_entries(select(.value | length > 0)))
        | if .hooks == {} then del(.hooks) else . end
      else . end' "$SETTINGS" >"$t"
  cat "$t" >"$SETTINGS"; rm -f "$t"
fi
step hooks "removed from $SETTINGS"

# 3. Sleep back to normal while the passwordless rule still exists, then remove the rule
sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 || true
step sleep "back to normal"
if [ -e "$SUDOERS" ]; then
  printf '    sudo asks for your password to remove %s\n' "$SUDOERS"
  sudo rm -f "$SUDOERS" && step sudoers removed
fi

# 4. Script and state
rm -rf ~/.claude/hooks/claude-coffee.sh ~/.claude/coffee
step files removed
printf '\n  Done. Sleep is back to normal.\n\n'
