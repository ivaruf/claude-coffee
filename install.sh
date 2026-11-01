#!/bin/sh
# Installs claude-coffee. Safe to re-run: that's also how you update.
set -eu
cd "$(dirname "$0")" || exit 1
LABEL=com.github.ivaruf.claude-coffee
HOOK=~/.claude/hooks/claude-coffee.sh
SETTINGS=~/.claude/settings.json
AGENT=~/Library/LaunchAgents/$LABEL.plist
SUDOERS=/etc/sudoers.d/claude-coffee

step() { printf '  \033[32m✓\033[0m %-14s %s\n' "$1" "$2"; }
warn() { printf '  \033[33m!\033[0m %-14s %s\n' "$1" "$2"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

printf '\nclaude-coffee: installing\n\n'
[ "$(uname)" = Darwin ] || die "macOS only: this uses pmset and launchd"
command -v jq >/dev/null || die "jq is missing: brew install jq"

# 1. The hook script
mkdir -p ~/.claude/hooks
install -m 0755 claude-coffee.sh "$HOOK"
step script "$HOOK"

# 2. Claude Code hooks: drop any earlier claude-coffee groups, then add ours. Everything else stays.
mkdir -p ~/.claude; [ -s "$SETTINGS" ] || echo '{}' >"$SETTINGS"
cp "$SETTINGS" "$SETTINGS.claude-coffee.bak"
t=$(mktemp)
# The ~ is meant literally: Claude Code runs hook commands in a shell, which expands it.
# shellcheck disable=SC2088
jq --arg on '~/.claude/hooks/claude-coffee.sh on' --arg off '~/.claude/hooks/claude-coffee.sh off' '
  def add($e; $c): .[$e] = ((.[$e] // []) + [{hooks: [{type: "command", command: $c}]}]);
  .hooks = ((.hooks // {})
    | with_entries(.value |= map(select([.hooks[]?.command | strings | test("claude-coffee\\.sh")] | any | not)))
    | add("UserPromptSubmit"; $on) | add("PreToolUse"; $on)
    | add("Stop"; $off) | add("StopFailure"; $off) | add("SessionEnd"; $off))
' "$SETTINGS" >"$t" || { rm -f "$t"; die "$SETTINGS is not valid JSON; nothing changed"; }
cat "$t" >"$SETTINGS"; rm -f "$t"
step hooks "$SETTINGS (backup: settings.json.claude-coffee.bak)"

# 3. Passwordless pmset, for exactly these two commands. Not "disablesleep *": man sudoers says a
#    wildcard can match whitespace too, which would let any other pmset setting be appended.
t=$(mktemp)
echo "$(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" >"$t"
visudo -cf "$t" >/dev/null || { rm -f "$t"; die "visudo rejected the sudoers rule"; }
# Not "sudo -n -l pmset ...": that also passes with cached credentials or any other NOPASSWD rule.
if [ -e "$SUDOERS" ]; then
  step sudoers "$SUDOERS (already there)"
else
  printf '    sudo asks for your password once, to allow only: pmset -a disablesleep 0|1\n'
  if sudo install -m 0440 -o root -g wheel "$t" "$SUDOERS"; then step sudoers "$SUDOERS"
  else warn sudoers "skipped: without it the Mac just sleeps as usual. Re-run to retry"; fi
fi
rm -f "$t"

# 4. Launch agent: re-checks every 5 minutes, so markers from interrupted turns expire on time
mkdir -p ~/Library/LaunchAgents
cat >"$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- claude-coffee: re-checks every 5 min so an interrupted turn can't keep the Mac awake -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/.claude/hooks/claude-coffee.sh</string>
    <string>check</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
</dict>
</plist>
EOF
# bootout + bootstrap back to back can race; the plist never changes, so a loaded agent can stay
launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || launchctl bootstrap "gui/$(id -u)" "$AGENT"
step "launch agent" "$AGENT"

printf '\n  Done. Running Claude Code sessions pick this up on their next turn.\n'
printf '  Check any time:  %s status\n\n' "$HOOK"
