#!/bin/sh
# claude-coffee: keep the computer awake, lid closed too, while any Claude Code session is mid-turn.
# https://github.com/ivaruf/claude-coffee
#
# usage: claude-coffee.sh on|off   Claude Code hooks (hook JSON on stdin)
#        claude-coffee.sh check    the every-minute job (launchd, a systemd timer, Task Scheduler)
#        claude-coffee.sh status   for you; changes nothing

C=~/.claude/coffee
STALE_MINUTES=30    # drop a marker no hook has touched for this long (Esc never fires Stop) ...
MAX_QUIET_HOURS=4   # ... unless Claude Code is still at work (a long tool call, a build); this caps that
REMOTE=1            # 0 = no remote mode
REMOTE_MINUTES=60   # remote mode lapses this long after the last hook event and the SSH login
HEAT_GUARD=1        # 0 = never let heat end a turn early
HOT_BATTERY_C=45    # with the lid closed, a battery this hot (°C) means sleep, mid-turn or not
LOW_BATTERY=20      # on battery at this charge (%) or less, stop keeping the Mac awake; 0 = never
# shellcheck source=/dev/null
[ -f "$C/config" ] && . "$C/config"
D=$C/busy   # one marker file per session that is mid-turn
L=$C/last   # touched on every hook event
H=$C/hot    # the heat guard tripped; stays until the lid opens
B=$C/low    # the battery guard tripped; goes when the Mac is plugged in or charged above LOW_BATTERY
mkdir -p "$D"

# Platform layer: everything OS-specific is in these functions, and the logic below only calls them.
#   held          prints 1 while sleep is switched off by us, else 0. Hooks call it every time: keep it
#                 fast (no PowerShell: a state file, a quick systemctl, pmset -g)
#   hold 1|0      switches sleep off (1) or back on (0), lid close included. Only called on a change
#   lid_state     prints 2 if the lid is closed and that normally means sleep, 1 if it's closed but
#                 something keeps the machine up (an external display), 0 if open or there's no lid
#   lid_closed    exit 0 if the lid is closed, whatever that means for sleep
#   sleep_now     puts the machine to sleep, for when the OS won't by itself after "hold 0" with the
#                 lid already closed (macOS won't; logind will, so on Linux it does nothing)
#   heat          sets thermal (0-3: nominal, fair, serious, critical) and battery (°C); empty = unknown.
#                 Hooks call it only with the lid closed and work going on
#   power         sets onbatt (1 on battery, else 0) and charge (%, empty without a battery). Hooks call
#                 it while work goes on, so it must be fast too (Windows: read the check's cache)
#   notify TEXT   shows a desktop notification
#   procs         prints the process table: pid ppid etime %cpu args, where %cpu is recent use (about
#                 the last minute), not a lifetime average, and etime is [[dd-]hh:]mm:ss. Only the check
#                 calls it, so it may be slow
#   ssh_logins    prints the PIDs of the user's SSH logins, exit 1 if none; login_ages PIDS: their etimes
#   can_hold      exit 0 if hold works without a password (for status, labelled HOLD_LABEL)
#   agent_loaded  exit 0 if the every-minute check is installed (for status, labelled AGENT_LABEL)
#   OWN_KEEPAWAKE the helper Claude Code itself runs during a turn (macOS: caffeinate), or empty
#   MACHINE       what to call the computer in notifications
case $(uname -s) in
Darwin)
  MACHINE=Mac OWN_KEEPAWAKE=caffeinate HOLD_LABEL='sudo pmset' AGENT_LABEL='launch agent'
  # pmset -g shows "SleepDisabled 1", "SleepDisabled 0", or no line for 0: read the value, never the line
  held() { pmset -g | awk '/SleepDisabled/ { v = $2 } END { print (v == 1) ? 1 : 0 }'; }
  hold() { sudo -n /usr/bin/pmset -a disablesleep "$1" >/dev/null; }
  lid_state() { ioreg -r -k AppleClamshellState -d 1 | grep -cE '"AppleClamshell(State|CausesSleep)" = Yes'; }
  lid_closed() { ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'; }
  sleep_now() { pmset sleepnow >/dev/null 2>&1; }
  # Thermal state and battery °C; neither needs root. The battery's "Temperature" is in 0.1 K (see
  # docs/verification.md); "VirtualTemperature" is a model
  heat() {
    thermal=$(osascript -l JavaScript -e 'ObjC.import("Foundation"); $.NSProcessInfo.processInfo.thermalState' 2>/dev/null | tr -cd 0-9)
    battery=$(ioreg -r -n AppleSmartBattery -d 1 | awk '/"Temperature" = / { print int($3 / 10 - 273.15) }')
  }
  power() {
    b=$(pmset -g batt)
    case $b in *"'Battery Power'"*) onbatt=1 ;; *) onbatt=0 ;; esac
    charge=$(printf '%s\n' "$b" | grep -oE '[0-9]+%' | head -n 1 | tr -d %)
  }
  notify() { osascript -e "display notification \"$1\" with title \"claude-coffee\"" >/dev/null 2>&1; }
  procs() { ps -A -o pid=,ppid=,etime=,%cpu=,args=; }
  # The user-owned "sshd-session: you@ttysNNN" (OpenSSH 9.8+) or "sshd: you@ttysNNN" (older); the
  # root-owned "[priv]" process has no @
  ssh_logins() { pgrep -u "$(id -u)" -f '^sshd(-session)?: [^ ]+@'; }
  login_ages() { ps -o etime= -p "$(printf '%s' "$1" | tr '\n' ,)"; }
  # -k: with cached credentials "sudo -n" passes for any admin; only a NOPASSWD rule should count
  can_hold() { sudo -k -n -l | grep -qE 'NOPASSWD: (ALL$|.*/usr/bin/pmset -a disablesleep 1)'; }
  agent_loaded() { launchctl print "gui/$(id -u)/com.github.ivaruf.claude-coffee"; }
  ;;
