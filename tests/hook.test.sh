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
#   boot      the system's boot ID (absent: none); a different one means it restarted
#   net       up | down: whether the API answers (curl); netlag: down for that many more checks first
# A fixture sets UNAME (what uname -s prints), HOLD_LABEL and AGENT_LABEL (status lines), and
# RELEASE_SLEEPS: 1 if the system sleeps by itself when the hold ends with the lid closed (logind),
# 0 if claude-coffee has to (macOS); its fakes then touch $T/slept on release or on "sleep now".
# A fixture may define fx_sync, called before every run, to turn the knobs into the files its backend
# reads (a fake /sys tree, a cache), and may export variables for the script (say, a sysfs root).
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
cat >"$T/bin/curl" <<EOF
#!/bin/sh
if [ "\$(cat $T/netlag 2>/dev/null || echo 0)" -gt 0 ]; then echo \$((\$(cat $T/netlag) - 1)) >$T/netlag; exit 7; fi
[ "\$(cat $T/net 2>/dev/null || echo up)" = up ] || exit 7
EOF
UNAME='' HOLD_LABEL='' AGENT_LABEL='' RELEASE_SLEEPS=0   # the fixture sets these
# shellcheck source=/dev/null
. "$R/tests/fixtures/$FX.sh"
printf '#!/bin/sh\necho %s\n' "$UNAME" >"$T/bin/uname"
chmod +x "$T/bin/"*

