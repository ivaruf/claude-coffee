#!/bin/sh
# Installs claude-coffee on macOS, Linux or Windows (Git Bash). Safe to re-run: that's also how you
# update. Works from a clone (./install.sh) and straight from GitHub (curl -fsSL .../install.sh | sh),
# where it downloads claude-coffee.sh too.
set -eu
RAW=https://raw.githubusercontent.com/ivaruf/claude-coffee/main
HOOK=~/.claude/hooks/claude-coffee.sh
SETTINGS=~/.claude/settings.json
# The ~ is meant literally: Claude Code runs hook commands in a shell, which expands it.
# shellcheck disable=SC2088
CMD='~/.claude/hooks/claude-coffee.sh'

step() { printf '  \033[32m✓\033[0m %-14s %s\n' "$1" "$2"; }
warn() { printf '  \033[33m!\033[0m %-14s %s\n' "$1" "$2"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

platform() {
  case $(uname -s) in
    Darwin) echo darwin ;;
    Linux) if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

# Each system has <os>_prepare (runs first: may adjust HOOK, SETTINGS, CMD) and <os>_install (runs
# last: whatever lets the hook keep the machine awake, and the every-minute check).

# --- macOS: passwordless pmset for exactly two commands, and a launch agent ---------------------------
LABEL=com.github.ivaruf.claude-coffee
AGENT=~/Library/LaunchAgents/$LABEL.plist
SUDOERS=/etc/sudoers.d/claude-coffee
darwin_prepare() { :; }
darwin_install() {
  # Not "disablesleep *": man sudoers says a wildcard can match whitespace too, which would let any other
  # pmset setting be appended.
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

  # Checks every minute, so markers from interrupted turns expire on time and the guards notice a long
  # job (one long tool call fires no hooks)
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
}

# --- Linux: a systemd timer, and nothing to grant: logind's lock needs no sudo -----------------------------
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
linux_prepare() {
  for c in systemctl systemd-run systemd-inhibit busctl; do
    command -v "$c" >/dev/null || die "$c is missing: on Linux, claude-coffee needs systemd"
  done
  systemctl --user show-environment >/dev/null 2>&1 ||
    die "systemctl --user isn't answering: claude-coffee needs your systemd user manager (log in as yourself, not with su or sudo)"
}
linux_install() {
  # polkit lets a local desktop session take the lid lock without a password; an SSH login alone it doesn't
  if systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block --who=claude-coffee --why='install check' true </dev/null >/dev/null 2>&1
  then step "logind lock" "allowed without a password"
  else warn "logind lock" "polkit refused it here (an SSH login?): it needs a local desktop session"; fi

  # Some desktops (KDE's PowerDevil, Xfce's power manager if set to) take the lid over from logind and
  # decide on lid sleep themselves, whatever claude-coffee's lock says
  who=$(busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ListInhibitors 2>/dev/null |
    jq -r '.data[0][] | select(.[3] == "block" and .[1] != "claude-coffee" and (.[0] | split(":") | index("handle-lid-switch"))) | .[1]' 2>/dev/null |
    sort -u | paste -sd , -)
  case ${XDG_CURRENT_DESKTOP:-} in *KDE*) [ -n "$who" ] || who=PowerDevil ;; esac
  if [ -n "$who" ]; then warn lid "handled by $who, not logind: closing the lid follows its power settings"; fi

  # Checks every minute, so markers from interrupted turns expire on time and the guards notice a long
  # job (one long tool call fires no hooks)
  mkdir -p "$UNITS"
  changed=0
  write_unit "$UNITS/claude-coffee.service" <<'EOF'
# claude-coffee: checks for stale markers, long jobs, heat and the battery
[Unit]
Description=claude-coffee check

[Service]
Type=oneshot
ExecStart=%h/.claude/hooks/claude-coffee.sh check
EOF
  write_unit "$UNITS/claude-coffee.timer" <<'EOF'
# claude-coffee: runs the check every minute
[Unit]
Description=claude-coffee check, every minute