Linux)
  ROOT=${CLAUDE_COFFEE_ROOT:-}   # empty: the real /sys and /proc. The tests point it at a fake tree
  grep -qi microsoft "$ROOT/proc/version" 2>/dev/null && exit 0   # WSL: not supported yet
  MACHINE=computer HOLD_LABEL='logind lock' AGENT_LABEL='systemd timer'
  # Claude Code on Linux runs no keep-awake helper yet (2.1.316 has an unused linuxInhibitor field set to
  # "systemd-inhibit"). Named anyway: should it start one per turn, as caffeinate on macOS, a long tool
  # call counts as work. Our own lock's systemd-inhibit runs under the systemd user manager, not under
  # Claude Code, so it never counts. Should it hold one all session, an interrupted turn's marker lasts
  # MAX_QUIET_HOURS instead of STALE_MINUTES: bounded either way.
  OWN_KEEPAWAKE=systemd-inhibit
  # A logind inhibitor lock, held by a transient user unit because the hook exits at once. Lid close
  # needs handle-lid-switch: a sleep lock alone doesn't stop it (LidSwitchIgnoreInhibited=yes). polkit
  # grants that to a local desktop user without a password, but not to an SSH login alone
  held() { if systemctl --user is-active --quiet claude-coffee-awake 2>/dev/null; then echo 1; else echo 0; fi; }
  hold() {
    if [ "$1" = 1 ]; then
      systemd-run --user --quiet --collect --unit=claude-coffee-awake \
        systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block --who=claude-coffee \
        --why='Claude Code is working' sleep infinity </dev/null >/dev/null 2>&1
    else
      systemctl --user stop claude-coffee-awake >/dev/null 2>&1
    fi
  }
  # logind's LidClosed and Docked (an external display or a dock), each printed as "b true" or "b false".
  # Without logind on the bus, the ACPI lid
  lid_state() {
    if lx_l=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
      org.freedesktop.login1.Manager LidClosed Docked 2>/dev/null); then
      case $lx_l in "b true"*"b true"*) echo 1 ;; "b true"*) echo 2 ;; *) echo 0 ;; esac
    else
      case $(cat "$ROOT"/proc/acpi/button/lid/*/state 2>/dev/null) in *closed*) echo 2 ;; *) echo 0 ;; esac
    fi
  }
  lid_closed() { [ "$(lid_state)" != 0 ]; }
  # logind re-checks a closed lid when the last lock goes, and sleeps by itself unless docked. Sleeping
  # again here would only put the computer back to sleep when the lid next opens
  sleep_now() { :; }
  # Serious: any thermal zone at one of its own passive or hot trip points, or within 10 °C of its
  # critical one (millidegrees; trips at 40 °C or less are placeholders). Battery °C from its temp, in
  # 0.1 °C, which many x86 laptops don't have. Unreadable zones are skipped; none readable: unknown
  heat() {
    thermal=$(awk 'BEGIN {
        for (i = 1; i < ARGC; i++) {
          f = ARGV[i] "/temp"; ok = (getline t < f) > 0; close(f)
          if (!ok || t !~ /^-?[0-9]+$/) continue
          seen = 1
          for (j = 0; ; j++) {
            f = ARGV[i] "/trip_point_" j "_type"; if ((getline type < f) <= 0) break; close(f)
            f = ARGV[i] "/trip_point_" j "_temp"; ok = (getline trip < f) > 0; close(f)
            if (!ok || trip + 0 <= 40000) continue
            if ((type == "passive" || type == "hot") && t + 0 >= trip + 0) s = 2
            if (type == "critical" && t + 0 >= trip - 10000) s = 2
          }
        }
        if (seen) print s + 0
      }' "$ROOT"/sys/class/thermal/thermal_zone* 2>/dev/null)
    battery=$(awk 'function val(f,  v) { v = ""; if ((getline v < f) <= 0) v = ""; close(f); return v }
      BEGIN { for (i = 1; i < ARGC; i++)
        if (val(ARGV[i] "/type") == "Battery" && val(ARGV[i] "/scope") != "Device" &&
            (t = val(ARGV[i] "/temp")) ~ /^-?[0-9]+$/) { print int(t / 10); exit } }' \
      "$ROOT"/sys/class/power_supply/* 2>/dev/null)
  }
  # The computer's own batteries (scope Device is a mouse or a headset), averaged; on battery when one
  # is discharging, or no charger (Mains, USB) is online
  power() {
    lx_p=$(awk 'function val(f,  v) { v = ""; if ((getline v < f) <= 0) v = ""; close(f); return v }
      BEGIN {
        for (i = 1; i < ARGC; i++) {
          type = val(ARGV[i] "/type")
          if (type == "Mains" || type ~ /^USB/) { mains = 1; if (val(ARGV[i] "/online") + 0 == 1) online = 1 }
          else if (type == "Battery" && val(ARGV[i] "/scope") != "Device") {
            c = val(ARGV[i] "/capacity"); if (c ~ /^[0-9]+$/) { sum += c; n++ }
            if (val(ARGV[i] "/status") == "Discharging") dis = 1
          }
        }
        printf "%d %s\n", dis || (n && mains && !online), n ? int(sum / n + 0.5) : ""
      }' "$ROOT"/sys/class/power_supply/* 2>/dev/null)
    onbatt=${lx_p%% *}; charge=${lx_p#* }
  }
  notify() { notify-send claude-coffee "$1" >/dev/null 2>&1; }
  # procps's %cpu is a lifetime average (CPU time over elapsed time), not recent use. So every check
  # keeps each process's CPU time in $C/cpu, and the next one reports the use since, for processes it
  # recognizes by PID and start time (a reused PID starts afresh). Otherwise the lifetime average stands
  # in: for a process younger than the last check that's the same thing, and with no usable snapshot
  # (the first check, one under 10 s or over 5 minutes old, say after sleep) it's the best there is
  procs() {
    ps -A -o pid=,ppid=,etime=,time=,pcpu=,args= | awk -v now="$(date +%s)" -v snap="$C/cpu" -v out="$C/cpu.$$" '
      function secs(s,  n, t) { n = split(s, t, /[-:]/); return t[n] + 60 * t[n - 1] + 3600 * t[n - 2] + 86400 * t[n - 3] }
      BEGIN {
        if ((getline t0 < snap) > 0) { age = now - t0
          if (age >= 10 && age <= 300) while ((getline l < snap) > 0) { split(l, f, " "); start[f[1]] = f[2]; used[f[1]] = f[3] } }
        close(snap)
        print now > out
      }
      { s = now - secs($3); c = secs($4); cpu = $5
        print $1, s, c > out
        if (($1 in used) && s - start[$1] <= 5 && start[$1] - s <= 5 && c >= used[$1]) cpu = (c - used[$1]) * 100 / age
        a = $0; sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", a)
        printf "%s %s %s %.1f %s\n", $1, $2, $3, cpu, a }'
    mv -f "$C/cpu.$$" "$C/cpu" 2>/dev/null
  }
  # Linux OpenSSH titles them "sshd: you@pts/0" or (9.8+) "sshd-session: you@pts/0", as on macOS
  ssh_logins() { pgrep -u "$(id -u)" -f '^sshd(-session)?: [^ ]+@'; }
  login_ages() { ps -o etime= -p "$(printf '%s' "$1" | tr '\n' ,)"; }
  # polkit's answer for this login, without a password prompt (stdin isn't a terminal)
  can_hold() {
    systemd-inhibit --what=sleep:idle:handle-lid-switch --mode=block --who=claude-coffee --why='status check' true </dev/null
  }
  agent_loaded() { systemctl --user is-active --quiet claude-coffee.timer; }
  ;;
MINGW*|MSYS*|CYGWIN*)   # Windows, in Git Bash
  exit 0   # Windows backend: to do
  ;;
*) exit 0 ;;   # not supported: stay out of the way
esac

case $1 in
  on|off) json=$(cat); touch "$L" ;;
  check|status) ;;
  *) echo "usage: ${0##*/} on|off|check|status" >&2; exit 1 ;;   # not 2: that would block a PreToolUse
