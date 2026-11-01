#!/bin/sh
# The hook's scenarios, run against one platform backend: sh tests/hook.test.sh [darwin|linux|windows]
# (default: this machine's). tests/fixtures/<os>.sh fakes that system's commands, and uname, in a
# throwaway $HOME, so every backend runs on any machine. Your real sleep settings are never touched.
#
# The scenarios only use these generic knobs in $T; a fixture maps them to its fake commands:
#   state     1 while claude-coffee holds the machine awake, else 0 (the fake "hold" writes it)
#   slept     appears when the machine was put to sleep
#   lid       open | closed       thermal  0-3 (nominal … critical)      batt_c  battery °C
#   src, pct  ac | battery, and the charge in %
#   ssh       PIDs of the user's SSH logins (empty: none), etime their age ([[dd-]hh:]mm:ss)
#   ptable    the process table: pid ppid etime %cpu args, %cpu being recent use
#   notified  every notification's text, one per line
#   canhold   present when keeping awake needs no password; agent: present when the check is installed
# A fixture sets UNAME (what uname -s prints), HOLD_LABEL and AGENT_LABEL (status lines), and
# RELEASE_SLEEPS: 1 if the system sleeps by itself when the hold ends with the lid closed (logind),
# 0 if claude-coffee has to (macOS); its fakes then touch $T/slept on release or on "sleep now".
set -eu
R=$(cd "$(dirname "$0")/.." && pwd); S=$R/claude-coffee.sh
case ${1:-$(uname -s)} in
  darwin|Darwin) FX=darwin ;;
  linux|Linux) FX=linux ;;
  *) FX=windows ;;
esac
T=$(mktemp -d); n=0; rc=0
trap 'rc=$?; rm -rf "$T"; [ "$rc" = 0 ] || echo "hook ($FX): check $((n + 1)) failed" >&2' EXIT
mkdir "$T/bin"
echo 0 >"$T/state"; echo open >"$T/lid"; echo 0 >"$T/thermal"; echo 30 >"$T/batt_c"
echo ac >"$T/src"; echo 100 >"$T/pct"; : >"$T/notified"
: >"$T/ssh"; echo 30-00:00:00 >"$T/etime"   # no SSH login; any login is old
printf '  500     1  3-00:00:00  0.0 claude\n' >"$T/ptable"   # one idle Claude Code session

# Generic fakes; a fixture may replace them
cat >"$T/bin/pgrep" <<EOF
#!/bin/sh
[ -s $T/ssh ] && cat $T/ssh
EOF
cat >"$T/bin/ps" <<EOF
#!/bin/sh
if [ "\$1" = -A ]; then cat $T/ptable; else cat $T/etime; fi
EOF
cat >"$T/bin/sleep" <<EOF
#!/bin/sh
[ -f $T/during-sleep ] && sh $T/during-sleep
exit 0
EOF
UNAME= HOLD_LABEL= AGENT_LABEL= RELEASE_SLEEPS=0   # the fixture sets these
# shellcheck source=/dev/null
. "$R/tests/fixtures/$FX.sh"
printf '#!/bin/sh\necho %s\n' "$UNAME" >"$T/bin/uname"
chmod +x "$T/bin/"*

