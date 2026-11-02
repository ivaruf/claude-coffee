# Field notes: what was checked, and how

claude-coffee was built on a real Mac on 2026-10-31: a MacBook Pro on macOS 26.6.2, Apple silicon, OpenSSH 10.3. Every assumption the design depends on was checked against the docs or the hardware. This is the record, warts included.

## The bugs real hardware found

Each passed a first round of reasoning and only failed on the machine. All are now covered by `tests/hook.test.sh`.

### 1. `Stop` didn't remove the marker

macOS `/bin/sh` has `echo` expand escape sequences. The `Stop` hook input includes Claude's last reply as a JSON string, and the `\n` in it turned into a raw newline. `jq` then rejected the JSON, so there was no `session_id`, so the marker stayed and the Mac stayed awake until the 30-minute limit.

**Fix:** `printf '%s\n'` instead of `echo`. The test sends a reply containing `\n` and `\"`.

### 2. Turning sleep back on with the lid already closed didn't sleep the Mac

The kernel logged `System sleep prevented by kPMUserDisabledAllSleep` when the lid closed and never looked again when the value went back to 0. So a lid closed mid-turn left the Mac awake after the turn, indefinitely.

**Fix:** when the last session finishes, the lid is closed and closing the lid normally causes sleep, wait a second and run `pmset sleepnow`. Verified: `sleep reason Software Sleep`, requested by `pmset`, 1.1 s after re-enabling. `pmset sleepnow` works without root.

### 3. `pmset -g` doesn't always leave the line out

On 2026-10-31, `pmset -g` printed no `SleepDisabled` line when the value was 0. On 2026-11-01 it printed `SleepDisabled 0`. The check added before `sleepnow` (to catch a turn starting during that second) and the uninstaller's "is sleep back on?" check both only looked for the line. So with the line present at 0, `sleepnow` was skipped, and fix 2 quietly stopped working. It turned up when the uninstall steps reported sleep as still off right after switching it on.

**Fix:** read the value, never whether the line is there. The fake `pmset` in the tests now prints `SleepDisabled 0`, with one case for the no-line form.

## Assumptions

