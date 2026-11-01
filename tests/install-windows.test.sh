#!/bin/sh
# The Windows install, and the Windows backend's own pitfalls: runs install.sh, uninstall.sh and the hook in
# a throwaway $HOME with a fake uname (MINGW64), the fakes of tests/fixtures/windows.sh (powercfg, powershell,
# cygpath, reg, schtasks, tasklist) and curl (which serves files from this repo instead of GitHub).
# Your real settings, power plan and scheduled tasks are never touched.
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); n=0; rc=0
trap 'rc=$?; rm -rf "$T"; [ "$rc" = 0 ] || echo "install (windows): check $((n + 1)) failed" >&2' EXIT
mkdir -p "$T/bin" "$T/empty" "$T/git/bin" "$T/profile/.claude"
# The knobs of tests/hook.test.sh, for the fixture
echo 0 >"$T/state"; echo open >"$T/lid"; echo 0 >"$T/thermal"; echo 30 >"$T/batt_c"
echo ac >"$T/src"; echo 100 >"$T/pct"; : >"$T/notified"; : >"$T/ssh"; echo 30-00:00:00 >"$T/etime"
printf '  500     1  3-00:00:00  0.0 claude\n' >"$T/ptable"
UNAME=   # the fixture sets it
# shellcheck source=/dev/null
. "$R/tests/fixtures/windows.sh"
printf '#!/bin/sh\necho %s\n' "$UNAME" >"$T/bin/uname"
cat >"$T/bin/curl" <<EOF
#!/bin/sh
for a; do case \$a in https://*) url=\$a ;; esac; done
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
echo "curl \$url" >>$T/calls
[ -e $T/offline ] && exit 7
if [ -e $T/portal ]; then echo "<html>Sign in to Wi-Fi</html>" >"\$out"; else cp "$R/\${url##*/}" "\$out"; fi
EOF
cat >"$T/git/bin/bash.exe" <<'EOF'
#!/bin/sh
# Git's own bin\bash.exe
exec sh "$@"
EOF
chmod +x "$T/bin/"* "$T/git/bin/bash.exe"
touch "$T/canhold"; : >"$T/calls"
unset CLAUDE_CONFIG_DIR
USERPROFILE=$T/profile; export USERPROFILE   # Claude Code's home, which needn't be Git Bash's ~ ($T here)
S=$T/profile/.claude/settings.json
HK=$T/.claude/hooks/claude-coffee.sh
WH=$T/.claude/coffee/win.held
run() { HOME=$T PATH="$T/bin:$PATH" sh "$R/$1" >/dev/null 2>&1; }
ours() { jq '[.hooks[]?[] | select([.hooks[]?.command | test("claude-coffee")] | any)] | length' "$1"; }
plan() { awk '{ printf "%s%s %s %s", (NR > 1 ? ", " : ""), $1, $2, $3 }' "$T/pcfg"; }   # lid AC DC, sleep-after AC DC
t() { n=$((n + 1)); }

cat >"$S" <<'EOF'
{ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "~/other.sh" } ] } ] } }
EOF
run install.sh
[ "$(ours "$S")" = 5 ]; t                                            # five hook groups, in %USERPROFILE%\.claude
[ ! -e "$T/.claude/settings.json" ]; t                               # ... not in Git Bash's ~
[ "$(jq -r .model "$S")" = opus ]; t                                 # other settings kept
# shellcheck disable=SC2088
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S")" = '~/other.sh' ]; t   # other hooks kept, still first
[ -x "$HK" ]; t
if grep -q '^curl' "$T/calls"; then exit 1; fi; t                   # a clone installs its own copy: no download
cmd=$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$S")
[ "$cmd" = "$T/git/bin/bash.exe $HK on" ]; t                         # Git's bash on the script, absolute, no quotes
printf '{"session_id":"S1"}' | HOME=$T PATH="$T/bin:$PATH" sh -c "$cmd"
[ -e "$T/.claude/coffee/busy/S1" ]; t                                # the hook command really runs
[ -e "$T/agent" ]; t                                                 # the scheduled task is there ...
[ "$(sed -n 1p "$T/task.args")" = "$T/git/bin/bash.exe" ]; [ "$(sed -n 2p "$T/task.args")" = "$HK" ]; t
grep -q "conhost.exe' -Argument ('--headless \"{0}\" \"{1}\" check'" "$T/task.ps1"; t   # ... running "check" unseen
grep -q -- '-RepetitionInterval (New-TimeSpan -Minutes 1)' "$T/task.ps1"; t                 # ... every minute
grep -q -- '-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries' "$T/task.ps1"; t          # ... on battery too
grep -q -- '-MultipleInstances IgnoreNew' "$T/task.ps1"; t
[ -e "$WH" ]; [ "$(cat "$T/state")" = 1 ]; t                         # S1 holds it

