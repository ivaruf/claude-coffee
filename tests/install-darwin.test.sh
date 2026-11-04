#!/bin/sh
# The macOS install: runs install.sh and uninstall.sh in a throwaway $HOME with a fake uname (Darwin),
# sudo, launchctl, pmset, ioreg, osascript
# and curl (which serves files from this repo instead of GitHub).
# Your real settings, sudoers and launch agents are never touched.
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); n=0; rc=0
export CLAUDE_COFFEE_TTY="$T/answer"   # no file: no terminal, so no question (and no hang under make test)
trap 'rc=$?; rm -rf "$T"; [ "$rc" = 0 ] || echo "install (darwin): check $((n + 1)) failed" >&2' EXIT
mkdir -p "$T/bin" "$T/.claude" "$T/empty"
cat >"$T/bin/curl" <<EOF
#!/bin/sh
for a; do case \$a in https://*) url=\$a ;; esac; done
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
echo "curl \$url" >>$T/log
[ -e $T/offline ] && exit 7
if [ -e $T/portal ]; then echo "<html>Sign in to Wi-Fi</html>" >"\$out"; else cp "$R/\${url##*/}" "\$out"; fi
EOF
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
printf '#!/bin/sh\nexit 1\n' >"$T/bin/pgrep"   # no SSH logins
cat >"$T/bin/launchctl" <<EOF
#!/bin/sh
echo "launchctl \$*" >>$T/log
case \$1 in
  print) [ -e $T/loaded ] ;;
  bootstrap) touch $T/loaded ;;
  bootout) rm -f $T/loaded ;;
esac
EOF
printf '#!/bin/sh\necho Darwin\n' >"$T/bin/uname"
# visudo checks the sudoers rule for real where it exists (macOS); elsewhere it's waved through
command -v visudo >/dev/null || printf '#!/bin/sh\nexit 0\n' >"$T/bin/visudo"
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
[ "$(jq -c '.hooks.StopFailure[-1].hooks[1] | [.asyncRewake, .timeout, (.command | endswith(" wait"))]' "$S")" = '[true,14400,true]' ]; t   # ... StopFailure also starts the waiter, in the background
[ "$(jq -r .model "$S")" = opus ]; t                                  # other settings kept
# shellcheck disable=SC2088
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S")" = '~/other.sh' ]; t  # other hooks kept, still first
[ -x "$T/.claude/hooks/claude-coffee.sh" ]; t
if grep -q '^curl' "$T/log"; then exit 1; fi; t                       # a clone installs its own copy: no download
if command -v plutil >/dev/null; then plutil -lint "$P" >/dev/null; else grep -q '<key>Label</key>' "$P"; fi; t
grep -q "<string>$T/.claude/hooks/claude-coffee.sh</string>" "$P"; t  # absolute path: launchd has no shell
grep -q '<key>RunAtLoad</key><true/>' "$P"; t                    # also at login: lets go after a restart mid-turn
# the rule goes in, unless this Mac already has the real one
grep -q '^sudo install -m 0440 -o root -g wheel .* /etc/sudoers.d/claude-coffee$' "$T/log" || [ -e /etc/sudoers.d/claude-coffee ]; t
cmd=$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$S")
printf '{"session_id":"S1"}' | HOME=$T PATH="$T/bin:$PATH" sh -c "$cmd"
[ -e "$T/.claude/coffee/busy/S1" ]; t                                 # the hook command really runs

run install.sh
[ "$(ours)" = 5 ]; t                                                  # re-running doesn't duplicate
[ "$(grep -c bootstrap "$T/log")" = 1 ]; t                            # a loaded, unchanged agent is left alone
sed 's|<integer>60</integer>|<integer>300</integer>|' "$P" >"$P.old" && mv "$P.old" "$P"; run install.sh
[ "$(grep -c bootstrap "$T/log")" = 2 ]; grep -q '<integer>60</integer>' "$P"; t  # an older plist is replaced and reloaded
C=$T/.claude/coffee/config
[ ! -e "$C" ]; HOME=$T PATH="$T/bin:$PATH" sh "$R/install.sh" 2>&1 | grep -q "echo AWAKE_ON_AC=1 >>$C\$"; t   # no terminal: a tip, no config
echo y >"$T/answer"; run install.sh; [ "$(cat "$C")" = AWAKE_ON_AC=1 ]; t   # "y": awake while plugged in
echo n >"$T/answer"; run install.sh; [ "$(cat "$C")" = AWAKE_ON_AC=1 ]; t   # asked only once
printf REMOTE=0 >"$C"; printf maybe >"$T/answer"; run install.sh
[ "$(cat "$C")" = "$(printf 'REMOTE=0\nAWAKE_ON_AC=0')" ]; t       # anything but yes is no, on a line of its own
rm "$T/answer"

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

# curl -fsSL .../install.sh | sh: no clone next to it, so claude-coffee.sh comes from GitHub
rm -f "$T/nosudo"; echo '{}' >"$S"
piped() { (cd "$T/empty" && HOME=$T PATH="$T/bin:$PATH" sh <"$R/$1" >/dev/null 2>&1); }
piped install.sh; [ "$(ours)" = 5 ]; t                                # piped install works ...
cmp -s "$T/.claude/hooks/claude-coffee.sh" "$R/claude-coffee.sh"; t   # ... with the downloaded script
grep -q '^curl https://raw.githubusercontent.com/ivaruf/claude-coffee/main/claude-coffee.sh$' "$T/log"; t
rm "$T/.claude/hooks/claude-coffee.sh"; touch "$T/offline"
if piped install.sh; then exit 1; fi; [ ! -e "$T/.claude/hooks/claude-coffee.sh" ]; t   # offline: refuses
rm "$T/offline"; touch "$T/portal"
if piped install.sh; then exit 1; fi; [ ! -e "$T/.claude/hooks/claude-coffee.sh" ]; t   # a Wi-Fi login page isn't installed
rm "$T/portal"
printf '#!/bin/sh\n# decoy\n' >"$T/empty/claude-coffee.sh"; : >"$T/empty/sh"
piped install.sh; cmp -s "$T/.claude/hooks/claude-coffee.sh" "$R/claude-coffee.sh"; t  # piped next to a decoy (and a file named sh): still downloads
rm "$T/empty/claude-coffee.sh" "$T/empty/sh"
piped uninstall.sh; [ "$(ours)" = 0 ]; [ ! -e "$T/.claude/hooks/claude-coffee.sh" ]; t  # piped uninstall works too
echo "install (darwin): all $n checks passed"
