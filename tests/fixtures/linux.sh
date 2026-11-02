# shellcheck shell=sh disable=SC2034  # sourced by tests/hook.test.sh, which reads these variables
# Fixture for the Linux backend, sourced by tests/hook.test.sh (and tests/install-linux.test.sh). Fakes
# systemd (systemctl --user, systemd-run, systemd-inhibit, busctl), notify-send and ps, and builds a
# fake /sys from the generic knobs in $T (see tests/hook.test.sh). Every call to a fake systemd tool is
# logged in $T/log. Linux-only knobs: $T/docked (an external display), $T/nobus (logind unreachable),
# $T/nosystemd (no user manager), $T/stuck (the lock won't stop), $T/inhibitors (logind's list, JSON).
UNAME=Linux
HOLD_LABEL='logind lock'
AGENT_LABEL='systemd timer'
RELEASE_SLEEPS=1   # logind re-checks a closed lid when the last lock goes, and sleeps unless docked
export CLAUDE_COFFEE_ROOT="$T/root"   # the backend reads $T/root/sys and $T/root/proc

# The user manager: the lock's transient unit is $T/state, the timer is $T/agent
cat >"$T/bin/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >>$T/log
[ "\$1" = --user ] || exit 1
[ -e $T/nosystemd ] && { echo "Failed to connect to bus: No medium found" >&2; exit 1; }
for a; do case \$a in -*) ;; *) v=\$a; break ;; esac; done
for u; do :; done
case \$v in
  is-active)
    case \$u in
      claude-coffee-awake*) [ "\$(cat $T/state)" = 1 ]; exit ;;
      claude-coffee.timer) [ -e $T/agent ]; exit ;;
      *) exit 3 ;;
    esac ;;
  stop)
    case \$u in claude-coffee-awake*)
      [ -e $T/stuck ] && exit 1
      if [ "\$(cat $T/state)" = 1 ]; then
        echo 0 >$T/state
        if [ "\$(cat $T/lid)" = closed ] && [ ! -e $T/docked ]; then touch $T/slept; fi
      fi ;;
    esac ;;
  start|restart) touch $T/agent ;;
  enable) case " \$* " in *" --now "*) touch $T/agent ;; esac ;;
  disable) rm -f $T/agent ;;
  suspend|hibernate|hybrid-sleep|suspend-then-hibernate) touch $T/slept ;;
esac
exit 0
EOF
# Only the exact lock holds: sleep, idle and the lid switch, blocking, in the named unit
cat >"$T/bin/systemd-run" <<EOF
#!/bin/sh
echo "systemd-run \$*" >>$T/log
case " \$* " in *" --user "*" --unit=claude-coffee-awake "*) ;; *) exit 1 ;; esac
case " \$* " in *" --what=sleep:idle:handle-lid-switch --mode=block "*) ;; *) exit 1 ;; esac
if [ "\$(cat $T/state)" = 1 ]; then echo "Unit claude-coffee-awake.service already exists." >&2; exit 1; fi
echo 1 >$T/state
EOF
cat >"$T/bin/systemd-inhibit" <<EOF
#!/bin/sh
echo "systemd-inhibit \$*" >>$T/log
[ -e $T/canhold ]
EOF
cat >"$T/bin/busctl" <<EOF
#!/bin/sh
echo "busctl \$*" >>$T/log
[ -e $T/nobus ] && exit 1
case " \$* " in
  *" get-property "*" LidClosed Docked ")
    if [ "\$(cat $T/lid)" = closed ]; then echo 'b true'; else echo 'b false'; fi
    if [ -e $T/docked ]; then echo 'b true'; else echo 'b false'; fi ;;
  *" ListInhibitors"*)
    if [ -s $T/inhibitors ]; then cat $T/inhibitors; else echo '{"type":"a(ssssuu)","data":[[]]}'; fi ;;
  *) exit 1 ;;
esac
EOF
cat >"$T/bin/notify-send" <<EOF
#!/bin/sh
echo "\$*" >>$T/notified
EOF
cat >"$T/bin/ps" <<EOF
#!/bin/sh
if [ "\$1" = -A ]; then cat $T/ps-linux; else cat $T/etime; fi
EOF