run install.sh
[ "$(ours "$S")" = 5 ]; t                                            # re-running doesn't duplicate
rm "$T/canhold"; out=$(HOME=$T PATH="$T/bin:$PATH" sh "$R/install.sh" 2>&1); touch "$T/canhold"
printf '%s\n' "$out" | grep -q 'set by your organization'; t         # Group Policy on sleep: says so
(CLAUDE_CONFIG_DIR=$T/cfg; export CLAUDE_CONFIG_DIR; run install.sh)
[ "$(ours "$T/cfg/settings.json")" = 5 ]; t                          # CLAUDE_CONFIG_DIR wins
(CLAUDE_CONFIG_DIR=$T/cfg; export CLAUDE_CONFIG_DIR; run uninstall.sh)
[ "$(ours "$T/cfg/settings.json")" = 0 ]
mkdir -p "$T/my home"
out=$(HOME="$T/my home" PATH="$T/bin:$PATH" sh "$R/install.sh" 2>&1)
printf '%s\n' "$out" | grep -q 'need Claude Code to find Git Bash'; t   # a space and no short name: says what that costs
cmd=$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$S")
[ "$cmd" = "'$T/git/bin/bash.exe' '$T/my home/.claude/hooks/claude-coffee.sh' on" ]; t   # ... and quotes, for bash
printf '{"session_id":"S2"}' | HOME="$T/my home" PATH="$T/bin:$PATH" sh -c "$cmd"
[ -e "$T/my home/.claude/coffee/busy/S2" ]; t
HOME="$T/my home" PATH="$T/bin:$PATH" sh "$R/uninstall.sh" >/dev/null 2>&1
run install.sh

# --- the backend -----------------------------------------------------------------------------------------
hook() { fx_sync; printf '{"session_id":"%s"}' "$2" | HOME=$T PATH="$T/bin:$PATH" sh "$HK" "$1"; }
chk() { fx_sync; HOME=$T PATH="$T/bin:$PATH" sh "$HK" check </dev/null; }
pwsh() { grep -c '^powershell' "$T/calls" || true; }   # PowerShell runs so far
rm -rf "$T/.claude/coffee"; echo 0 >"$T/state"; fx_plan "1 1" "1800 900"; : >"$T/calls"
hook on A
[ "$(plan)" = '5ca83367-6e45-459f-a27b-476b1d01c936 0 0, 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0 0' ]; t  # lid: nothing, sleep: never
[ "$(sed -n 1p "$WH")" = 381b4222-f694-41f0-9685-ff5bb260df2e ]; t   # ... and what it was, saved
grep -qx '4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1 1' "$WH"; t
grep -qx '238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 1800 900' "$WH"; t
grep -q '^powercfg -setactive 381b4222' "$T/calls"; t               # the active plan: takes effect now
[ "$(pwsh)" = 0 ]; t                                                 # holding starts no PowerShell
: >"$T/calls"; hook on A
[ ! -s "$T/calls" ]; t                                               # a hook mid-turn runs neither powercfg nor PowerShell
sed "s/^5ca83367-6e45-459f-a27b-476b1d01c936 0 0\$/5ca83367-6e45-459f-a27b-476b1d01c936 2 0/" "$T/pcfg" >"$T/pcfg.new"
mv "$T/pcfg.new" "$T/pcfg"                                         # meanwhile, you set lid AC to hibernate
hook off A
[ "$(plan)" = '5ca83367-6e45-459f-a27b-476b1d01c936 2 1, 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 1800 900' ]; t  # put back, yours kept
[ ! -e "$WH" ]; [ "$(cat "$T/state")" = 0 ]; t
[ "$(pwsh)" = 1 ]; grep -q '^powershell claude-coffee.ps1 lid$' "$T/calls"; t  # releasing asks for the lid, once
[ ! -e "$T/slept" ]; t                                               # open: no sleep
fx_plan '1 1' '1800 900'