[Timer]
OnCalendar=minutely
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
  # Unchanged units stay as they are; new or changed ones (an update) are reloaded and the timer restarted
  if [ "$changed" = 1 ]; then
    systemctl --user daemon-reload
    systemctl --user --quiet enable claude-coffee.timer
    systemctl --user restart claude-coffee.timer
  else
    systemctl --user --quiet enable --now claude-coffee.timer
  fi
  step "systemd timer" "$UNITS/claude-coffee.timer"
}
write_unit() {   # FILE, contents on stdin: written, and changed=1, only if new or different
  t=$(mktemp); cat >"$t"
  if cmp -s "$t" "$1"; then rm -f "$t"; else cat "$t" >"$1"; rm -f "$t"; changed=1; fi
}

# --- Windows, in Git Bash ---------------------------------------------------------------------------------
windows_prepare() { die "Windows support is on its way"; }
windows_install() { :; }

# Everything runs from here, called on the last line: a download cut off halfway runs nothing
main() {
  printf '\nclaude-coffee: installing\n\n'
  os=$(platform)
  case $os in
    darwin|linux|windows) ;;
    wsl) die "WSL isn't supported yet: Claude Code there can't keep Windows awake" ;;
    *) die "not supported on $(uname -s)" ;;
  esac
  if ! command -v jq >/dev/null; then
    case $os in
      darwin) die "jq is missing: brew install jq" ;;
      linux) die "jq is missing: install it with your package manager (apt, dnf, pacman: jq)" ;;
      windows) die "jq is missing: winget install jqlang.jq" ;;
    esac
  fi
  "${os}_prepare"

  # 1. The hook script: in a clone, the one next to this installer. Piped through sh, $0 is just "sh"
  #    and whatever lies in the current folder is irrelevant, so it comes from the same branch on GitHub
  mkdir -p "$(dirname "$HOOK")"
  src=$(dirname "$0")/claude-coffee.sh
  case $0 in *install.sh) [ -f "$src" ] || src= ;; *) src= ;; esac
  if [ -n "$src" ]; then
    install -m 0755 "$src" "$HOOK"
    step script "$HOOK"
  else
    t=$(mktemp)
    curl -fsSL "$RAW/claude-coffee.sh" -o "$t" || { rm -f "$t"; die "couldn't download $RAW/claude-coffee.sh"; }
    # A captive portal or proxy can answer with a web page; only install what looks like the script
    head -n 1 "$t" | tr -d '\r' | grep -qx '#!/bin/sh' || { rm -f "$t"; die "$RAW/claude-coffee.sh didn't download as a script"; }
    install -m 0755 "$t" "$HOOK"; rm -f "$t"
    step script "$HOOK (downloaded)"
  fi

  # 2. Claude Code hooks: drop any earlier claude-coffee groups, then add ours. Everything else stays.
  mkdir -p "$(dirname "$SETTINGS")"; [ -s "$SETTINGS" ] || echo '{}' >"$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.claude-coffee.bak"
  t=$(mktemp)
  jq --arg on "$CMD on" --arg off "$CMD off" '
    def add($e; $c): .[$e] = ((.[$e] // []) + [{hooks: [{type: "command", command: $c}]}]);
    .hooks = ((.hooks // {})
      | with_entries(.value |= map(select([.hooks[]?.command | strings | test("claude-coffee\\.sh")] | any | not)))
      | add("UserPromptSubmit"; $on) | add("PreToolUse"; $on)
      | add("Stop"; $off) | add("StopFailure"; $off) | add("SessionEnd"; $off))
  ' "$SETTINGS" >"$t" || { rm -f "$t"; die "$SETTINGS is not valid JSON; nothing changed"; }
  cat "$t" >"$SETTINGS"; rm -f "$t"
  step hooks "$SETTINGS (backup: settings.json.claude-coffee.bak)"

  # 3. What lets the hook keep the machine awake, and the every-minute check
  "${os}_install"

  printf '\n  Done. Running Claude Code sessions pick this up on their next turn.\n'
  printf '  Check any time:  %s status\n\n' "$HOOK"
}

main "$@"