esac

# printf, not echo: macOS sh's echo expands the \n inside the JSON and jq then rejects it
sid=$(printf '%s\n' "${json:-}" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')
bg=$(printf '%s\n' "${json:-}" | jq '.background_tasks // [] | length' 2>/dev/null | tr -cd 0-9)   # jq.exe ends lines in CRLF
if [ -n "$sid" ]; then case $1 in
  on)  touch "$D/$sid" ;;
  # Stop with background agents or shells still running: stay awake until they report back
  off) if [ "${bg:-0}" -gt 0 ]; then touch "$D/$sid"; else rm -f "$D/$sid"; fi ;;
esac; fi

# Is Claude Code still at work, though no hook has fired for a while? Signs, among the processes under
# any Claude Code: its own "caffeinate" (it keeps one through a turn in progress, one long tool call
# included), one using 10% CPU or more (a background build, a test run), or one started in the last
# 2 minutes (a build spawning compilers, each gone too fast to show CPU). An idle dev server shows none
# of them, and idle sessions start no processes (see docs/verification.md).
claude_working() {
  procs | awk -v own="$OWN_KEEPAWAKE" '
    { pid[NR] = $1; ppid[NR] = $2; age[NR] = $3; cpu[NR] = $4
      n = split($5, p, /[\/\\]/); exe[NR] = p[n]; sub(/\.exe$/, "", exe[NR])   # Windows: C:\...\claude.exe
      root[NR] = exe[NR] == "claude" || $0 ~ /@anthropic-ai\/claude-code/
      if (root[NR]) under[$1] = 1 }
    END {
      do { grew = 0
           for (i = 1; i <= NR; i++) if (under[ppid[i]] && !under[pid[i]]) { under[pid[i]] = 1; grew = 1 }
      } while (grew)
      for (i = 1; i <= NR; i++) if (under[pid[i]] && !root[i]) {
        n = split(age[i], a, /[-:]/)   # [[dd-]hh:]mm:ss
        if ((own != "" && exe[i] == own) || cpu[i] + 0 >= 10 || (n == 2 && a[1] + 0 < 2)) exit 0
      }
      exit 1
    }'
}
# Only the launch agent's check looks: it runs outside Claude Code, whereas a hook would count itself
# as a young process. Hooks go by the check's verdict, if it's from the last 2 minutes.
W=$C/working
if [ "$1" = check ]; then if claude_working; then touch "$W"; else rm -f "$W"; fi; fi
limit=$STALE_MINUTES
[ -n "$(find "$W" -mmin -2 2>/dev/null)" ] && limit=$((MAX_QUIET_HOURS * 60))
[ "$1" = status ] || find "$D" -type f -mmin +"$limit" -delete
busy=$(find "$D" -type f ! -mmin +"$limit" | wc -l | tr -d ' ')
want=0; [ "$busy" = 0 ] || want=1