# The lid closes seconds before the turn ends: the check's cache still says open, Windows doesn't
hook on B; sh "$T/bin/fx-cache" full >"$T/.claude/coffee/win.cache"; echo closed >"$T/lid"
printf '{"session_id":"B"}' | HOME=$T PATH="$T/bin:$PATH" sh "$HK" off
[ -e "$T/slept" ]; t                                                 # asked, found it closed: asleep
rm "$T/slept"; echo 0 >"$T/state"
# Lid closed with your own lid action "do nothing" (say, an external display): not ours to sleep
fx_plan '0 0' '1800 900'; hook on C; hook off C
[ ! -e "$T/slept" ]; t
hook on C; touch -t 202001010000 "$T/.claude/coffee/busy/C"; chk
[ "$(cat "$T/state")" = 0 ]; [ ! -e "$T/slept" ]; t                 # ... nor when the check lets go
fx_plan '1 1' '1800 900'; echo open >"$T/lid"

# Two hooks at once: the second waits for the first, and never saves the first one's zeros
mkdir "$T/.claude/coffee/win.lock"
hook on D; [ ! -e "$WH" ]; t                                         # busy lock: gives up after a while, holds nothing
touch -t 202001010000 "$T/.claude/coffee/win.lock"
hook on D; [ -e "$WH" ]; grep -qx '.* 5ca83367-6e45-459f-a27b-476b1d01c936 1 1' "$WH"; t   # a stale lock is cleared
[ ! -e "$T/.claude/coffee/win.lock" ]; t
hook off D; rm -f "$T/slept"

# The every-minute check: PowerShell once while there's work, not at all when idle without an sshd
: >"$T/calls"; hook on E; chk
[ "$(pwsh)" = 1 ]; grep -q '^powershell claude-coffee.ps1 gather full$' "$T/calls"; t
grep -q '^proc 500 ' "$T/.claude/coffee/win.cache"; t                # the processes, for the check's own use
hook off E; : >"$T/calls"; chk
[ "$(pwsh)" = 0 ]; grep -q '^tasklist' "$T/calls"; t                 # idle: tasklist looks for sshd, finds none
touch -t 202001010000 "$T/.claude/coffee/last"; echo 4242 >"$T/ssh"; chk   # an old login, quiet
grep -q '^powershell claude-coffee.ps1 gather ssh$' "$T/calls"; t    # an sshd: PowerShell, for logins only
: >"$T/ssh"; echo 'REMOTE=0' >"$T/.claude/coffee/config"; : >"$T/calls"; chk
[ ! -s "$T/calls" ]; t                                               # remote mode off: not even tasklist
rm "$T/.claude/coffee/config"
echo junk >"$T/.claude/coffee/claude-coffee.ps1"; hook on F; chk
grep -q '^param(' "$T/.claude/coffee/claude-coffee.ps1"; t           # an outdated PowerShell half is rewritten
hook off F
touch -t 202001010000 "$T/.claude/coffee/win.cache"; echo closed >"$T/lid"
HOME=$T PATH="$T/bin:$PATH" sh "$HK" status | grep -q 'lid            closed'; t   # status asks, not the old cache
echo open >"$T/lid"; printf 'lid closed\nonbatt 1\ncharge 5\nthermal 3\n' >"$T/.claude/coffee/win.cache"
touch -t 202001010000 "$T/.claude/coffee/win.cache"
printf '{"session_id":"G"}' | HOME=$T PATH="$T/bin:$PATH" sh "$HK" on
[ "$(cat "$T/state")" = 1 ]; [ ! -e "$T/.claude/coffee/low" ]; t     # a cache from long ago is no reading at all
printf '{"session_id":"G"}' | HOME=$T PATH="$T/bin:$PATH" sh "$HK" off; echo 0 >"$T/state"