# shellcheck disable=SC2317  # called by tests/hook.test.sh before every run
fx_sync() {
  fx_now=$(date +%s)
  mkdir -p "$T/.claude/coffee"
  # ps: procps shows a lifetime %cpu, so the knob's recent %cpu has to come from comparing CPU time with
  # a snapshot. Here every process older than a minute spent its earlier life at the opposite load
  # (a dev server busy only at start, a job that sat idle until a minute ago), and $C/cpu holds what a
  # check a minute ago saw. So reading the lifetime %cpu gets those scenarios wrong
  awk -v now="$fx_now" -v snap="$T/.claude/coffee/cpu" -v ps="$T/ps-linux" '
    function secs(s,  n, t) { n = split(s, t, /[-:]/); return t[n] + 60 * t[n - 1] + 3600 * t[n - 2] + 86400 * t[n - 3] }
    function hms(x) { return (x >= 86400 ? int(x / 86400) "-" : "") sprintf("%02d:%02d:%02d", int(x % 86400 / 3600), int(x % 3600 / 60), x % 60) }
    BEGIN { print now - 60 > snap; printf "" > ps }
    { e = secs($3); r = $4 + 0
      if (e > 60) {
        early = int((e - 60) * (100 - r) / 100 + 0.5); used = early + int(r * 60 / 100 + 0.5); life = used * 100 / e
        print $1, now - e, early > snap
      } else { used = int(r * e / 100 + 0.5); life = r }
      a = $0; sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", a)
      printf "%6d %6d %11s %11s %5.1f %s\n", $1, $2, $3, hms(used), life, a > ps }' "$T/ptable"

  # /proc's boot ID, from the boot knob
  mkdir -p "$T/root/proc/sys/kernel/random"
  if [ -e "$T/boot" ]; then cp "$T/boot" "$T/root/proc/sys/kernel/random/boot_id"; else rm -f "$T/root/proc/sys/kernel/random/boot_id"; fi

  # /sys: a charger, the battery, a mouse's battery, and three thermal zones
  read -r fx_src <"$T/src"; read -r fx_pct <"$T/pct"; read -r fx_c <"$T/batt_c"; read -r fx_th <"$T/thermal"
  fx_p=$T/root/sys/class/power_supply; fx_z=$T/root/sys/class/thermal
  mkdir -p "$fx_p/AC" "$fx_p/BAT0" "$fx_p/hidpp_battery_0" "$fx_z/thermal_zone0" "$fx_z/thermal_zone1" "$fx_z/thermal_zone2"
  echo Mains >"$fx_p/AC/type"
  if [ "$fx_src" = ac ]; then echo 1; else echo 0; fi >"$fx_p/AC/online"
  echo Battery >"$fx_p/BAT0/type"; echo "$fx_pct" >"$fx_p/BAT0/capacity"; echo $((fx_c * 10)) >"$fx_p/BAT0/temp"
  if [ "$fx_src" = battery ]; then echo Discharging; elif [ "$fx_pct" = 100 ]; then echo Full; else echo Charging; fi >"$fx_p/BAT0/status"
  # A wireless mouse (scope Device), nearly flat: never the computer's battery
  echo Battery >"$fx_p/hidpp_battery_0/type"; echo Device >"$fx_p/hidpp_battery_0/scope"
  echo 5 >"$fx_p/hidpp_battery_0/capacity"; echo Discharging >"$fx_p/hidpp_battery_0/status"
  # The CPU follows the thermal knob: passive (throttling) at 95 °C, critical at 105 °C
  case $fx_th in 0) fx_t=45000 ;; 1) fx_t=80000 ;; 2) fx_t=95000 ;; *) fx_t=101000 ;; esac
  echo "$fx_t" >"$fx_z/thermal_zone0/temp"
  echo passive >"$fx_z/thermal_zone0/trip_point_0_type"; echo 95000 >"$fx_z/thermal_zone0/trip_point_0_temp"
  echo critical >"$fx_z/thermal_zone0/trip_point_1_type"; echo 105000 >"$fx_z/thermal_zone0/trip_point_1_temp"
  # Warm, past trip points that don't mean heat: a fan step (active) and an unset passive one (0)
  echo 55000 >"$fx_z/thermal_zone1/temp"
  echo active >"$fx_z/thermal_zone1/trip_point_0_type"; echo 50000 >"$fx_z/thermal_zone1/trip_point_0_temp"
  echo passive >"$fx_z/thermal_zone1/trip_point_1_type"; echo 0 >"$fx_z/thermal_zone1/trip_point_1_temp"
  # No temperature to read (a sensor that's switched off)
  echo hot >"$fx_z/thermal_zone2/trip_point_0_type"; echo 45000 >"$fx_z/thermal_zone2/trip_point_0_temp"
}
