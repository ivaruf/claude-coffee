#!/bin/sh
# The Linux install: runs install.sh and uninstall.sh in a throwaway $HOME with a fake uname (Linux), the
# fake systemd from tests/fixtures/linux.sh (systemctl, systemd-run, systemd-inhibit, busctl) and curl
# (which serves files from this repo instead of GitHub). Then the installed hook, for what only the Linux
# backend does: CPU use measured between checks, a docked or ACPI-only lid, never suspending by itself.
# Your real settings, systemd units and locks are never touched.
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); n=0; rc=0
export CLAUDE_COFFEE_TTY="$T/answer"   # no file: no terminal, so no question (and no hang under make test)
trap 'rc=$?; rm -rf "$T"; [ "$rc" = 0 ] || echo "install (linux): check $((n + 1)) failed" >&2' EXIT
mkdir -p "$T/bin" "$T/.claude" "$T/empty"
# The fixture's knobs (see tests/hook.test.sh), then its fakes
echo 0 >"$T/state"; echo open >"$T/lid"; echo 0 >"$T/thermal"; echo 30 >"$T/batt_c"
echo ac >"$T/src"; echo 100 >"$T/pct"; : >"$T/notified"; : >"$T/log"
printf '  500     1  3-00:00:00  0.0 claude\n' >"$T/ptable"; echo 30-00:00:00 >"$T/etime"
# shellcheck source=/dev/null
. "$R/tests/fixtures/linux.sh"
cat >"$T/bin/curl" <<EOF
#!/bin/sh
for a; do case \$a in https://*) url=\$a ;; esac; done
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
echo "curl \$url" >>$T/log
cp "$R/\${url##*/}" "\$out"
EOF
cat >"$T/bin/sudo" <<EOF
#!/bin/sh
echo "sudo \$*" >>$T/log
exit 1
EOF
printf '#!/bin/sh\nexit 1\n' >"$T/bin/pgrep"   # no SSH logins
printf '#!/bin/sh\nexit 0\n' >"$T/bin/sleep"
printf '#!/bin/sh\necho Linux\n' >"$T/bin/uname"
chmod +x "$T/bin/"*
S=$T/.claude/settings.json
U=$T/.config/systemd/user
H=$T/.claude/hooks/claude-coffee.sh
fake() { HOME=$T XDG_CONFIG_HOME=$T/.config XDG_CURRENT_DESKTOP=${DESK:-} PATH="$T/bin:$PATH" "$@"; }
run() { fake sh "$R/$1" >/dev/null 2>&1; }
say() { fake sh "$R/$1" 2>&1; }   # its output, for the warnings
ours() { jq '[.hooks[]?[] | select([.hooks[]?.command | test("claude-coffee")] | any)] | length' "$S"; }
hk() { printf '{"session_id":"%s"}' "$2" | fake sh "$H" "$1"; cat "$T/state"; }   # the installed hook
t() { n=$((n + 1)); }

cat >"$S" <<'EOF'
{ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "~/other.sh" } ] } ] } }
EOF
touch "$T/canhold"
out=$(say install.sh)
[ "$(ours)" = 5 ]; t                                                  # five hook groups added
[ "$(jq -c '.hooks.StopFailure[-1].hooks[1] | [.asyncRewake, .timeout, (.command | endswith(" wait"))]' "$S")" = '[true,14400,true]' ]; t   # ... StopFailure also starts the waiter, in the background
[ "$(jq -r .model "$S")" = opus ]; t                                  # other settings kept
# shellcheck disable=SC2088
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S")" = '~/other.sh' ]; t  # other hooks kept, still first
[ -x "$H" ]; t
if grep -q '^curl' "$T/log"; then exit 1; fi; t                       # a clone installs its own copy: no download
grep -qx 'Type=oneshot' "$U/claude-coffee.service"; t
grep -qx 'ExecStart=%h/.claude/hooks/claude-coffee.sh check' "$U/claude-coffee.service"; t   # systemd has no shell: %h, not ~
grep -qx 'OnCalendar=minutely' "$U/claude-coffee.timer"; grep -qx 'AccuracySec=1s' "$U/claude-coffee.timer"; t
grep -qx 'WantedBy=timers.target' "$U/claude-coffee.timer"; t
grep -q '^systemctl --user daemon-reload$' "$T/log"; [ -e "$T/agent" ]; t   # loaded, enabled and running
if grep -q '^sudo' "$T/log"; then exit 1; fi; t                       # no sudo, no password
printf '%s\n' "$out" | grep -q 'logind lock .*allowed'; t
if printf '%s\n' "$out" | grep -q 'handled by'; then exit 1; fi; t    # logind handles the lid: no warning
fx_sync; : >"$T/log"; cmd=$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$S")
printf '{"session_id":"S1"}' | fake sh -c "$cmd"
[ -e "$T/.claude/coffee/busy/S1" ]; [ "$(cat "$T/state")" = 1 ]; t   # the hook command really runs, and holds
grep -qxF 'systemd-run --user --quiet --collect --unit=claude-coffee-awake systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block --who=claude-coffee --why=Claude Code is working sh -c gnome-session-inhibit --inhibit suspend --reason "Claude Code is working" sleep infinity 2>/dev/null || exec sleep infinity' "$T/log"; t

