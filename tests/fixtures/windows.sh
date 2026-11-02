# shellcheck shell=sh disable=SC2034  # sourced by tests/hook.test.sh, which reads these variables
# Fixture for the Windows backend (Git Bash), sourced by tests/hook.test.sh and tests/install-windows.test.sh.
# Fakes powercfg, powershell (the script's PowerShell half, and the installer's), cygpath, reg, schtasks and
# tasklist on top of the generic knobs in $T (see tests/hook.test.sh). Every call is logged in $T/calls.
#   $T/pcfg   the power plan the fake powercfg keeps: SETTING-GUID AC DC per line
#   pcfg-fail powercfg fails; agent: the scheduled task exists; canhold: no Group Policy on sleep settings
UNAME=MINGW64_NT-10.0-26100
HOLD_LABEL='power plan'
AGENT_LABEL='scheduled task'
RELEASE_SLEEPS=0   # assumed, not verified: Windows doesn't look at a closed lid again when sleep comes back

FX_LID='4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936'
FX_IDLE='238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
# The plan as you set it: lid sleeps, sleep after 30 min plugged in, 15 on battery
fx_plan() { printf '%s\n' "${FX_LID#* } $1" "${FX_IDLE#* } $2" >"$T/pcfg"; }
fx_plan '1 1' '1800 900'
fx() { printf '#!/bin/sh\nT=%s\n' "$T" >"$T/bin/$1"; cat >>"$T/bin/$1"; }

# The localized, CRLF text of the real thing (Norwegian here); the last two hex numbers are AC and DC
fx powercfg <<'EOF'
echo "powercfg $*" >>$T/calls
[ -e $T/pcfg-fail ] && exit 1
case $1 in
  -getactivescheme) printf 'GUID for strømstyringsoppsett: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balansert)\r\n' ;;
  -query)
    v=$(awk -v s="$4" '$1 == s { print $2, $3 }' $T/pcfg)
    [ -n "$v" ] || exit 1
    set -- $v
    printf 'GUID for strømstyringsoppsett: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balansert)\r\n'
    printf '    Minste mulige innstilling: 0x00000000\r\n    Største mulige innstilling: 0xffffffff\r\n'
    printf '  Gjeldende indeks for vekselstrøm: 0x%08x\r\n  Gjeldende indeks for likestrøm: 0x%08x\r\n' "$1" "$2" ;;
  -setacvalueindex|-setdcvalueindex)
    awk -v s="$4" -v v="$5" -v c="$1" '$1 == s { if (c == "-setacvalueindex") $2 = v; else $3 = v } { print }' \
      $T/pcfg >$T/pcfg.new && mv $T/pcfg.new $T/pcfg ;;
  -setactive)   # what counts: is sleep off (lid does nothing, never sleeps)?
    awk '$2 != 0 || $3 != 0 { on = 1 } END { print on ? 0 : 1 }' $T/pcfg >$T/state ;;
esac
EOF

# What the script's PowerShell half prints for "gather full", from the knobs ("gather ssh": the ssh lines)
fx fx-cache <<'EOF'
if [ "$1" != ssh ]; then
  echo "lid $(cat $T/lid)"
  if [ "$(cat $T/src)" = battery ]; then echo onbatt 1; else echo onbatt 0; fi
  echo "charge $(cat $T/pct)"
  echo "thermal $(cat $T/thermal)"
  echo "battery $(cat $T/batt_c)"
fi
for p in $(cat $T/ssh); do echo "ssh $p $(cat $T/etime)"; done
[ "$1" = ssh ] || sed 's/^ */proc /' $T/ptable
EOF

# The state knob and the backend's record of its hold ($WH, plus the plan's zeros) say the same thing
fx fx-held <<'EOF'
c=$T/.claude/coffee; mkdir -p $c
if [ "$(cat $T/state)" = 1 ]; then
  [ -e $c/win.held ] && exit 0
  printf '%s\n' 381b4222-f694-41f0-9685-ff5bb260df2e \
    '4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1 1' \
    '238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 1800 900' >$c/win.held
  awk '{ $2 = 0; $3 = 0; print }' $T/pcfg >$T/pcfg.new && mv $T/pcfg.new $T/pcfg
elif [ -e $c/win.held ]; then
  rm $c/win.held
  printf '%s\n' '5ca83367-6e45-459f-a27b-476b1d01c936 1 1' '29f6c1db-86da-48c5-9fdb-f2b67b1f44da 1800 900' >$T/pcfg
fi
EOF

# Before every run: the hold as the knobs say, and the cache as a check just now would have left it
fx_sync() { sh "$T/bin/fx-held"; sh "$T/bin/fx-cache" full >"$T/.claude/coffee/win.cache"; }

# The generic sleep, and then the knobs again: something during the wait may have set state
fx sleep <<'EOF'
[ -f $T/during-sleep ] && sh $T/during-sleep
sh $T/bin/fx-held
exit 0
EOF

# powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File SCRIPT ARGS..., output in CRLF
fx powershell <<'EOF'
while [ $# -gt 0 ] && [ "$1" != -File ]; do shift; done
f=$2; shift 2
echo "powershell ${f##*/} $*" >>$T/calls
case ${f##*/} in
  claude-coffee.ps1)
    grep -q '^param(' "$f" || exit 1   # the script did write its PowerShell half first
    case $1 in
      gather) sh $T/bin/fx-cache "$2" | awk '{ printf "%s\r\n", $0 }' ;;
      lid) printf '%s\r\n' "$(cat $T/lid)" ;;
      sleep) touch $T/slept ;;
      notify) echo "$2" >>$T/notified ;;
    esac ;;
  *)   # the installer's, which registers the scheduled task
    cp "$f" $T/task.ps1; printf '%s\n' "$@" >$T/task.args
    [ -e $T/task-fail ] && exit 1
    touch $T/agent ;;
esac
EOF

# cygpath -u|-w|-m [-s] PATH: there are no drive letters here, so a path stays as it is; / is where Git is
fx cygpath <<'EOF'
for a; do p=$a; done
if [ "$p" = / ]; then echo $T/git; else echo "$p"; fi
EOF

fx reg <<'EOF'
echo "reg $*" >>$T/calls
[ ! -e $T/canhold ]   # reg query finds a Group Policy key, unless we can hold
EOF

fx schtasks <<'EOF'
echo "schtasks $*" >>$T/calls
case $1 in
  /query) [ -e $T/agent ] ;;
  /delete) [ -e $T/task-stuck ] && exit 1; rm -f $T/agent ;;
esac
EOF

fx tasklist <<'EOF'
echo "tasklist $*" >>$T/calls
[ -s $T/ssh ] || { echo 'INFO: Ingen oppgaver som samsvarer med de angitte kriteriene, kjører.'; exit 0; }
for p in $(cat $T/ssh); do printf '"sshd-session.exe","%s","Services","0","8 112 K"\r\n' "$p"; done
EOF