run() { HOME=$T PATH="$T/bin:$PATH" sh "$S" "$@"; }
hook() { printf '{"session_id":"%s"%s}' "$2" "${3:-}" | run "$1"; cat "$T/state"; }
chk() { run check </dev/null; cat "$T/state"; }
ago() { date -v-"$1"M +%Y%m%d%H%M 2>/dev/null || date -d "$1 minutes ago" +%Y%m%d%H%M; }
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
echo closed >"$T/lid"
[ "$(hook on F)" = 1 ]
[ ! -e "$T/slept" ]; t              # lid closed mid-turn: stays awake
[ "$(hook off F)" = 0 ]
[ -e "$T/slept" ]; t                # last turn ends with the lid closed: asleep
if [ "$RELEASE_SLEEPS" = 0 ]; then  # claude-coffee sleeps it explicitly, which has its own pitfalls:
  if [ "$FX" = darwin ]; then
    rm "$T/slept"; touch "$T/noline"; hook on F >/dev/null
    [ "$(hook off F)" = 0 ]; [ -e "$T/slept" ]; t   # ... also when pmset shows no SleepDisabled line for 0
    rm "$T/noline"
  fi
  rm -f "$T/slept"; hook on F >/dev/null
  echo "touch $T/.claude/coffee/busy/F2" >"$T/during-sleep"
  [ "$(hook off F)" = 0 ]; [ ! -e "$T/slept" ]; t     # a turn starts during the 1 s wait: no sleep
  rm "$T/.claude/coffee/busy/F2"; hook on F >/dev/null
  echo "echo 1 >$T/state" >"$T/during-sleep"
  hook off F >/dev/null; [ ! -e "$T/slept" ]; t       # another hook holds it again during the wait: no sleep
  rm "$T/during-sleep"; echo 0 >"$T/state"
fi
rm -f "$T/slept"
[ "$(hook on H)" = 1 ]; t           # heat guard: lid closed, cool: awake
echo 2 >"$T/thermal"
[ "$(hook on H)" = 0 ]; t           # serious thermal pressure: sleep allowed mid-turn ...
[ -e "$T/slept" ]; t                # ... and asleep now, though H is still busy
[ -e "$T/.claude/coffee/hot" ]; grep -q 'got hot' "$T/notified"; t  # tripped, and says why
echo 0 >"$T/thermal"; rm "$T/slept"
[ "$(hook on H)" = 0 ]; [ "$(chk)" = 0 ]; t   # cooled down in the bag: stays tripped (no dark-wake heating)
echo open >"$T/lid"
[ "$(hook on H)" = 1 ]; [ ! -e "$T/.claude/coffee/hot" ]; t   # lid opens: guard resets, Claude carries on
echo closed >"$T/lid"; echo 45 >"$T/batt_c"
[ "$(hook on H)" = 0 ]; t           # a battery at 45 °C trips it too
echo open >"$T/lid"; echo 30 >"$T/batt_c"; echo 3 >"$T/thermal"
[ "$(hook on H)" = 1 ]; t           # lid open: heat is the system's business, not ours
echo closed >"$T/lid"; echo 'HEAT_GUARD=0' >"$T/.claude/coffee/config"
[ "$(hook on H)" = 1 ]; t           # guard switched off in config
rm "$T/.claude/coffee/config"; echo 0 >"$T/thermal"; echo open >"$T/lid"
[ "$(hook off H)" = 0 ]; rm -f "$T/slept"
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
quiet() { hook on Q >/dev/null; touch -t "$(ago "$1")" "$T/.claude/coffee/busy/Q"; }
procs() { printf '  500     1  3-00:00:00  0.0 claude\n' >"$T/ptable"; printf '%s\n' "$@" >>"$T/ptable"; }
quiet 40; [ "$(chk)" = 0 ]; t       # 40 min without a hook and Claude Code isn't working: stale
if [ "$FX" = darwin ]; then         # only macOS has Claude Code's own keep-awake helper
  procs '  501   500       03:10  0.0 caffeinate -i -t 300'; quiet 40
  [ "$(chk)" = 1 ]; t               # Claude Code's own caffeinate: one long tool call