run install.sh
[ "$(ours)" = 5 ]; t                                                  # re-running doesn't duplicate
[ "$(grep -c daemon-reload "$T/log")" = 0 ]; t                        # unchanged units are left alone
sed 's/AccuracySec=1s/AccuracySec=1min/' "$U/claude-coffee.timer" >"$T/old"; cat "$T/old" >"$U/claude-coffee.timer"
run install.sh
grep -qx 'AccuracySec=1s' "$U/claude-coffee.timer"; [ "$(grep -c daemon-reload "$T/log")" = 1 ]; t   # an older timer is replaced ...
grep -q '^systemctl --user restart claude-coffee.timer$' "$T/log"; t  # ... and restarted

rm "$T/canhold"
say install.sh | grep -q 'logind lock .*polkit refused'; t            # polkit says no (SSH): a warning ...
[ "$(ours)" = 5 ]; t                                                  # ... not a failure
DESK=KDE; say install.sh | grep -q 'lid .*handled by PowerDevil'; t   # KDE handles the lid itself
DESK=
cat >"$T/inhibitors" <<'EOF'
{"type":"a(ssssuu)","data":[[["sleep","NetworkManager","NetworkManager needs to turn off networks","delay",0,901],
["handle-power-key:handle-suspend-key:handle-lid-switch","xfce4-power-manager","xfce4-power-manager handles these events","block",1000,2042]]]}
EOF
say install.sh | grep -q 'lid .*handled by xfce4-power-manager'; t    # so does any other holder of the lid switch ...
cat >"$T/inhibitors" <<'EOF'
{"type":"a(ssssuu)","data":[[["sleep:idle:handle-lid-switch","claude-coffee","Claude Code is working","block",1000,4242],
["handle-lid-switch","gsd-power","Lid switch held for a moment","delay",1000,2050]]]}
EOF
if say install.sh | grep -q 'handled by'; then exit 1; fi; t          # ... but not our own lock, or a delay
rm "$T/inhibitors"; touch "$T/canhold"

: >"$T/log"; echo 1 >"$T/state"
run uninstall.sh
[ "$(ours)" = 0 ]; t
[ "$(jq -c '.hooks | keys' "$S")" = '["Stop"]' ]; t                   # emptied events dropped, others kept
[ ! -e "$U/claude-coffee.timer" ]; [ ! -e "$U/claude-coffee.service" ]; t
[ ! -e "$H" ]; [ ! -e "$T/.claude/coffee" ]; t
grep -q '^systemctl --user --quiet disable --now claude-coffee.timer$' "$T/log"; [ ! -e "$T/agent" ]; t
[ "$(cat "$T/state")" = 0 ]; grep -q '^systemctl --user stop claude-coffee-awake$' "$T/log"; t   # the lock released

rm "$S"; run install.sh
[ "$(ours)" = 5 ]; t                                                  # no settings.json yet: created
run uninstall.sh
[ "$(cat "$S")" = '{}' ]; t                                           # and left empty, not deleted

touch "$T/nosystemd"
if run install.sh; then exit 1; fi; t                                 # no systemd user manager: refuses ...
[ "$(cat "$S")" = '{}' ]; [ ! -e "$H" ]; t                            # ... before changing anything
rm "$T/nosystemd"

echo '{ broken' >"$S"
if run install.sh; then exit 1; fi; t                                 # invalid JSON: refuses ...
[ "$(cat "$S")" = '{ broken' ]; t                                     # ... and leaves the file alone
echo 1 >"$T/state"
if run uninstall.sh; then exit 1; fi; t                               # uninstall reports the broken file ...
[ "$(cat "$T/state")" = 0 ]; [ ! -e "$H" ]; t                         # ... but still releases the lock
[ "$(cat "$S")" = '{ broken' ]; t

echo '{}' >"$S"; run install.sh; echo 1 >"$T/state"; touch "$T/stuck"
if out=$(say uninstall.sh); then exit 1; fi; t                        # releasing fails ...
printf '%s\n' "$out" | grep -q 'run: systemctl --user stop claude-coffee-awake'; t   # ... and it says how to fix it
rm "$T/stuck"; echo 0 >"$T/state"