| Assumption | Result |
|---|---|
| `StopFailure` and `SessionEnd` are real hook events | Yes. Both are in the settings schema and the [hooks docs](https://code.claude.com/docs/en/hooks). |
| `Stop` doesn't fire on Esc | Correct. The docs say it "does not run if the stoppage occurred due to a user interrupt". The 30-minute stale limit covers this. |
| Background agents and shells after `Stop` | The `Stop` input lists `background_tasks`. If it's non-empty, the marker is kept. A background agent that reports back fires `UserPromptSubmit`, which refreshes the marker. |
| Subagent hooks share the session's `session_id` | Not confirmed, and it doesn't matter: a different id just makes its own marker, which also keeps the Mac awake. |
| `PreToolUse` fires before a permission prompt | Yes. The docs give the order as `PreToolUse` → `PermissionRequest`. |
| Hook output stays out of Claude's context | The script prints nothing to stdout, and a test fails if it does. The docs say stderr on exit 0 is never shown to Claude. |
| Running sessions pick up a hook edit | Yes. The marker appeared in the running session right after the edit. |
| `pmset disablesleep` exists on macOS 26 | Yes. It's in the `pmset` binary but missing from `man pmset`. |
| `pmset -g` shows `SleepDisabled` | ` SleepDisabled		1` when the value is 1. For 0 it showed no line on 2026-10-31 and ` SleepDisabled		0` on 2026-11-01 (bug 3). The script reads the value and treats a missing line as 0. |
| The launch agent can use passwordless sudo | Yes. Reset to 0 by hand, ran `launchctl kickstart`, and it was back to `Yes` within 2 s with exit code 0. |
| `jq` under launchd | `/usr/bin/jq` is on launchd's default `PATH`. `check` mode doesn't read stdin, so it returns in 0.1 s even with stdin left open. |
| `sudo -n` without the sudoers rule | Fails at once ("a password is required") without hanging. The Mac then sleeps as usual. |
| `visudo -cf` needs no root | Yes, so the installer validates the rule before it asks for a password. |
| `sudo -n -l /usr/bin/pmset …` tells whether the rule is installed | **No.** Admins may run every command, so it passes with cached credentials or with any other NOPASSWD rule. The installer looks for its own file instead, and `status` greps the NOPASSWD lines of `sudo -k -n -l` (`-k` so cached credentials don't count). |
| The lid closed really stays awake | Yes, on AC (2 min 49 s) and on battery (about 50 s). `ioreg` read `AppleClamshellState = Yes` from inside the running turn, and the power log has no sleep entry. |
| Claude Code's own `caffeinate` | Claude Code runs `caffeinate`, which holds off idle sleep (not lid sleep) during a turn and for a minute or two after. It doesn't interfere. |
| Long dark wakes after the Mac sleeps | That's macOS, not claude-coffee. One lasted 1 h 39 min (`kPMCPUAssertion`, held by a Safari SafeBrowsing update); `kPMUserDisabledAllSleep` never appeared during it. |
| SSH login detection | A login shows up as root's `sshd-session: you [priv]` and your own `sshd-session: you@ttys025`. Only the second has an `@`. With no markers, against a live login: recent hook event → awake; 60 minutes without one and a login over an hour old → sleep allowed. |
| The SSH pattern also matches older OpenSSH | `pgrep -f '^sshd(-session)?: [^ ]+@'` matches both `sshd-session: me@ttys998` and `sshd: me@ttys999` and skips `sshd-session: me [priv]`, checked with fake process titles. Not tested against a real pre-9.8 `sshd`. |

## A night of real use (2026-11-01)

With the hook as it is on `main`, on AC. Sources: `pmset -g log` and the session's transcript. Times are local.

| Time | What happened |
|---|---|
| 19:50–20:04 | Lid closed while background research agents worked. No sleep entry in the power log. |
| 20:04:32 → 20:04:37 | The turn ended. 5 s later the Mac slept: `Software Sleep`, the hook's `pmset sleepnow`. |
| 20:30:34–20:41:20 | The next prompt; the display went off 6 s later. 11 minutes of edits and test runs, no sleep entry. |
| 20:41:20 → 20:41:25 | The turn ended. 4.5 s later the Mac slept, the same way. |
| 20:57–06:11 | Six more sleeps, which macOS can't enter while `disablesleep` is 1. The dark wakes between them lasted up to 1 h 48 min, as on earlier nights on AC (3 h 14 min on 2026-10-28). |
| 21:36 | Claude Code compacted the idle conversation during one of those dark wakes. claude-coffee has no hook on compaction, and the Mac went back to sleep at 22:03 as usual. |

The lid itself isn't in the power log while sleep is off, so "closed" is inferred: each time the display went off within seconds, and the hook only runs `sleepnow` when it reads the lid as closed.

## Heat guard

### Official limits

Apple publishes no battery or chip temperature limit for Macs. What it does publish, and what the limits are based on:

| Source | What it says |
|---|---|
| [Keep your Mac laptop within acceptable operating temperatures](https://support.apple.com/en-us/102336) | Use it where the ambient temperature is 10–35 °C, on "a stable work surface that allows for good ventilation" |
| [Apple: Batteries, maximizing performance](https://www.apple.com/batteries/maximizing-performance/) | MacBook works best at 10–35 °C ambient; storage −20 to 45 °C; ideal 16–22 °C. Above 35 °C ambient "can permanently damage battery capacity", and "software may limit charging above 80% when the recommended battery temperatures are exceeded" |
| [MacBook Pro: important safety information](https://support.apple.com/guide/macbook-pro/important-safety-information-apd9b8f7aa11/mac) | "Adequate air circulation under and around the computer"; "never place anything over the keyboard when operating". Bags aren't mentioned |
| [Energy Efficiency Guide: thermal state](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html) | *Serious*: "Thermals are highly elevated. Fans are active, running at maximum speed … the system begins enacting countermeasures"; apps should start cutting back. *Critical*: "The device needs to cool down" |
| [Battery University BU-410](https://batteryuniversity.com/article/bu-410-charging-at-high-and-low-temperatures) | Lithium-ion: charge 0–45 °C, discharge −20 to 60 °C; many chargers stop charging above 50 °C |
| [Battery University BU-808](https://batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries) | Above 30 °C is "elevated" and speeds up wear; a full battery kept at 40 °C keeps about 65% of its capacity after a year, against 80% at 25 °C |

So the guard trips at *serious*, where Apple tells software to back off, or at a battery temperature of 45 °C: the top of the lithium-ion charging range and Apple's highest storage temperature, with room to spare before the 60 °C discharge limit. Apple's 35 °C is about the room, and the battery normally runs a few degrees above it, so 35 °C as a battery limit would trip during ordinary heavy work.

### Measurements

Measured on 2026-11-01, same Mac, on battery.

| Question | Result |
|---|---|
| Can a hook read temperatures without root? | Yes, two: macOS's thermal state (`NSProcessInfo.thermalState`, read through `osascript -l JavaScript` in 62 ms) and the battery's sensors (`ioreg -r -n AppleSmartBattery`, 32 ms). Die temperatures need root (`powermetrics`) or private APIs. |
| `pmset -g therm` | Records nothing on this Mac ("No thermal warning level has been recorded"), so it isn't used. |
| Units of the battery's `Temperature` | **0.1 K**, not 0.01 °C as many scripts online assume. During 90 s of load on all cores, `Temperature` went 2978 → 2981 and `VirtualTemperature` (0.01 °C; its lifetime average of 23 °C matches) went 2459 → 2489. Both rose by 0.3 °C, and as 0.1 K, 2978 is 24.65 °C, next to the virtual 24.59 °C. Read as 0.01 °C, the battery would be 5 °C warmer than its own model and react 10 times slower. |
| How often the battery values change | About once a minute, which suits the launch agent's one-minute check. |
| Does heavy work alone trip it? | 90 s of load on all cores left the thermal state at *nominal* and the battery at 25 °C. The battery's lifetime maximum is 42 °C, below the 45 °C limit. |
| Not tested yet | An actual bag, and the thermal state reaching *serious* on real hardware. The tests fake both. |

## Battery guard

| Question | Result |
|---|---|
| Is there an official low-battery threshold? | No. Apple publishes none. macOS shows "Low Battery: Your Mac will sleep soon unless plugged into a power outlet" at about 10% ([Apple Community](https://discussions.apple.com/thread/255561785)). |
| Does `disablesleep 1` keep macOS from its own low-battery sleep? | Not tested, deliberately: that means running the battery flat. The guard doesn't rely on either answer, and it steps in at 20%, well before that point. |
| Reading the charge without root | `pmset -g batt` prints `Now drawing from 'AC Power'` or `'Battery Power'`, then a line with the charge, such as `100%; finishing charge`. Desktop Macs have no battery line, so the guard never trips there. |
| Not tested yet | A real discharge to 20%. The tests fake `pmset -g batt`. |

## Long tool calls and background jobs

Measured on 2026-11-01, same Mac. The question: how to tell a long tool call or a background build from a turn interrupted with Esc, or a dev server left running, when none of them fires a hook.

| Question | Result |
|---|---|
| Does Claude Code have its own sign of being busy? | Yes. While a turn is in progress, the `claude` process has a child `caffeinate -i -t 300` (prevent idle sleep, at most 5 minutes). |
| Does it last through one long tool call? | Yes. During one 7-minute tool call with no hooks firing, sampled every 30 s, a `caffeinate` child was always there: Claude Code started a new one about every 4 minutes, before the old one timed out (new PIDs at 3:55 and 7:55 in). |
| Background tasks after the turn has ended | `caffeinate` doesn't cover them. With the turn over and a 7-minute background task running, the `caffeinate` disappeared about 30 s after the turn ended, at 2:50 of its 5 minutes, so Claude Code stopped it. No new one followed. |
| What background tasks look like | Child processes of the session's `claude` process. The `Stop` input lists them (`type`, `status`, and `command` for shells) but gives no process IDs. |
| A busy job in one process | Visible as CPU time. A CPU-bound `perl` loop went from 4.2 to 19.2 s of CPU in 15 s: a full core. |
| A build that spawns compilers | **Not** visible as CPU time: each short-lived child's CPU disappears with it. A loop running CPU-heavy `awk` processes back to back added 0.1 s to its parent in 15 s, even with `ps -S`, which is meant to add finished children's time. But a young process was always there: every sample caught one under a second old. |
| Do idle sessions start processes? | No. 11 Claude Code sessions were open, some for 30 days. Sampled every 5 s for a minute, the 10 idle ones had no child processes at all. |
| Esc | Not tested. Claude Code stopping `caffeinate` at the end of a normal turn suggests Esc does the same. `MAX_QUIET_HOURS` (4) caps the case where it doesn't. |
| Telling Claude Code's `caffeinate` apart | Its parent process is `claude` (`node … claude-code …` for npm installs). A `caffeinate` you start yourself has your shell as its parent and doesn't count. |

So a marker no hook has touched for 30 minutes is kept, for up to 4 hours, while some process under a Claude Code session is its `caffeinate`, uses 10% CPU or more, or started in the last 2 minutes. An idle dev server or a `sleep` does none of that. Only the launch agent's check measures, because it runs outside Claude Code; a hook would count itself as a young process. Hooks use the check's verdict if it's from the last 2 minutes. Without the launch agent, the plain 30-minute rule applies. Parts of this depend on undocumented Claude Code behavior, and the fallback in every case is the plain 30-minute rule.

## Ideas that didn't survive

The design started in a phone chat with Claude. Some first drafts were replaced once they met the details:

- **`disablesleep *` in sudoers** became the two exact commands, because a sudoers wildcard also matches whitespace and would allow any other `pmset` setting to be appended.
- **`pgrep claude`** as the "is anything running" check. About eight `claude` processes are usually open, so any check based on them keeps the Mac awake forever. The hooks know when a turn is running; process lists don't.
- **Parsing the hook JSON with `sed`** became `jq`.
- **Presence signals for remote mode** (a flag file, pinging the phone on home Wi-Fi, `tailscale ping`) were replaced by watching for your own SSH login process, which needs no setup and no network assumptions.

## Reproduce

```sh
make test                               # fakes only: safe at any time
~/.claude/hooks/claude-coffee.sh status # the real thing, read-only
pmset -g | grep SleepDisabled           # mid-turn "SleepDisabled 1"; idle "SleepDisabled 0" or no line
ls ~/.claude/coffee/busy                # sessions that are mid-turn right now
```

**Lid test:** start a long turn and close the lid for two minutes. `pmset -g log | grep -E 'Entering Sleep|Wake from' | tail -5` should show no sleep inside that window. Leave the lid shut past the end of the turn, and an `Entering Sleep state due to 'Software Sleep pid=…'` entry follows about a second later.

The kernel's own account of why the Mac did or didn't sleep is under [Troubleshooting](../README.md#troubleshooting) in the README.
