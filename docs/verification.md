# Field notes: what was checked, and how

claude-coffee was built on a real Mac on 2026-10-31: a MacBook Pro on macOS 26.6.2, Apple silicon, OpenSSH 10.3. Every assumption the design depends on was checked against the docs or the hardware. This is the record, warts included.

## The bugs real hardware found

Each passed a first round of reasoning and only failed on the machine. All are now covered by `tests/hook.test.sh`.

### 1. `Stop` didn't remove the marker

macOS `/bin/sh` has `echo` expand escape sequences. The `Stop` hook input includes Claude's last reply as a JSON string, and the `\n` in it turned into a raw newline. `jq` then rejected the JSON, so there was no `session_id`, so the marker stayed and the Mac stayed awake until the 30-minute limit.

**Fix:** `printf '%s\n'` instead of `echo`. The test sends a reply containing `\n` and `\"`.

### 2. Turning sleep back on with the lid already closed didn't sleep the Mac

The kernel logged `System sleep prevented by kPMUserDisabledAllSleep` when the lid closed and never looked again when the value went back to 0. So a lid closed mid-turn left the Mac awake after the turn, indefinitely.

**Fix:** when the last session finishes, the lid is closed and closing the lid normally causes sleep, wait a second and run `pmset sleepnow`. Verified: `sleep reason Software Sleep`, requested by `pmset`, 1.1 s after re-enabling. `pmset sleepnow` works without root. The source agrees: turning sleep back on only clears a flag, with no new look at the lid (`kPowerEventUserDisabledSleep` in [IOPMrootDomain.cpp](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOPMrootDomain.cpp)). Since 2026-11-01 it also waits, up to 5 s, for the kernel's own flag to clear first (see below).

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
| `pmset -g` shows the kernel's state | **No**, the saved setting. The kernel's flag is `SleepDisabled` on `IOPMrootDomain` in `ioreg`, set once powerd applies the setting, and `pmset sleepnow` is refused while it's on ([pmset.m](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m), [IOPMrootDomain.cpp](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOPMrootDomain.cpp)). So before `sleepnow`, claude-coffee waits for that flag rather than a fixed second. |
| `disablesleep` lasts across a restart | Yes, per the source: `pmset` writes it to `/Library/Preferences/com.apple.PowerManagement.plist`, and powerd applies it again when it starts ([pmset.m](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m), [PMSettings.m](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMSettings.m)). Not tested by restarting. So markers from before a restart are dropped (`kern.bootsessionuuid` changes with every boot), and the launch agent also runs at login. Before login nothing runs, so a Mac restarted mid-turn stays up at the login window. |
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
| A hook inside the SSH login | macOS `pgrep` leaves out its own ancestors unless given `-a`, and Claude run in the SSH shell (or in `screen` started there) has the login as an ancestor. Without `-a`, `status` said "no SSH login" from inside one, and with the lid closed the Mac slept at the end of every phone-driven turn. Checked with a fake `sshd-session` title as parent and as sibling. Linux `pgrep` only skips itself, and its `-a` lists command lines instead. |

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

## A commute (2026-11-04)

One prompt typed at the Mac before leaving home: pick tasks off the board and work through whatever needs no input. Then a commute on battery and a phone's hotspot, with the lid closed most of the way. Same Mac, Claude Code 2.1.317. Claude worked through 12 issues, on local branches. Sources: `pmset -g log`, configd's `network changed` messages in `log show`, and the session's transcript (which is in UTC). Times are local.