# curl -fsSL .../install.sh | sh
piped() { (cd "$T/empty" && fake sh <"$R/$1" >/dev/null 2>&1); }
echo '{}' >"$S"; : >"$T/log"
piped install.sh; [ "$(ours)" = 5 ]; cmp -s "$H" "$R/claude-coffee.sh"; [ -e "$U/claude-coffee.timer" ]; t
grep -q '^curl https://raw.githubusercontent.com/ivaruf/claude-coffee/main/claude-coffee.sh$' "$T/log"; t
piped uninstall.sh; [ "$(ours)" = 0 ]; [ ! -e "$H" ]; [ ! -e "$U/claude-coffee.timer" ]; t

# The installed hook, for what only Linux does
run install.sh; fx_sync; : >"$T/log"; rm -f "$T/slept"
echo closed >"$T/lid"
[ "$(hk on L)" = 1 ]; [ "$(hk off L)" = 0 ]; [ -e "$T/slept" ]; t    # logind sleeps a closed lid once the lock goes ...
if grep -qE '^systemctl .*(suspend|hibernate|sleep)' "$T/log"; then exit 1; fi; t   # ... so the hook never asks it to
rm "$T/slept"; touch "$T/docked"; echo 2 >"$T/thermal"; fx_sync
[ "$(hk on L)" = 1 ]; t                                               # docked (an external display): heat isn't ours ...
out=$(fake sh "$H" status); printf '%s\n' "$out" | grep -q 'lid            closed'; t               # ... though the lid is closed
[ "$(hk off L)" = 0 ]; [ ! -e "$T/slept" ]; t
rm "$T/docked"; echo 0 >"$T/thermal"; touch "$T/nobus"; fx_sync
mkdir -p "$T/root/proc/acpi/button/lid/LID0"
printf 'state:      closed\n' >"$T/root/proc/acpi/button/lid/LID0/state"
out=$(fake sh "$H" status); printf '%s\n' "$out" | grep -q 'lid            closed'; t               # no logind on the bus: the ACPI lid
printf 'state:      open\n' >"$T/root/proc/acpi/button/lid/LID0/state"
out=$(fake sh "$H" status); printf '%s\n' "$out" | grep -q 'lid            open'; t
rm "$T/nobus"; echo open >"$T/lid"
printf 'Linux version 5.15.167.4-microsoft-standard-WSL2\n' >"$T/root/proc/version"; : >"$T/log"
[ "$(hk on W)" = 0 ]; [ ! -e "$T/.claude/coffee/busy/W" ]; [ ! -s "$T/log" ]; t   # WSL: stays out of the way
rm "$T/root/proc/version"

# %cpu: procps shows a lifetime average; the check measures since the last check. Here train.py ran
# flat out for 45 of its 50 minutes, and ps says 90%
C=$T/.claude/coffee
printf '%s\n' '   500      1  3-00:00:00    00:10:00   0.2 claude' \
  '   501    500       50:00    00:45:00  90.0 python train.py' >"$T/ps-linux"
# chk AGE CPU MOVED: a snapshot from AGE seconds ago, in which PID 501 had used CPU seconds and started
# MOVED seconds before train.py did (non-zero: another process had that PID), then a check
chk() {
  now=$(date +%s)
  printf '%s\n' "$((now - $1))" "500 $((now - 259200)) 600" "501 $((now - 3000 - $3)) $2" >"$C/cpu"
  fake sh "$H" check </dev/null
}
rm -f "$C/cpu"; fake sh "$H" check </dev/null
[ -e "$C/working" ]; [ -s "$C/cpu" ]; t                               # no snapshot yet: the lifetime 90% stands in
chk 60 2700 0
[ ! -e "$C/working" ]; t                                              # no CPU time in the last minute: idle, whatever ps says
grep -q '^501 [0-9]* 2700$' "$C/cpu"; t                               # and the next check compares with this one
chk 60 2640 0
[ -e "$C/working" ]; t                                                # a full minute's CPU: at work
chk 60 2700 6000
[ -e "$C/working" ]; t                                                # another process had that PID: lifetime again
chk 600 2700 0
[ -e "$C/working" ]; t                                                # a snapshot from before a 10-minute sleep: lifetime
chk 3 2700 0
[ -e "$C/working" ]; t                                                # 3 seconds is too short to measure: lifetime
printf '%s\n' '   500      1  3-00:00:00    00:10:00   0.2 claude' \
  '   502    500       03:10    00:00:00   0.0 systemd-inhibit --what=idle sleep 300' >"$T/ps-linux"
rm -f "$C/working"; fake sh "$H" check </dev/null
[ -e "$C/working" ]; t                                                # Claude Code's own systemd-inhibit: a long tool call
echo "install (linux): all $n checks passed"
