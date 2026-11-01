#!/bin/sh
# Runs claude-coffee.sh against fake pmset, sudo, ioreg, osascript, pgrep and ps in a throwaway $HOME.
# $T/ptable is the fake process table: pid, ppid, age, %cpu, command.
# Your real sleep settings are never touched, so this is safe to run at any time.
set -eu
S=$(cd "$(dirname "$0")/.." && pwd)/claude-coffee.sh
T=$(mktemp -d); n=0; rc=0
trap 'rc=$?; rm -rf "$T"; [ "$rc" = 0 ] || echo "hook: check $((n + 1)) failed" >&2' EXIT
mkdir "$T/bin"; echo 0 >"$T/state"
cat >"$T/bin/pmset" <<EOF
#!/bin/sh
# Real pmset prints "SleepDisabled 0" or, on some days, no line at all for 0; $T/noline picks the latter
if [ "\$2" = batt ]; then printf "Now drawing from '%s'\\n -InternalBattery-0 (id=1)\\t%s%%; discharging; present: true\\n" "\$(cat $T/src)" "\$(cat $T/pct)"; exit 0; fi
if [ "\$1" = -g ]; then [ -e $T/noline ] && [ "\$(cat $T/state)" = 0 ] && exit 0; printf ' SleepDisabled\t\t%s\n' "\$(cat $T/state)"; exit 0; fi
if [ "\$1" = sleepnow ]; then touch $T/slept; exit 0; fi
echo "\$3" >$T/state
EOF
echo 'AC Power' >"$T/src"; echo 100 >"$T/pct"   # plugged in, full
: >"$T/ssh"; echo 30-00:00:00 >"$T/etime"   # no SSH login; any login is old
printf '  500     1  3-00:00:00  0.0 claude\n' >"$T/ptable"   # one idle Claude Code session
cat >"$T/bin/pgrep" <<EOF
#!/bin/sh
[ -s $T/ssh ] && cat $T/ssh
EOF
cat >"$T/bin/ps" <<EOF
#!/bin/sh
if [ "\$1" = -A ]; then cat $T/ptable; else cat $T/etime; fi
EOF
echo No >"$T/lid"; echo 3032 >"$T/batt"; echo 0 >"$T/thermal"   # battery 3032 = 303.2 K = 30 °C
cat >"$T/bin/ioreg" <<EOF
#!/bin/sh
echo "      \"AppleClamshellState\" = \$(cat $T/lid)"
echo "      \"AppleClamshellCausesSleep\" = Yes"
echo "      \"VirtualTemperature\" = 9999"
echo "      \"Temperature\" = \$(cat $T/batt)"
EOF
cat >"$T/bin/osascript" <<EOF
#!/bin/sh
if [ "\$1" = -l ]; then cat $T/thermal; else echo "\$*" >>$T/notified; fi
EOF
cat >"$T/bin/sudo" <<EOF
#!/bin/sh
[ "\$1" = -k ] && shift
[ "\$1" = -n ] && shift
[ "\$1" = -l ] && { cat $T/sudoers; exit 0; }
p=\$(basename "\$1"); shift; exec "\$p" "\$@"
EOF
: >"$T/sudoers"
cat >"$T/bin/launchctl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$T/bin/sleep" <<EOF
#!/bin/sh
[ -f $T/during-sleep ] && sh $T/during-sleep
exit 0
EOF
chmod +x "$T/bin/"*

hook() { printf '{"session_id":"%s"%s}' "$2" "${3:-}" | HOME=$T PATH="$T/bin:$PATH" sh "$S" "$1"; cat "$T/state"; }
chk() { HOME=$T PATH="$T/bin:$PATH" sh "$S" check </dev/null; cat "$T/state"; }
t() { n=$((n + 1)); }