| Time | What happened |
|---|---|
| 06:53:08 | Lid opened, on battery at 100%. Wi-Fi joined the hotspot at 06:53:32. |
| 06:56:30 | The prompt. The display went off at 06:57:13. |
| 07:17–07:35 | powerd logged the lid opening four times, for half a minute to 3 minutes each. No sleep entry in the power log for the whole trip, so the heat and battery guards never stepped in. |
| 07:51:27 | An API request got no answer, and neither did the next one, at 07:51:43: the signal was fading. |
| 07:53:20 → 07:55:56 | Out of range: Wi-Fi lost its address for 2 min 36 s (`v4(en0-:…)`, then DHCP again). |
| 07:56:21 | The next request went out 25 s after the network came back. It was answered at 07:56:25, and the turn went on. It never failed, so `StopFailure` and auto-continue had nothing to do. |
| 08:17:09 | The turn ended after 79 minutes (Claude Code's `turn_duration`). Two background tasks were still running, so the Mac stayed awake. |
| 08:19:24, 08:21:45 | Each finished and started a short turn of its own. 348 tool calls in all. |
| 08:23:15 → 08:23:22 | The last turn ended. 7 s later the Mac slept (`Software Sleep`), at 92%. |
| 08:37:25 | Lid opened at work, still at 92%. |

The address was back 18 s before Claude Code's retries would have run out, going by the 2 min 54 s of [the drop of 2026-11-03](#a-real-drop). Counted from the first unanswered request, though, the API was out of reach for about 4½ minutes and the turn still didn't fail. The transcript doesn't log retries, so it doesn't show why. A guess: a request that hangs on a weak signal uses up time rather than attempts.

8 points of this 100 Wh battery in 90 minutes is about 5 W on average. That's for real work, with the hotspot's Wi-Fi and about 12 minutes of display. The 1% steps make it rough, and so does macOS showing 100% for a while after it's unplugged.

## A night on the charger, and a shop (2026-11-06)

`AWAKE_ON_AC=1`, and the phone logged in over SSH: Tailscale, from 100.103.190.70 to a non-root `sshd` on 100.85.221.53:22022 (the burrow setup), with `claude` in `tmux`. In the morning the Mac rode in a bag on the phone's hotspot. Sources: `pmset -g log`, the kernel's `PMRD` lines and launchd's runs of the check in `log show`, the burrow `sshd.log` (which has no timestamps), and `~/.claude/history.jsonl`. Times are local.

| Time | What happened |
|---|---|
| 11-05 15:20:54 | The phone logged in. That one login lasted 18 hours: the same `sshd-session` process (PID and thread) logged again at its end. |
| 19:22 → 06:26 | Lid closed, on AC, no Claude turns, a login 4 to 15 hours old. No sleep entry in the power log for 11 hours: `AWAKE_ON_AC` held it. |
| 06:26 → 09:41 | On and off the charger (on battery 06:26–07:33 and from 09:06:35), the lid closed most of the time. Prompts typed on the phone, 06:31 to 09:22, kept remote mode on: the login was old, but the last hook event was under an hour old. |
| 09:19:40 | The hotspot's network changed (a new IPv6 prefix); the Mac kept its address. |
| 09:41:04 | In a shop, the phone had lost its mobile data. sshd gave up: `Read error from remote host … Operation timed out`. With `ClientAliveInterval 30` and `ClientAliveCountMax 4`, the phone had been unreachable for at most about 2 minutes. |
| 09:41:24.7 → 09:41:26.1 | launchd ran the check (every earlier run took 0.18 s and changed nothing). No SSH login, on battery, no turn: it released sleep and ran `pmset sleepnow`. The kernel logged `sleep reason Software Sleep` at 09:41:26.078, the second the check exited. |
| 09:45, 09:58, 10:01, 10:02 | Dark wakes, which the kernel put down to the Wi-Fi chip (`wifibt`), each followed by a network change. In the 09:58:49 one, four reconnects from the phone reached sshd at 09:59:29, but the Mac slept again at 09:59:35, so they ended `Timeout before authentication`. |
| 10:03 | The lid opened. |
| 10:03 → 10:21 | On the move again, lid closed, on battery. A new login from the phone timed out the same way. At 10:21:40 a turn in another session ended, and its `Stop` hook found no login and put the Mac to sleep, 25 s after a minute check had left it alone. |

So remote mode on battery hung on the login being there at the moment a hook or the check ran. The last prompt was at 09:22, so the Mac would have stayed up until 10:22. Instead, a couple of minutes without a signal put it to sleep, twice, and the phone couldn't get back in. The same morning on the charger would have kept it up. Since then, a login that drops still counts until remote mode would lapse anyway.

With that installed, the same Mac, lid closed and on battery, and the phone walked out of range at about 10:41. sshd dropped the login at 10:44:51. The Mac stayed up: when the network came back at 10:50:15, macOS tried to sleep twice (10:50:21 and 10:50:45), and both times the kernel logged `prevented by kPMUserDisabledAllSleep`. The phone logged in again at 10:50:40, without anyone touching the Mac. The SSH app still has to reconnect after a drop like that. Claude in `tmux` carries on.

Next, the burrow sshd's `ClientAliveInterval` went from 30 s to 300 s (`ClientAliveCountMax` 3), so that a quiet session sends nothing for 5 minutes. A login from 11:00:14 still ended `Operation timed out` at 11:22:54, on a longer walk. When the phone went out of range isn't known, so that doesn't say how much longer it held.

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
| Does `disablesleep 1` keep macOS from its own low-battery sleep? | Yes, per the source: while sleep is disabled the kernel refuses every sleep, low-battery and overheating sleep included (`checkSystemSleepAllowed` in [IOPMrootDomain.cpp](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOPMrootDomain.cpp)). Some arm64 configurations ask for a shutdown instead. Not tested, deliberately: that means running the battery flat. So the guard is what stands in, at 20%. A [hardware report](https://github.com/vorssaint/vorssaint-utils/issues/1729) for another tool shows the same: with the lid closed and sleep turned back on at 20%, the Mac never slept and drained. |
| Reading the charge without root | `pmset -g batt` prints `Now drawing from 'AC Power'` or `'Battery Power'`, then a line with the charge, such as `100%; finishing charge`. Desktop Macs have no battery line, so the guard never trips there. |
| Not tested yet | A real discharge to 20%. The tests fake `pmset -g batt`. |

## Power draw

Measured on 2026-11-02, same Mac (16-inch, M4 Pro, 100 Wh battery), on battery.

| Question | Result |
|---|---|
| Reading it without root | `ioreg -rn AppleSmartBattery` has `"SystemLoad"` in `PowerTelemetryData`: the whole machine's draw in mW, on battery and on AC. Like the battery's other values it changes about once a minute, so it gives averages over minutes, not second by second. |
| Voltage × current instead? | `InstantAmperage` is printed as an unsigned 64-bit number, so −609 mA shows as 18446744073709551007. awk's floating point can't take 2^64 off that exactly and gave 25 W, then 0 W. Done exactly with `bc` it was 9.55 W, next to `SystemLoad`'s 8.27 W. `SystemLoad` is simpler. |
| The battery's mAh left over a run? | Too coarse over minutes: `AppleRawCurrentCapacity` rose by 98 mAh in the middle of the run below. |

| State | Draw |
|---|---|
| Lid open, display on, during a turn | 7.4, 13.3 and 8.3 W, read at 12:10–12:12 |
| Lid closed, kept awake, Claude waiting on one 9-minute tool call | **1.5 W** on average: 1.07, 1.21, 1.53, 1.31, 1.09, 1.07, 1.16, 2.77 and 2.38 W, one reading a minute. The first reading, 4.9 W, dated from before the lid closed and is left out. |
| Asleep, lid closed | **Under 0.6 W**: from 06:37 to 08:18 the charge stayed at 99%, and from 08:39 to 10:00 at 95% (`pmset -g log`, dark wakes included) |

So a Mac kept awake with the lid closed and nothing to do uses about 12% of this battery over an 8-hour night, against under 5% asleep. With the lid closed during real work, about 5 W over [a commute](#a-commute-2026-11-04), going by the charge alone. Pilot Light's site reports 2.3 W for builds or tests on an M5 Max.

## Losing the network

Tested on 2026-11-03 with Claude Code 2.1.317, same Mac. Two headless runs (`claude -p`) went through a proxy that doesn't exist (`HTTPS_PROXY=http://127.0.0.1:9`), so every connection was refused and nothing left the machine.

| Question | Result |
|---|---|
| Can a hook resume a turn that failed? | Not by its output: `StopFailure` ignores that ([hooks docs](https://code.claude.com/docs/en/hooks)). But a background one can: see [auto-continue](#auto-continue) below. |
| How long does a turn last without a network? | About 3¼ minutes (gone between 183 and 198 s): 10 retries with backoff, then `API Error: Connection refused … (ECONNREFUSED)`. `StopFailure` removed its marker. |
| With `CLAUDE_CODE_RETRY_WATCHDOG=1`? | Still retrying at 8 minutes, when it was stopped with SIGINT, and `SessionEnd` removed its marker. The docs give 300 retries, about 3 hours, for dropped connections and timeouts, and no limit for rate limits and overload ([errors](https://code.claude.com/docs/en/errors#tune-retry-behavior)). |
| Does `caffeinate` run while it retries? | Not in `claude -p`: neither run had one in 8 minutes, while this interactive session had `caffeinate -i -t 300` as a child. So a headless run's marker lasts the plain 30 minutes. |
| Not tested | A real network drop, an interactive turn stuck retrying, and a turn carrying on after the machine slept mid-retry. The docs count a connection broken by sleep as dropped, and retry it. |

### Auto-continue

Tested on 2026-11-03 with Claude Code 2.1.317, same Mac. Claude Code ran with a throwaway `CLAUDE_CONFIG_DIR`, a dummy API key and `ANTHROPIC_BASE_URL` pointing at a local port where nothing listened yet, so nothing left the machine. It ran as `claude -p --input-format stream-json`, which keeps the session open between turns like the interactive CLI. Its only hooks were test scripts given with `--settings`.

| Question | Result |
|---|---|
| Does a background `StopFailure` hook wake Claude? | Yes. The turn ended with `API Error: Connection refused … (ECONNREFUSED)`. A `StopFailure` hook with `asyncRewake: true` waited until a fake Messages API came up on that port, then exited 2. Claude woke within a second, in a new turn, and answered through the fake API. The docs say such a hook "wakes Claude immediately even when the session is idle", and the code path for it doesn't look at the event. |
| What does the woken turn look like to hooks? | Like any other: `UserPromptSubmit` (its prompt a `<task-notification>` summarised "Stop hook feedback"), then `Stop`. So claude-coffee's own hooks mark it busy and let go after, as usual. Claude gets the hook's stderr as a system reminder: `Stop hook blocking error from command "StopFailure:server_error": …`. |
| Does the error type say it was the network? | No. A refused connection reads `server_error`, the same as a failure inside the API. So claude-coffee goes by the message, using the network errors listed on the [errors page](https://code.claude.com/docs/en/errors#network-and-connection-errors), and only for `server_error` or `unknown`. |
| How does it tell the internet is back? | `curl -s -o /dev/null --max-time 5 https://api.anthropic.com` (or `ANTHROPIC_BASE_URL`): exit 0 for any HTTP answer, 7 for a refused connection. |
| Hook timeout | Claude Code enforces `timeout` on `asyncRewake` hooks, unlike plain `async` ones. The installer sets 4 hours, so `OFFLINE_MINUTES` stops at 239. |
| Does `StopFailure` always mean a turn failed? | No. On 2026-11-06 it fired with `ENOTFOUND` in an idle session while the internet was gone (about 11:57 to 12:06), with no turn or error in the transcript between the last turn at 11:03 and the wake, so it came from a request Claude Code makes in the background. claude-coffee woke that session at 12:06:55 to carry on, with nothing to carry on. Since then it waits only when the session's marker says a turn was running. |
| Not tested | Claude Code's other connection messages (`Connection lost mid-response`, `The response stopped arriving`) as hook input; claude-coffee matches them from the docs. |

### A real drop

On 2026-11-03, in an interactive session (Claude Code 2.1.317), with Wi-Fi switched off mid-turn from the menu bar. Times are local, from the session's transcript.

| Time | What happened |
|---|---|
| 13:56:24 → 13:56:57 | A first drop, of 33 s. Claude Code's own retries rode it out (7 attempts, backing off from 0.6 to 16 s). The turn never failed, so claude-coffee had nothing to do. |
| 13:57:29 | Wi-Fi off again, and Claude Code retries. |
| 14:00:23 | After 2 min 54 s and 11 attempts, the turn ends: `API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)`. `StopFailure` keeps the marker and starts `wait`. |
| 14:00:44 | The API answers; `wait` exits 2 and Claude wakes in a new turn with `claude-coffee: The connection dropped and is back. Your last turn ended on "API Error: Can't reach the API server …"`. Afterwards `~/.claude/coffee/offline` is empty, and only the running turn's marker is left. |

So an outage shorter than Claude Code's own retries, about 3 minutes, needs nothing from claude-coffee, and a longer one now carries on by itself. The wake message counts from when Claude Code gave up, not from the drop, so it said "dropped" for an outage of about 3 minutes.

### The terminal's title

Notifications are easy to miss at the desk, so the title says it too. Tested the same day, in iTerm2, in the same interactive session.

| Question | Result |
|---|---|
| Can a hook write to the terminal? | Not directly: hooks have no terminal. A `terminalSequence` field in a hook's JSON output has Claude Code write an allowlisted escape sequence for it, a title (OSC 0/1/2) among them, and `StopFailure` honours it while discarding all other output ([hooks docs](https://code.claude.com/docs/en/hooks#emit-terminal-notifications)). |
| Does Claude Code put its own title back afterwards? | No. Through the woken turn and the next prompt, the tab kept `☕ Waiting for the internet · claude-coffee`, so claude-coffee has to put it back itself. |
| Can a hook read the title it replaces? | No: that takes a terminal query (CSI), which hooks can't send or read. But Claude Code's title is the session's, and the transcript has it: `{"type":"custom-title","customTitle":…}` after a `/rename`, `{"type":"ai-title","aiTitle":…}` otherwise. Claude Code keeps writing `ai-title` entries after a rename, so the last `custom-title` wins. |
| A real drop (14:36–14:41) | The tab read `claude-coffee offline experiments · ☕ Waiting for the internet · claude-coffee` once the turn failed, `… · 🎉 Woho! Internet is back` as Claude woke (`UserPromptSubmit`), and `claude-coffee offline experiments` again at its first tool call (`PreToolUse`). The JSON from `UserPromptSubmit` and `PreToolUse` didn't reach Claude's context. |
| Not tested | Terminals other than iTerm2, and the title after `wait` gives up: it keeps the waiting note until the session's next prompt. |

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

## Linux

Researched on 2026-11-01 from systemd, polkit and kernel sources and docs; built and tested against faked commands only. Nothing here has run on real Linux hardware yet.

| What it relies on | Source |
|---|---|
| A lid-closed laptop stays up only with a `handle-lid-switch` lock: a plain sleep lock doesn't stop lid suspend, because `LidSwitchIgnoreInhibited=yes` by default | [logind.conf(5)](https://www.freedesktop.org/software/systemd/man/latest/logind.conf.html), [inhibitor locks](https://systemd.io/INHIBITOR_LOCKS/) |
| polkit grants `inhibit-handle-lid-switch` to an active or inactive local session without a password, but not to any other (an SSH login alone) | [org.freedesktop.login1.policy](https://github.com/systemd/systemd/blob/main/src/login/org.freedesktop.login1.policy) |
| The lock is an open file descriptor, so a long-lived process must hold it: a transient user unit (`systemd-run --user --unit=claude-coffee-awake systemd-inhibit … sleep infinity`) | systemd-inhibit(1), systemd-run(1) |
| When the last lock goes with the lid closed, logind re-checks the lid and suspends by itself (not when docked, with `HandleLidSwitch=ignore`, or within 30 s of boot or resume). So claude-coffee never suspends explicitly: that would put the computer back to sleep when the lid next opens | [logind-button.c](https://github.com/systemd/systemd/blob/main/src/login/logind-button.c) |
| KDE Plasma's PowerDevil, and Xfce's power manager by default, handle the lid themselves, ignoring other programs' lid locks. KDE does that on purpose, against laptops overheating in bags | [KDE bugs 485623](https://bugs.kde.org/show_bug.cgi?id=485623) and [457859](https://bugs.kde.org/show_bug.cgi?id=457859), [xfpm-manager.c](https://gitlab.xfce.org/xfce/xfce4-power-manager/-/blob/master/src/xfpm-manager.c) |
| GNOME's automatic suspend of an idle machine asks gnome-session's inhibitors, not logind's, and before systemd 257 logind let a user's own `Suspend()` past that user's block locks. So inside the lock, `gnome-session-inhibit --inhibit suspend` runs too, where it works; elsewhere it falls back to a plain wait | [gsd-power-manager.c](https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/blob/master/plugins/power/gsd-power-manager.c), [systemd NEWS](https://github.com/systemd/systemd/blob/main/NEWS) (v257: "logind now always obeys block inhibitor locks") |
| Since systemd 257 the lock also refuses your own `systemctl suspend` while held, as `disablesleep` does on macOS | [logind-shutdown.c](https://github.com/systemd/systemd/blob/main/src/login/logind-shutdown.c) |
| UPower's critical-battery action skips inhibitors, so it still works while the lock is held | [up-backend.c](https://gitlab.freedesktop.org/upower/upower/-/blob/master/src/linux/up-backend.c) |
| procps' `%cpu` is a lifetime average, so the check keeps a snapshot of each process's CPU time and reports the use since the last check | ps(1) |
| Claude Code runs no keep-awake helper on Linux (2.1.316) | [#96679](https://github.com/anthropics/claude-code/issues/96679) |

**Unverified:**
- that polkit grants the lid lock to a process in a user unit, which belongs to no session (it should fall back to the user's desktop session; old polkit 0.105 is the risk);
- that logind sleeps a closed laptop the moment the lock goes (the source says so);
- that the GNOME inhibit stops GNOME's idle suspend on systemd 256 and older (Ubuntu 24.04 has 255);
- the `busctl` output formats, the thermal trip-point rule on real laptops, and `notify-send` reaching the desktop from the timer.

## Windows

Researched on 2026-11-01 from Microsoft Learn and Claude Code's docs and issues; built and tested against faked commands only. Nothing here has run on real Windows hardware, and the PowerShell/C# half hasn't been syntax-checked.

| What it relies on | Source |
|---|---|
| `SetThreadExecutionState` and power requests don't stop lid-close sleep; the power plan's lid close action does | [SetThreadExecutionState](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate), [lid action](https://learn.microsoft.com/windows-hardware/customize/power-settings/power-button-and-lid-settings-lid-switch-close-action) |
| You may change your own plan without admin, unless Group Policy or MDM sets it | [administrator overrides](https://learn.microsoft.com/windows/win32/power/administrator-overrides) |
| With "do nothing", Windows' protection against waking in a bag (input suppression) is off while held | [input suppression](https://learn.microsoft.com/windows-hardware/customize/power-settings/power-controls-enableinputsuppression) |
| There's no API for the lid's state other than a power-setting notification that reports it on registration | [PowerSettingRegisterNotification](https://learn.microsoft.com/windows/win32/api/powersetting/nf-powersetting-powersettingregisternotification) |
| Hooks run in Git Bash, or in PowerShell without it, where a failing hook blocks the tool call: hence the absolute, quote-free hook command | Claude Code's [hooks](https://code.claude.com/docs/en/hooks) and [setup](https://code.claude.com/docs/en/setup) docs |
| Claude Code runs no keep-awake helper on Windows | [#96679](https://github.com/anthropics/claude-code/issues/96679) |
| The same design was proposed for PowerToys Awake and closed unmerged. Review found that it restored into whichever plan was active, wrote "do nothing" into a plan switched to meanwhile, and only recovered from a crash on relaunch. claude-coffee restores into the plan it saved, never writes into another, and the every-minute check puts things back after a crash | [PowerToys #46408](https://github.com/microsoft/PowerToys/pull/46408), [#34479](https://github.com/microsoft/PowerToys/issues/34479) |
| The plan keeps its change across a restart. There's no cheap boot ID, so markers from before one expire after 30 minutes | — |

**Unverified:**
- that Windows doesn't sleep by itself when the lid action goes back to sleep with the lid already closed (assumed, so claude-coffee sleeps it);
- that "do nothing" plus "never sleep" keeps a closed Modern Standby laptop running, and that turning the display off puts it into standby;
- the lid callback's timing and data offset, `conhost --headless`, the scheduled task repeating forever, and the toast;
- that thermal-zone throttling counters move at all on most laptops.

## Other tools

Checked on 2026-11-01 from their source where it's public. Every tool found that keeps a Mac awake with the lid closed on battery, reliably, switches sleep off with `pmset disablesleep` behind root, as claude-coffee does.

| Tool | Lid closed on battery | With | Guards |
|---|---|---|---|
| [Claude Clamshell](https://github.com/mrexodia/claude-clamshell) | No | `caffeinate -s`, which works on AC power only | — |
| [claude-keep-awake](https://github.com/AxGord/claude-keep-awake) | Yes, reportedly | a private clamshell switch, no root (see below) | — |
| [keep-awake-agents](https://github.com/emielmadonna/keep-awake-agents) | Opt-in | `pmset disablesleep` through a sudoers rule | battery 15%, 8 hours |
| [Adrafinil](https://github.com/kageroumado/adrafinil) | Yes | `pmset disablesleep` through a root helper | 80 °C, battery 20% |
| [Nemuri](https://github.com/syfssb/nemuri) | Yes | `pmset disablesleep` through a root helper; restores it at boot | battery 20% |
| [Lidnight](https://lidnight.app/en/security/) | Yes | `pmset disablesleep` through a root helper; restores it at boot | 45 °C, a battery floor |
| [Amphetamine Power Protect](https://github.com/x74353/Amphetamine-Power-Protect) | Yes | the same two-command sudoers rule as claude-coffee | battery level |
| [Pilot Light](https://github.com/CyrisXD/pilot-light) (checked 2026-11-02) | Yes, while its switch is on | `pmset disablesleep` through a sudoers rule, plus Low Power Mode with the lid closed | serious thermal state, battery 15% |

## Ideas that didn't survive

The design started in a phone chat with Claude. Some first drafts were replaced once they met the details:

- **`disablesleep *` in sudoers** became the two exact commands, because a sudoers wildcard also matches whitespace and would allow any other `pmset` setting to be appended.
- **`pgrep claude`** as the "is anything running" check. About eight `claude` processes are usually open, so any check based on them keeps the Mac awake forever. The hooks know when a turn is running; process lists don't.
- **Parsing the hook JSON with `sed`** became `jq`.
- **A no-root clamshell switch** (`kPMSetClamshellSleepState` on `IOPMrootDomain`, used by Amphetamine Enhancer and claude-keep-awake) needs no sudo, and macOS's own low-battery sleep keeps working with it. But it takes compiled code, powerd resets it after a wake and on power changes on Apple silicon, and [Adrafinil](https://github.com/kageroumado/adrafinil) found it had no effect on macOS 26.3.
- **Low Power Mode with the lid closed**, as Pilot Light does. Its site reports 4.8 W with the lid closed and Low Power Mode on, on an M5 Max. Here, without it, this Mac drew [1.5 W](#power-draw) with the lid closed while Claude waited. These are different Macs, but it leaves Low Power Mode little to save. It would also take 18 more `pmset` commands in the sudoers rule, saving and restoring your own setting, and slower builds and tests while Claude works.
- **Presence signals for remote mode** (a flag file, pinging the phone on home Wi-Fi, `tailscale ping`) were replaced by watching for your own SSH login process, which needs no setup and no network assumptions.

## Reproduce

```sh
make test                               # fakes only: safe at any time
~/.claude/hooks/claude-coffee.sh status # the real thing, read-only
pmset -g | grep SleepDisabled           # mid-turn "SleepDisabled 1"; idle "SleepDisabled 0" or no line
ls ~/.claude/coffee/busy                # sessions that are mid-turn right now
ioreg -rn AppleSmartBattery | grep -oE '"SystemLoad"=[0-9]+'   # the whole machine's draw in mW, refreshed about once a minute
```

**Lid test:** start a long turn and close the lid for two minutes. `pmset -g log | grep -E 'Entering Sleep|Wake from' | tail -5` should show no sleep inside that window. Leave the lid shut past the end of the turn, and an `Entering Sleep state due to 'Software Sleep pid=…'` entry follows about a second later.

The kernel's own account of why the Mac did or didn't sleep is under [Troubleshooting](../README.md#troubleshooting) in the README.
