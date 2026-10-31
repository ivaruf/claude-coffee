#!/bin/sh
# Runs claude-coffee.sh against fake pmset, sudo, ioreg, pgrep and ps in a throwaway $HOME.
# Your real sleep settings are never touched, so this is safe to run at any time.
set -eu
S=$(cd "$(dirname "$0")/.." && pwd)/claude-coffee.sh
T=$(mktemp -d); n=0
trap 'rc=$?; rm -rf "$T"; [ $rc = 0 ] || echo "hook: check $((n + 1)) failed" >&2' EXIT
mkdir "$T/bin"; echo 0 >"$T/state"
cat >"$T/bin/pmset" <<EOF
#!/bin/sh
if [ "\$1" = -g ]; then [ "\$(cat $T/state)" = 1 ] && printf ' SleepDisabled\t\t1\n'; exit 0; fi
if [ "\$1" = sleepnow ]; then touch $T/slept; exit 0; fi
echo "\$3" >$T/state
EOF
: >"$T/ssh"; echo 30-00:00:00 >"$T/etime"   # no SSH login; any login is old
cat >"$T/bin/pgrep" <<EOF
#!/bin/sh
[ -s $T/ssh ] && cat $T/ssh
EOF
cat >"$T/bin/ps" <<EOF
#!/bin/sh
cat $T/etime
EOF
echo No >"$T/lid"
cat >"$T/bin/ioreg" <<EOF
#!/bin/sh
echo "      \"AppleClamshellState\" = \$(cat $T/lid)"
echo "      \"AppleClamshellCausesSleep\" = Yes"
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
[ "$(hook on '../../x')" = 1 ]
[ -e "$T/.claude/coffee/busy/x" ]; t   # path characters stripped from the session id
out=$(HOME=$T PATH="$T/bin:$PATH" sh "$S" status)
[ "$(cat "$T/state")" = 1 ]; t      # status changes nothing ...
printf "%s\n" "$out" | grep -q "busy sessions  1"; t   # ... and reports
printf "%s\n" "$out" | grep -q "lid            open"; t
printf "%s\n" "$out" | grep -q "sudo pmset     missing"; t   # no NOPASSWD rule ...
echo '    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1' >"$T/sudoers"
HOME=$T PATH="$T/bin:$PATH" sh "$S" status | grep -q "sudo pmset     ok"; t   # ... and with one
[ -z "$(printf '{"session_id":"Q"}' | HOME=$T PATH="$T/bin:$PATH" sh "$S" on)" ]; t  # silent: nothing reaches Claude
if HOME=$T PATH="$T/bin:$PATH" sh "$S" bogus </dev/null 2>/dev/null; then exit 1; else [ $? = 1 ]; fi; t  # bad usage exits 1, never 2
echo "hook: all $n checks passed"