run() { if command -v fx_sync >/dev/null 2>&1; then fx_sync; fi; HOME=$T PATH="$T/bin:$PATH" sh "$S" "$@"; }
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
    rm -f "$T/slept"; hook on F >/dev/null; echo 3 >"$T/klag"
    [ "$(hook off F)" = 0 ]; [ -e "$T/slept" ]; [ "$(cat "$T/klag")" = 0 ]; t   # ... once the kernel's own flag lets go
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
echo 'AWAKE_ON_AC=1' >"$T/.claude/coffee/config"; echo closed >"$T/lid"; rm -f "$T/slept"
[ "$(chk)" = 1 ]; [ ! -e "$T/slept" ]; t     # AWAKE_ON_AC: plugged in, Claude idle, lid closed: awake
hook on X >/dev/null; [ "$(hook off X)" = 1 ]; [ ! -e "$T/slept" ]; t   # a turn ends: still awake
run status </dev/null | grep -q '^  power .*; AWAKE_ON_AC keeps it awake while plugged in$'; t
echo battery >"$T/src"
[ "$(chk)" = 0 ]; [ -e "$T/slept" ]; t       # unplugged with the lid closed: asleep at the next check
rm "$T/slept"; [ "$(chk)" = 0 ]; [ ! -e "$T/slept" ]; t   # ... and it stays that way on battery
echo ac >"$T/src"; [ "$(chk)" = 1 ]; echo 3 >"$T/thermal"
[ "$(chk)" = 0 ]; [ -e "$T/slept" ]; t       # too hot on the charger: the heat guard still applies
echo 0 >"$T/thermal"; echo open >"$T/lid"; rm "$T/slept"
[ "$(chk)" = 1 ]; t                          # lid opens: guard reset, awake on the charger again
rm "$T/.claude/coffee/config"
[ "$(chk)" = 0 ]; t                          # off by default
# Auto-continue: the internet cuts a turn short (StopFailure), and "wait" carries it on when it's back
O=$T/.claude/coffee/offline; N=$T/.claude/coffee/busy/N
lost='API Error: Connection refused — a firewall or proxy may be blocking it (ECONNREFUSED)'
dropped() { printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"%s","last_assistant_message":"%s","transcript_path":"%s"}' "$1" "${3:-server_error}" "$2" "$T/tr"; }
waits() { dropped "$@" | run wait 2>"$T/woke"; }
said() { printf '%s\n' "$1" | head -n 1 | jq -r .terminalSequence; }   # the title a hook's output sets
is() { printf '\033]0;%s\007' "$1"; }
printf '{"type":"ai-title","aiTitle":"Old name"}\n{"type":"user"}\n{"type":"ai-title","aiTitle":"Fixing tests"}\n' >"$T/tr"
echo closed >"$T/lid"; rm -f "$T/slept"
[ "$(hook on N)" = 1 ]
out=$(dropped N "$lost" | run off); [ "$(cat "$T/state")" = 1 ]; [ ! -e "$T/slept" ]; t   # cut short, lid closed: stays up to carry on
[ "$(said "$out")" = "$(is 'Fixing tests · ☕ Waiting for the internet · claude-coffee')" ]; t   # ... and the session's title says so
if waits N "$lost"; then exit 1; else [ $? = 2 ]; fi; t                    # back already: wakes Claude (exit 2) ...
grep -q 'is back' "$T/woke"; grep -qF "$lost" "$T/woke"; grep -q 'Carry on with the task' "$T/woke"; t   # ... saying why
[ -e "$N" ]; [ ! -e "$O/N" ]; [ "$(cat "$T/state")" = 1 ]; t               # ... and stays up for that turn
: >"$T/notified"; echo 2 >"$T/netlag"
if waits N "$lost"; then exit 1; else [ $? = 2 ]; fi; t                    # gone for two checks, then back: carries on
grep -q "internet's gone" "$T/notified"; grep -q "It's back" "$T/notified"; t   # little Claude frets, then cheers
if waits N "$lost"; then exit 1; fi                                        # a third try in a row
waits N "$lost"; [ ! -e "$N" ]; [ "$(cat "$T/state")" = 0 ]; [ -e "$T/slept" ]; t   # a fourth, no tool call between: gives up, sleeps
grep -q 'keeps failing' "$T/notified"; t
out=$(hook on N ",\"hook_event_name\":\"PreToolUse\",\"transcript_path\":\"$T/tr\""); [ "$(printf '%s\n' "$out" | tail -n 1)" = 1 ]; [ ! -e "$O/N.n" ]; t   # a tool call is progress: the tries start over
[ "$(said "$out")" = "$(is 'Fixing tests · 🎉 Woho! Internet is back')" ]; t   # ... and the woken turn's first event cheers
echo down >"$T/net"; echo 'OFFLINE_MINUTES=0' >"$T/.claude/coffee/config"; rm -f "$T/slept"
waits N "$lost"; [ ! -e "$N" ]; [ "$(cat "$T/state")" = 0 ]; [ -e "$T/slept" ]; t   # no internet for OFFLINE_MINUTES: gives up, sleeps
grep -q 'Still no internet' "$T/notified"; t
rm "$T/.claude/coffee/config"; out=$(hook on N ",\"transcript_path\":\"$T/tr\"")
[ "$(said "$out")" = "$(is 'Fixing tests')" ]; [ "$(hook on N)" = 1 ]; t   # the next one: the session's title back, and then quiet
echo "rm -f $O/N" >"$T/during-sleep"
waits N "$lost"; [ -e "$N" ]; [ "$(cat "$T/state")" = 1 ]; t               # you type meanwhile: it bows out, your turn goes on
rm "$T/during-sleep"; touch "$T/.claude/coffee/hot"; rm -f "$T/slept"
waits N "$lost"; [ ! -e "$N" ]; [ "$(cat "$T/state")" = 0 ]; t             # a guard steps in: no carrying on
echo open >"$T/lid"; [ "$(hook on N)" = 1 ]; [ ! -e "$T/.claude/coffee/hot" ]; echo closed >"$T/lid"; rm -f "$T/slept"
[ "$(dropped N 'API Error: Rate limit reached' rate_limit | run off; cat "$T/state")" = 0 ]; [ -e "$T/slept" ]; t   # a rate limit isn't the internet
waits N 'API Error: Rate limit reached' rate_limit; t                     # ... so nothing waits
[ "$(hook on N)" = 1 ]
[ "$(dropped N 'API Error: Internal server error' | run off; cat "$T/state")" = 0 ]; t   # nor is a server error
printf '{"type":"custom-title","customTitle":"Renamed"}\n{"type":"ai-title","aiTitle":"Newer"}\n' >>"$T/tr"   # a /rename beats a newer made-up title
dropped N "$lost" | run off >/dev/null; [ "$(said "$(hook on N ",\"transcript_path\":\"$T/tr\"")")" = "$(is 'Renamed')" ]; t   # you type while it waits: the title goes back, no cheering
echo 'AUTO_CONTINUE=0' >"$T/.claude/coffee/config"; [ "$(hook on N)" = 1 ]
[ "$(dropped N "$lost" | run off; cat "$T/state")" = 0 ]; waits N "$lost"; t   # switched off in config
rm "$T/.claude/coffee/config"; [ "$(hook on N)" = 1 ]; mkdir -p "$O"; echo "99999 $(($(date +%s) - 900))" >"$O/N"
out=$(run status)
printf '%s\n' "$out" | grep -q 'auto-continue  waiting for the internet: gone 15 min, gives up in 45 min'; t
printf '%s\n' "$out" | grep -qF "little Claude (o_o;) \"This task is far too complex for me. I'm a shell script.\""; t
rm "$O/N"; [ "$(hook off N ',"hook_event_name":"Stop"')" = 0 ]; echo open >"$T/lid"; echo up >"$T/net"; rm -f "$T/slept"
run status | grep -q "auto-continue  on: after a lost connection, carries on once it's back (waits up to 60 min)"; t
if [ "$FX" != windows ]; then       # Windows has no cheap boot ID
  echo boot-1 >"$T/boot"; [ "$(hook on X1)" = 1 ]; [ -e "$T/.claude/coffee/busy/X1" ]; t   # first run with one: live markers stay
  echo boot-2 >"$T/boot"; echo 1 >"$T/state"   # restarted mid-turn; macOS keeps disablesleep
  [ "$(chk)" = 0 ]; [ ! -e "$T/.claude/coffee/busy/X1" ]; t   # that session is gone: its fresh marker too
  [ "$(hook on X2)" = 1 ]; [ "$(hook off X2)" = 0 ]; t         # turns after the restart as usual
  rm "$T/boot"
fi
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
[ -z "$(dropped Q "$lost" | run wait 2>/dev/null)" ]; t   # ... "wait" neither: it speaks on stderr, when it wakes Claude
if run bogus </dev/null 2>/dev/null; then exit 1; else [ $? = 1 ]; fi; t  # bad usage exits 1, never 2
echo "hook ($FX): all $n checks passed"
