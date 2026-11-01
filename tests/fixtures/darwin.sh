# shellcheck shell=sh disable=SC2034  # sourced by tests/hook.test.sh, which reads these variables
# Fixture for the macOS backend, sourced by tests/hook.test.sh. Fakes pmset, ioreg, osascript, sudo and
# launchctl on top of the generic knobs in $T (see tests/hook.test.sh).
UNAME=Darwin
HOLD_LABEL='sudo pmset'
AGENT_LABEL='launch agent'
RELEASE_SLEEPS=0   # macOS doesn't re-check a closed lid when sleep comes back: claude-coffee sleeps it

cat >"$T/bin/pmset" <<EOF
#!/bin/sh
# Real pmset prints "SleepDisabled 0" or, on some days, no line at all for 0; \$T/noline picks the latter
if [ "\$2" = batt ]; then
  if [ "\$(cat $T/src)" = battery ]; then s='Battery Power'; else s='AC Power'; fi
  printf "Now drawing from '%s'\\n -InternalBattery-0 (id=1)\\t%s%%; discharging; present: true\\n" "\$s" "\$(cat $T/pct)"
  exit 0
fi
if [ "\$1" = -g ]; then [ -e $T/noline ] && [ "\$(cat $T/state)" = 0 ] && exit 0; printf ' SleepDisabled\t\t%s\n' "\$(cat $T/state)"; exit 0; fi
if [ "\$1" = sleepnow ]; then touch $T/slept; exit 0; fi
echo "\$3" >$T/state
EOF

cat >"$T/bin/ioreg" <<EOF
#!/bin/sh
if [ "\$(cat $T/lid)" = closed ]; then l=Yes; else l=No; fi
echo "      \"AppleClamshellState\" = \$l"
echo "      \"AppleClamshellCausesSleep\" = Yes"
echo "      \"VirtualTemperature\" = 9999"
echo "      \"Temperature\" = \$(awk -v c="\$(cat $T/batt_c)" 'BEGIN { printf "%d", (c + 273.15) * 10 + 0.5 }')"
EOF

cat >"$T/bin/osascript" <<EOF
#!/bin/sh
if [ "\$1" = -l ]; then cat $T/thermal; else echo "\$*" >>$T/notified; fi
EOF

cat >"$T/bin/sudo" <<EOF
#!/bin/sh
[ "\$1" = -k ] && shift
[ "\$1" = -n ] && shift
if [ "\$1" = -l ]; then
  [ -e $T/canhold ] && echo '    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1'
  exit 0
fi
p=\$(basename "\$1"); shift; exec "\$p" "\$@"
EOF

cat >"$T/bin/launchctl" <<EOF
#!/bin/sh
[ "\$1" = print ] && { [ -e $T/agent ]; exit; }
exit 0
EOF
