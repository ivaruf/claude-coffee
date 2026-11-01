#!/bin/sh
# Installs claude-coffee. Safe to re-run: that's also how you update. Works from a clone (./install.sh)
# and straight from GitHub (curl -fsSL .../install.sh | sh), where it downloads claude-coffee.sh too.
set -eu
RAW=https://raw.githubusercontent.com/ivaruf/claude-coffee/main
LABEL=com.github.ivaruf.claude-coffee
HOOK=~/.claude/hooks/claude-coffee.sh
SETTINGS=~/.claude/settings.json
AGENT=~/Library/LaunchAgents/$LABEL.plist
SUDOERS=/etc/sudoers.d/claude-coffee

step() { printf '  \033[32m✓\033[0m %-14s %s\n' "$1" "$2"; }
warn() { printf '  \033[33m!\033[0m %-14s %s\n' "$1" "$2"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# Everything runs from here, called on the last line: a download cut off halfway runs nothing
main() {
  printf '\nclaude-coffee: installing\n\n'
  [ "$(uname)" = Darwin ] || die "macOS only: this uses pmset and launchd"
  command -v jq >/dev/null || die "jq is missing: brew install jq"

  # 1. The hook script: in a clone, the one next to this installer. Piped through sh, $0 is just "sh"
  #    and whatever lies in the current folder is irrelevant, so it comes from the same branch on GitHub
  mkdir -p ~/.claude/hooks
  src=$(dirname "$0")/claude-coffee.sh
  case $0 in *install.sh) [ -f "$src" ] || src= ;; *) src= ;; esac
  if [ -n "$src" ]; then
    install -m 0755 "$src" "$HOOK"
    step script "$HOOK"
  else
    t=$(mktemp)
    curl -fsSL "$RAW/claude-coffee.sh" -o "$t" || { rm -f "$t"; die "couldn't download $RAW/claude-coffee.sh"; }
    # A captive portal or proxy can answer with a web page; only install what looks like the script
    head -n 1 "$t" | grep -qx '#!/bin/sh' || { rm -f "$t"; die "$RAW/claude-coffee.sh didn't download as a script"; }
    install -m 0755 "$t" "$HOOK"; rm -f "$t"
    step script "$HOOK (downloaded)"
  fi

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
    printf '    sudo may ask for your password, to allow only: pmset -a disablesleep 0|1\n'
    if sudo install -m 0440 -o root -g wheel "$t" "$SUDOERS"; then step sudoers "$SUDOERS"
    else warn sudoers "skipped: without it the Mac just sleeps as usual. Re-run to retry"; fi
  fi
  rm -f "$t"

  # 4. Launch agent: checks every minute, so markers from interrupted turns expire on time and the heat
  #    guard notices a long job (one long tool call fires no hooks)
  mkdir -p ~/Library/LaunchAgents
  t=$(mktemp)
  cat >"$t" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- claude-coffee: checks every minute, for stale markers and the heat guard -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/.claude/hooks/claude-coffee.sh</string>
    <string>check</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
</dict>
</plist>
EOF
  # A loaded agent with the same plist stays as it is. A new or changed one (an update) is (re)loaded;
  # bootstrap right after bootout can fail while the old job winds down, hence one retry.
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && cmp -s "$t" "$AGENT"; then
    rm -f "$t"
  else
    cat "$t" >"$AGENT"; rm -f "$t"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || { sleep 1; launchctl bootstrap "gui/$(id -u)" "$AGENT"; }
  fi
  step "launch agent" "$AGENT"

  printf '\n  Done. Running Claude Code sessions pick this up on their next turn.\n'
  printf '  Check any time:  %s status\n\n' "$HOOK"
}

main "$@"