fi
procs '  501   500    02:00:00  0.3 node vite --port 5173'; quiet 40
[ "$(chk)" = 0 ]; t                 # an idle dev server in the background: stale
procs '  501   500       50:00 98.0 python train.py'; quiet 40
[ "$(chk)" = 1 ]; t                 # a background job using CPU: still at work
procs '  501   500       12:00  0.1 make -j8' '  502   501       00:03 40.0 cc -c parser.c'; quiet 40
[ "$(chk)" = 1 ]; t                 # a build spawning compilers (a young process deep in the tree)
procs '  777     1       00:05 99.0 caffeinate -d'; quiet 40
[ "$(chk)" = 0 ]; t                 # busy processes outside Claude Code don't count
procs; printf '  600     1  1-00:00:00  0.0 node /opt/lib/node_modules/@anthropic-ai/claude-code/cli.js\n  601   600       50:00 99.0 cargo build\n' >>"$T/ptable"
quiet 40; [ "$(chk)" = 1 ]; t       # an npm-installed Claude Code counts as Claude Code
quiet 300; [ "$(chk)" = 0 ]; t      # past MAX_QUIET_HOURS nothing keeps a quiet marker
quiet 40; [ "$(chk)" = 1 ]
quiet 40; hook on R >/dev/null; [ -e "$T/.claude/coffee/busy/Q" ]; t   # a hook goes by the last check's verdict ...
rm "$T/.claude/coffee/working"; hook on R >/dev/null; [ ! -e "$T/.claude/coffee/busy/Q" ]; t  # ... and without one, 30 min
hook off R >/dev/null; procs
echo battery >"$T/src"; echo 50 >"$T/pct"
[ "$(hook on V)" = 1 ]; t           # battery guard: on battery at 50%: awake
echo 20 >"$T/pct"; : >"$T/notified"
[ "$(hook on V)" = 0 ]; [ -e "$T/.claude/coffee/low" ]; t        # at 20%: sleep allowed, mid-turn
[ "$(hook on V)" = 0 ]; [ "$(grep -c 'Battery at 20%' "$T/notified")" = 1 ]; t   # one notification, not one per check
echo closed >"$T/lid"; echo 1 >"$T/state"; rm -f "$T/slept"
hook on V >/dev/null; [ -e "$T/slept" ]; t   # lid closed: asleep now
echo open >"$T/lid"; echo ac >"$T/src"
[ "$(hook on V)" = 1 ]; [ ! -e "$T/.claude/coffee/low" ]; t      # plugged in: carry on, guard cleared
echo battery >"$T/src"; echo 5 >"$T/pct"; echo 'LOW_BATTERY=0' >"$T/.claude/coffee/config"
[ "$(hook on V)" = 1 ]; t           # guard switched off in config
rm "$T/.claude/coffee/config"; echo ac >"$T/src"; echo 100 >"$T/pct"
[ "$(hook off V)" = 0 ]
[ "$(hook on '../../x')" = 1 ]
[ -e "$T/.claude/coffee/busy/x" ]; t   # path characters stripped from the session id
out=$(run status)
[ "$(cat "$T/state")" = 1 ]; t      # status changes nothing ...
printf "%s\n" "$out" | grep -q "busy sessions  1"; t   # ... and reports
printf "%s\n" "$out" | grep -q "lid            open"; t
printf "%s\n" "$out" | grep -q "heat           battery 30 °C, thermal state nominal"; t   # real readings, faked here
printf "%s\n" "$out" | grep -q "power          on AC power, battery 100%"; t
printf "%s\n" "$out" | grep -qF "$(printf '  %-14s missing' "$HOLD_LABEL")"; t   # can't keep awake without a password ...
touch "$T/canhold" "$T/agent"; out=$(run status)
printf "%s\n" "$out" | grep -qF "$(printf '  %-14s ok' "$HOLD_LABEL")"; t        # ... and can
printf "%s\n" "$out" | grep -qF "$(printf '  %-14s ok' "$AGENT_LABEL")"; t
[ -z "$(printf '{"session_id":"Q"}' | run on)" ]; t  # silent: nothing reaches Claude
if run bogus </dev/null 2>/dev/null; then exit 1; else [ $? = 1 ]; fi; t  # bad usage exits 1, never 2
echo "hook ($FX): all $n checks passed"