# Remote mode: while you're logged in over SSH (say, from your phone), also stay awake between turns
# so the next prompt can arrive. It lapses REMOTE_MINUTES after the later of the last hook event and
# the login, so a dead or forgotten connection can't keep the Mac up for good.
remote=0
if [ "$REMOTE" = 1 ] && ssh=$(ssh_logins); then
  remote=1
  if [ -n "$(find "$L" -mmin -"$REMOTE_MINUTES" 2>/dev/null)" ] ||
     login_ages "$ssh" | awk -v m="$REMOTE_MINUTES" '
       { n = split($1, t, /[-:]/); if (t[n] + 60*t[n-1] + 3600*t[n-2] + 86400*t[n-3] < m*60) young = 1 }
       END { exit !young }'; then
    remote=2; want=1
  fi
fi

# 2 = the lid is closed and that normally means sleep (no external display keeping the Mac up)
lid=$(lid_state)

# Heat guard: a closed Mac that keeps working in a bag can't get rid of its heat. With the lid
# closed, macOS reporting serious thermal pressure or a battery at HOT_BATTERY_C allows sleep and
# sleeps now, even mid-turn. It stays tripped until the lid opens, so a dark wake in the bag can't
# start the heat up again. With the lid open, heat is macOS's own business.
hot=0
if [ "$lid" != 2 ]; then
  [ "$1" = status ] || rm -f "$H"
elif [ -e "$H" ]; then
  hot=1
