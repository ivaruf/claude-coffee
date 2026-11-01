#!/bin/sh
# Runs install.sh and uninstall.sh in a throwaway $HOME with fake sudo, launchctl, pmset, ioreg and osascript.
# Your real settings, sudoers and launch agents are never touched.
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); n=0; rc=0
trap 'rc=$?; rm -rf "$T"; [ "$rc" = 0 ] || echo "install: check $((n + 1)) failed" >&2' EXIT
mkdir -p "$T/bin" "$T/.claude"
cat >"$T/bin/sudo" <<EOF
#!/bin/sh
echo "sudo \$*" >>$T/log
if [ "\$2" = /usr/bin/pmset ]; then [ -e $T/nosudo ] && exit 1; echo "\$5" >$T/state; fi
exit 0
EOF
cat >"$T/bin/pmset" <<EOF
#!/bin/sh
[ "\$1" = -g ] && printf ' SleepDisabled\t\t%s\n' "\$(cat $T/state)"
exit 0
EOF
printf '#!/bin/sh\necho "      \\"AppleClamshellState\\" = No"\n' >"$T/bin/ioreg"
printf '#!/bin/sh\necho 0\n' >"$T/bin/osascript"
cat >"$T/bin/launchctl" <<EOF
#!/bin/sh
echo "launchctl \$*" >>$T/log
case \$1 in
  print) [ -e $T/loaded ] ;;
  bootstrap) touch $T/loaded ;;
  bootout) rm -f $T/loaded ;;
esac
EOF
chmod +x "$T/bin/"*
: >"$T/log"; echo 0 >"$T/state"
S=$T/.claude/settings.json
P=$T/Library/LaunchAgents/com.github.ivaruf.claude-coffee.plist
run() { HOME=$T PATH="$T/bin:$PATH" sh "$R/$1" >/dev/null 2>&1; }
ours() { jq '[.hooks[]?[] | select([.hooks[]?.command | test("claude-coffee")] | any)] | length' "$S"; }
t() { n=$((n + 1)); }

cat >"$S" <<'EOF'
{ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "~/other.sh" } ] } ] } }
EOF
run install.sh
[ "$(ours)" = 5 ]; t                                                  # five hook groups added
[ "$(jq -r .model "$S")" = opus ]; t                                  # other settings kept
# shellcheck disable=SC2088
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S")" = '~/other.sh' ]; t  # other hooks kept, still first
[ -x "$T/.claude/hooks/claude-coffee.sh" ]; t
plutil -lint "$P" >/dev/null; t
grep -q "<string>$T/.claude/hooks/claude-coffee.sh</string>" "$P"; t  # absolute path: launchd has no shell
# the rule goes in, unless this Mac already has the real one
grep -q '^sudo install -m 0440 -o root -g wheel .* /etc/sudoers.d/claude-coffee$' "$T/log" || [ -e /etc/sudoers.d/claude-coffee ]; t
cmd=$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$S")
printf '{"session_id":"S1"}' | HOME=$T PATH="$T/bin:$PATH" sh -c "$cmd"
[ -e "$T/.claude/coffee/busy/S1" ]; t                                 # the hook command really runs

run install.sh
[ "$(ours)" = 5 ]; t                                                  # re-running doesn't duplicate
[ "$(grep -c bootstrap "$T/log")" = 1 ]; t                            # a loaded, unchanged agent is left alone
sed -i '' 's|<integer>60</integer>|<integer>300</integer>|' "$P"; run install.sh
[ "$(grep -c bootstrap "$T/log")" = 2 ]; grep -q '<integer>60</integer>' "$P"; t  # an older plist is replaced and reloaded

run uninstall.sh
[ "$(ours)" = 0 ]; t
[ "$(jq -c '.hooks | keys' "$S")" = '["Stop"]' ]; t                   # emptied events dropped, others kept
[ ! -e "$P" ]; [ ! -e "$T/.claude/hooks/claude-coffee.sh" ]; [ ! -e "$T/.claude/coffee" ]; t
grep -q '^launchctl bootout ' "$T/log"; t
grep -q '^sudo -n /usr/bin/pmset -a disablesleep 0$' "$T/log"; t     # sleep back on before the rule goes

rm "$S"; run install.sh
[ "$(ours)" = 5 ]; t                                                  # no settings.json yet: created
run uninstall.sh
[ "$(cat "$S")" = '{}' ]; t                                           # and left empty, not deleted

echo '{ broken' >"$S"
if run install.sh; then exit 1; fi; t                                 # invalid JSON: refuses ...
[ "$(cat "$S")" = '{ broken' ]; t                                     # ... and leaves the file alone
echo 1 >"$T/state"
if run uninstall.sh; then exit 1; fi; t                               # uninstall reports the broken file ...
[ "$(cat "$T/state")" = 0 ]; [ ! -e "$T/.claude/hooks/claude-coffee.sh" ]; t     # ... but still restores sleep
[ "$(cat "$S")" = '{ broken' ]; t

echo '{}' >"$S"; run install.sh; echo 1 >"$T/state"; touch "$T/nosudo"
if out=$(HOME=$T PATH="$T/bin:$PATH" sh "$R/uninstall.sh" 2>&1); then exit 1; fi; t  # restoring sleep fails ...
printf '%s\n' "$out" | grep -q 'run: sudo pmset -a disablesleep 0'; t   # ... and it says how to fix it
echo "install: all $n checks passed"