[ "$(hook on A)" = 1 ]; t           # turn starts
[ "$(hook on B)" = 1 ]; t           # second session
[ "$(hook off A)" = 1 ]; t          # B still mid-turn
[ "$(hook off B)" = 0 ]; t          # nobody busy
hook on C >/dev/null; touch -t 202001010000 "$T/.claude/coffee/busy/C"
[ "$(chk)" = 0 ]; t                 # stale marker (Esc or a crash) dropped; check reads no stdin
[ "$(hook on D)" = 1 ]
[ "$(hook off D ',"background_tasks":[{"id":"t1","type":"subagent"}]')" = 1 ]; t  # turn over, agent still working
[ "$(hook off D ',"background_tasks":[]')" = 0 ]; t                              # agent reported back
[ "$(hook on E)" = 1 ]
[ "$(hook off E ',"last_assistant_message":"done\n\"ok\""')" = 0 ]; t  # JSON escapes survive
[ ! -e "$T/slept" ]; t              # lid open: never forces sleep
echo Yes >"$T/lid"
[ "$(hook on F)" = 1 ]
[ ! -e "$T/slept" ]; t              # lid closed mid-turn: stays awake
[ "$(hook off F)" = 0 ]
[ -e "$T/slept" ]; t                # last turn ends with the lid closed: sleep now
rm "$T/slept"; touch "$T/noline"; hook on F >/dev/null
[ "$(hook off F)" = 0 ]; [ -e "$T/slept" ]; t   # ... also when pmset shows no SleepDisabled line for 0
rm "$T/noline"
rm "$T/slept"; hook on F >/dev/null
echo "touch $T/.claude/coffee/busy/F2" >"$T/during-sleep"
[ "$(hook off F)" = 0 ]; [ ! -e "$T/slept" ]; t     # a turn starts during the 1 s wait: no sleepnow
rm "$T/.claude/coffee/busy/F2"; hook on F >/dev/null
echo "echo 1 >$T/state" >"$T/during-sleep"
hook off F >/dev/null; [ ! -e "$T/slept" ]; t       # another hook disables sleep during the wait: no sleepnow
rm "$T/during-sleep"; echo 0 >"$T/state"; rm -f "$T/slept"
[ "$(hook on H)" = 1 ]; t           # heat guard: lid closed, cool: awake
echo 2 >"$T/thermal"
[ "$(hook on H)" = 0 ]; t           # serious thermal pressure: sleep allowed mid-turn ...
[ -e "$T/slept" ]; t                # ... and asleep now, though H is still busy
[ -e "$T/.claude/coffee/hot" ]; grep -q 'display notification' "$T/notified"; t  # tripped, and says why
echo 0 >"$T/thermal"; rm "$T/slept"
[ "$(hook on H)" = 0 ]; [ "$(chk)" = 0 ]; t   # cooled down in the bag: stays tripped (no dark-wake heating)
echo No >"$T/lid"
[ "$(hook on H)" = 1 ]; [ ! -e "$T/.claude/coffee/hot" ]; t   # lid opens: guard resets, Claude carries on
echo Yes >"$T/lid"; echo 3182 >"$T/batt"
[ "$(hook on H)" = 0 ]; t           # battery at 45 °C (318.2 K) trips it too; VirtualTemperature is ignored
echo No >"$T/lid"; echo 3032 >"$T/batt"; echo 3 >"$T/thermal"
[ "$(hook on H)" = 1 ]; t           # lid open: heat is macOS's business, not ours
echo Yes >"$T/lid"; echo 'HEAT_GUARD=0' >"$T/.claude/coffee/config"
[ "$(hook on H)" = 1 ]; t           # guard switched off in config
rm "$T/.claude/coffee/config"; echo 0 >"$T/thermal"; echo No >"$T/lid"
[ "$(hook off H)" = 0 ]; rm -f "$T/slept"
echo No >"$T/lid"
echo 4242 >"$T/ssh"                 # remote mode: logged in over SSH
[ "$(hook on G)" = 1 ]
[ "$(hook off G)" = 1 ]; t          # turn over, but the phone may send the next prompt
touch -t 202001010000 "$T/.claude/coffee/last"
[ "$(chk)" = 0 ]; t                 # quiet for 60 min and an old login: sleep allowed
echo 05:12 >"$T/etime"
[ "$(chk)" = 1 ]; t                 # login 5 min ago counts as activity
echo 01:05:12 >"$T/etime"
[ "$(chk)" = 0 ]; t                 # login 65 min ago doesn't
echo 'REMOTE_MINUTES=90' >"$T/.claude/coffee/config"
[ "$(chk)" = 1 ]; t                 # ... unless the config allows 90
echo 'REMOTE=0' >"$T/.claude/coffee/config"
echo 05:12 >"$T/etime"
[ "$(chk)" = 0 ]; t                 # remote mode switched off
rm "$T/.claude/coffee/config"; : >"$T/ssh"
[ "$(chk)" = 0 ]; t                 # logged out
quiet() { hook on Q >/dev/null; touch -t "$(date -v-"$1" +%Y%m%d%H%M)" "$T/.claude/coffee/busy/Q"; }
procs() { printf '  500     1  3-00:00:00  0.0 claude\n' >"$T/ptable"; printf '%s\n' "$@" >>"$T/ptable"; }
quiet 40M; [ "$(chk)" = 0 ]; t      # 40 min without a hook and Claude Code isn't working: stale
procs '  501   500       03:10  0.0 caffeinate -i -t 300'; quiet 40M
[ "$(chk)" = 1 ]; t                 # Claude Code's own caffeinate: one long tool call
procs '  501   500    02:00:00  0.3 node vite --port 5173'; quiet 40M
[ "$(chk)" = 0 ]; t                 # an idle dev server in the background: stale
procs '  501   500       50:00 98.0 python train.py'; quiet 40M
[ "$(chk)" = 1 ]; t                 # a background job using CPU: still at work
procs '  501   500       12:00  0.1 make -j8' '  502   501       00:03 40.0 cc -c parser.c'; quiet 40M
[ "$(chk)" = 1 ]; t                 # a build spawning compilers (a young process deep in the tree)
procs '  777     1       00:05 99.0 caffeinate -d'; quiet 40M
[ "$(chk)" = 0 ]; t                 # busy processes outside Claude Code don't count
procs; printf '  600     1  1-00:00:00  0.0 node /opt/lib/node_modules/@anthropic-ai/claude-code/cli.js\n  601   600       50:00 99.0 cargo build\n' >>"$T/ptable"
quiet 40M; [ "$(chk)" = 1 ]; t      # an npm-installed Claude Code counts as Claude Code
quiet 5H; [ "$(chk)" = 0 ]; t       # past MAX_QUIET_HOURS nothing keeps a quiet marker
quiet 40M; [ "$(chk)" = 1 ]
quiet 40M; hook on R >/dev/null; [ -e "$T/.claude/coffee/busy/Q" ]; t   # a hook goes by the last check's verdict ...
rm "$T/.claude/coffee/working"; hook on R >/dev/null; [ ! -e "$T/.claude/coffee/busy/Q" ]; t  # ... and without one, 30 min
hook off R >/dev/null; procs
echo 'Battery Power' >"$T/src"; echo 50 >"$T/pct"
[ "$(hook on V)" = 1 ]; t           # battery guard: on battery at 50%: awake
echo 20 >"$T/pct"; : >"$T/notified"
[ "$(hook on V)" = 0 ]; [ -e "$T/.claude/coffee/low" ]; t        # at 20%: sleep allowed, mid-turn
[ "$(hook on V)" = 0 ]; [ "$(grep -c 'Battery at 20%' "$T/notified")" = 1 ]; t   # one notification, not one per check
echo Yes >"$T/lid"; echo 1 >"$T/state"; rm -f "$T/slept"
hook on V >/dev/null; [ -e "$T/slept" ]; t   # lid closed: asleep now
echo No >"$T/lid"; echo 'AC Power' >"$T/src"
[ "$(hook on V)" = 1 ]; [ ! -e "$T/.claude/coffee/low" ]; t      # plugged in: carry on, guard cleared
echo 'Battery Power' >"$T/src"; echo 5 >"$T/pct"; echo 'LOW_BATTERY=0' >"$T/.claude/coffee/config"
[ "$(hook on V)" = 1 ]; t           # guard switched off in config
rm "$T/.claude/coffee/config"; echo 'AC Power' >"$T/src"; echo 100 >"$T/pct"
[ "$(hook off V)" = 0 ]
[ "$(hook on '../../x')" = 1 ]
[ -e "$T/.claude/coffee/busy/x" ]; t   # path characters stripped from the session id
out=$(HOME=$T PATH="$T/bin:$PATH" sh "$S" status)
[ "$(cat "$T/state")" = 1 ]; t      # status changes nothing ...
printf "%s\n" "$out" | grep -q "busy sessions  1"; t   # ... and reports
printf "%s\n" "$out" | grep -q "lid            open"; t
printf "%s\n" "$out" | grep -q "heat           battery 30 °C, thermal state nominal"; t   # real readings, faked here
printf "%s\n" "$out" | grep -q "power          on AC power, battery 100%"; t
printf "%s\n" "$out" | grep -q "sudo pmset     missing"; t   # no NOPASSWD rule ...
echo '    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' >"$T/sudoers"
HOME=$T PATH="$T/bin:$PATH" sh "$S" status | grep -q "sudo pmset     ok"; t   # ... and with one
[ -z "$(printf '{"session_id":"Q"}' | HOME=$T PATH="$T/bin:$PATH" sh "$S" on)" ]; t  # silent: nothing reaches Claude
if HOME=$T PATH="$T/bin:$PATH" sh "$S" bogus </dev/null 2>/dev/null; then exit 1; else [ $? = 1 ]; fi; t  # bad usage exits 1, never 2
echo "hook: all $n checks passed"