# --- uninstall -------------------------------------------------------------------------------------------
hook on H; [ -e "$WH" ]
run uninstall.sh
[ "$(ours "$S")" = 0 ]; t
[ "$(jq -c '.hooks | keys' "$S")" = '["Stop"]' ]; t                  # emptied events dropped, others kept
[ ! -e "$HK" ]; [ ! -e "$T/.claude/coffee" ]; [ ! -e "$T/agent" ]; t
grep -q '^schtasks /delete /tn claude-coffee /f$' "$T/calls"; t
[ "$(plan)" = '5ca83367-6e45-459f-a27b-476b1d01c936 1 1, 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 1800 900' ]; t  # plan put back

rm "$S"; run install.sh
[ "$(ours "$S")" = 5 ]; t                                            # no settings.json yet: created
run uninstall.sh
[ "$(cat "$S")" = '{}' ]; t                                          # and left empty, not deleted

echo '{ broken' >"$S"
if run install.sh; then exit 1; fi; t                                # invalid JSON: refuses ...
[ "$(cat "$S")" = '{ broken' ]; t                                    # ... and leaves the file alone
echo 0 >"$T/state"; hook on I; [ -e "$WH" ]
if run uninstall.sh; then exit 1; fi; t                              # uninstall reports the broken file ...
[ "$(cat "$T/state")" = 0 ]; [ ! -e "$HK" ]; t                       # ... but still puts the plan back
[ "$(cat "$S")" = '{ broken' ]; t

echo '{}' >"$S"; run install.sh; hook on J; touch "$T/pcfg-fail"
if out=$(HOME=$T PATH="$T/bin:$PATH" sh "$R/uninstall.sh" 2>&1); then exit 1; fi; t   # putting it back fails ...
printf '%s\n' "$out" | grep -q 'it was: lid action 1/1, sleep after (s) 1800/900'; t  # ... and it says what to set
rm "$T/pcfg-fail"; fx_plan '1 1' '1800 900'; echo 0 >"$T/state"; touch "$T/task-stuck"
run install.sh
if out=$(HOME=$T PATH="$T/bin:$PATH" sh "$R/uninstall.sh" 2>&1); then exit 1; fi
printf '%s\n' "$out" | grep -q 'run: schtasks /delete /tn claude-coffee /f'; t   # a task that won't go: says how
rm "$T/task-stuck"; touch "$T/task-fail"; echo '{}' >"$S"
if run install.sh; then exit 1; fi; t                                # no scheduled task: refuses to pretend
rm "$T/task-fail"

# curl -fsSL .../install.sh | sh: no clone next to it, so claude-coffee.sh comes from GitHub
echo '{}' >"$S"; : >"$T/calls"
piped() { (cd "$T/empty" && HOME=$T PATH="$T/bin:$PATH" sh <"$R/$1" >/dev/null 2>&1); }
piped install.sh; [ "$(ours "$S")" = 5 ]; t                          # piped install works ...
cmp -s "$HK" "$R/claude-coffee.sh"; t                                # ... with the downloaded script
grep -q '^curl https://raw.githubusercontent.com/ivaruf/claude-coffee/main/claude-coffee.sh$' "$T/calls"; t
rm "$HK"; touch "$T/offline"
if piped install.sh; then exit 1; fi; [ ! -e "$HK" ]; t              # offline: refuses
rm "$T/offline"; touch "$T/portal"
if piped install.sh; then exit 1; fi; [ ! -e "$HK" ]; t              # a Wi-Fi login page isn't installed
rm "$T/portal"
piped uninstall.sh; [ "$(ours "$S")" = 0 ]; [ ! -e "$HK" ]; t        # piped uninstall works too
echo "install (windows): all $n checks passed"