elif [ "$want" = 1 ] && [ "$HEAT_GUARD" = 1 ] && [ "$1" != status ]; then
  heat
  if [ "${thermal:-0}" -ge 2 ] || [ "${battery:-0}" -ge "$HOT_BATTERY_C" ]; then
    hot=1
    echo "$(date '+%Y-%m-%d %H:%M'), thermal state ${thermal:-?}, battery ${battery:-?} °C" >"$H"
    notify "Your $MACHINE got hot with the lid closed, so it went to sleep. Open the lid to carry on."
  fi
fi
[ "$hot" = 1 ] && want=0

# Battery guard: with sleep switched off, a Mac on battery could run itself flat (macOS starts warning
# at about 10% that it will sleep soon, and disablesleep may keep it from doing so). On battery at
# LOW_BATTERY % or less: stop keeping it awake and, with the lid closed, sleep now. Plugging in clears it.
low=0
if [ "$LOW_BATTERY" -gt 0 ] && { [ "$want" = 1 ] || [ -e "$B" ]; } && [ "$1" != status ]; then
  power
  if [ "$onbatt" = 1 ] && [ "${charge:-100}" -le "$LOW_BATTERY" ]; then
    if [ "$want" = 1 ]; then
      low=1; want=0
      if [ ! -e "$B" ]; then
        echo "$(date '+%Y-%m-%d %H:%M'), battery at $charge%" >"$B"
        notify "Battery at $charge%, so claude-coffee stopped keeping your $MACHINE awake. Plug it in to carry on."
      fi
    fi
  else
    rm -f "$B"
  fi
fi

have=$(held)

if [ "$1" = status ]; then
  ok() { if [ "$1" = 0 ]; then echo ok; else echo "missing (run install.sh)"; fi; }
  s=allowed; [ "$have" = 1 ] && s=blocked
  [ "$want" = "$have" ] || s="$s (the next hook or check flips it)"
  case $remote in
    0) r='off (no SSH login)' ;;
    1) r="lapsed (SSH login, but quiet for $REMOTE_MINUTES min)" ;;
    *) r='on (SSH login)' ;;
  esac
  [ "$REMOTE" = 1 ] || r='disabled in config'
  heat
  case ${thermal:-} in 0) tn=nominal ;; 1) tn=fair ;; 2) tn=serious ;; 3) tn=critical ;; *) tn=unknown ;; esac
  h="battery ${battery:-?} °C, thermal state $tn"
  if [ -e "$H" ]; then g="tripped $(cat "$H"); resets when the lid opens"
  elif [ "$HEAT_GUARD" = 1 ]; then g="armed: lid closed and serious thermal state or battery ${HOT_BATTERY_C} °C → sleep"
  else g='disabled in config'; fi
  printf 'claude-coffee\n'
  printf '  sleep          %s\n' "$s"
  printf '  busy sessions  %s\n' "$busy"
  printf '  remote mode    %s\n' "$r"
  printf '  lid            %s\n' "$(if lid_closed; then echo closed; else echo open; fi)"
  printf '  heat           %s\n' "$h"
  printf '  heat guard     %s\n' "$g"
  power
  if [ "$onbatt" = 1 ]; then p="on battery, ${charge:-?}%"; else p="on AC power${charge:+, battery $charge%}"; fi
  if [ -e "$B" ]; then bg="tripped $(cat "$B"); clears when plugged in"
  elif [ "$LOW_BATTERY" -gt 0 ]; then bg="armed: on battery at ${LOW_BATTERY}% or less → sleep"
  else bg='disabled in config'; fi
  printf '  power          %s\n' "$p"
  printf '  battery guard  %s\n' "$bg"
  can_hold >/dev/null 2>&1; printf '  %-14s %s\n' "$HOLD_LABEL" "$(ok $?)"
  agent_loaded >/dev/null 2>&1; printf '  %-14s %s\n' "$AGENT_LABEL" "$(ok $?)"
  exit 0
fi

[ "$want" = "$have" ] || hold "$want"

# macOS decides on lid sleep only when the lid closes. If it closed while sleep was disabled,
# re-enabling sleep leaves the Mac awake, so sleep now. Skipped when an external display keeps a
# closed Mac running (AppleClamshellCausesSleep = No).
if [ "$want" = 0 ] && [ "$have" = 1 ] && [ "$lid" = 2 ]; then
  sleep 1
  # Unless a guard tripped: a turn may have started during that second (a marker, or another hook's
  # disablesleep 1). Then stay up
  if [ "$hot" = 1 ] || [ "$low" = 1 ] || { [ -z "$(ls "$D")" ] && [ "$(held)" != 1 ]; }; then
    sleep_now
  fi
fi
exit 0
