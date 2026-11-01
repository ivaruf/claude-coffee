<p align="center">
  <img src="docs/assets/banner.svg" alt="claude-coffee: your Mac stays awake while Claude is brewing" width="100%">
</p>

<p align="center">
  <a href="https://github.com/ivaruf/claude-coffee/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/ivaruf/claude-coffee/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-Apple%20silicon-111111?logo=apple&logoColor=white">
  <img alt="One POSIX shell script" src="https://img.shields.io/badge/POSIX%20sh-one%20script-4EAA25?logo=gnubash&logoColor=white">
  <a href="https://code.claude.com/docs/en/hooks"><img alt="Claude Code hooks" src="https://img.shields.io/badge/Claude%20Code-hooks-D97757"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center">
  <b>Close the lid. Claude keeps working. The Mac sleeps the moment it's done.</b>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="#why-not-caffeinate-or-amphetamine">Why not caffeinate?</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#remote-mode">Remote mode</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="docs/verification.md">Field notes</a>
</p>

---

You ask Claude Code for a big refactor, close the lid, and walk to a meeting. macOS goes to sleep, the turn freezes, and you come back to a half-finished job. Turning sleep off for good isn't better: you forget to turn it back on, and the Mac cooks in your bag.

**claude-coffee ties sleep to what Claude is actually doing.** A handful of Claude Code hooks keep track of every session that is mid-turn. While any of them is working, the Mac stays awake, lid closed included. When the last one finishes, sleep comes back, and if the lid is already shut, the Mac goes to sleep about a second later.

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/ivaruf/claude-coffee/main/install.sh | sh
```

Or from a clone, if you'd like to read it first:

```sh
git clone https://github.com/ivaruf/claude-coffee
cd claude-coffee
./install.sh
```

Either way, the installer may ask for your password once, and that's it. Running sessions pick it up on their next turn.

```console
$ ~/.claude/hooks/claude-coffee.sh status
claude-coffee
  sleep          blocked
  busy sessions  2
  remote mode    off (no SSH login)
  lid            closed
  heat           battery 31 °C, thermal state nominal
  heat guard     armed: lid closed and serious thermal state or battery 45 °C → sleep
  sudo pmset     ok
  launch agent   ok
```

> [!TIP]
> `alias coffee='~/.claude/hooks/claude-coffee.sh status'` in your shell profile turns that into `coffee`.

<details>
<summary><b>What the installer changes</b> (all of it undone by <code>./uninstall.sh</code>)</summary>

| | What | Where |
|---|---|---|
| 1 | The hook script | `~/.claude/hooks/claude-coffee.sh` |
| 2 | Five hook groups, added next to your own hooks without touching them. A backup is kept | `~/.claude/settings.json` |
| 3 | Passwordless `pmset -a disablesleep 0` and `1`, checked with `visudo` first | `/etc/sudoers.d/claude-coffee` |
| 4 | A launch agent that runs `claude-coffee.sh check` every minute | `~/Library/LaunchAgents/com.github.ivaruf.claude-coffee.plist` |

Running the installer again, either way, is safe; it's also how you update. Piped through `sh`, it downloads `claude-coffee.sh` from the same branch. macOS will show a notification that *claude-coffee.sh can run in the background*. That's the launch agent; it shows up under System Settings → General → Login Items & Extensions.

**Requirements:** macOS, Claude Code, and `jq` (built into recent macOS; otherwise `brew install jq`).

</details>

<p align="center">
  <img src="docs/assets/brewing.svg" alt="An open MacBook between a plant and a steaming mug, with Claude Code at work: Brewing, 12 minutes 40 seconds. A coffee cup in the menu bar shows the Mac is being kept awake." width="100%">
</p>

## Why not caffeinate or Amphetamine?

Each one solves half the problem. `caffeinate` lets the Mac sleep again, but closing the lid still puts it to sleep in the middle of Claude's work. Amphetamine keeps a closed Mac running, but it keeps running until you remember to turn it off.

**With claude-coffee you can close the lid, *and* your Mac still gets to sleep.**

<p align="center">
  <img src="docs/assets/compare.svg" alt="Timeline of closing the lid mid-task. caffeinate: the Mac sleeps when the lid closes and Claude stops mid-task. Amphetamine: awake through the lid closing and long after Claude is done, until you turn it off. claude-coffee: awake through the lid closing, asleep a second after Claude finishes." width="100%">
</p>

<p align="center">
  <img src="docs/assets/lid-closed.svg" alt="Lid closed, still brewing: Claude sits on the closed MacBook with a steaming coffee, and the Mac is awake." width="49%">
  <img src="docs/assets/asleep.svg" alt="Done, fast asleep: Claude sleeps on the still-closed MacBook next to an empty mug, and the Mac is asleep." width="49%">
</p>

| | Close the lid mid-task | Sleeps again by itself | Knows when Claude is working |
|---|:---:|:---:|:---:|
| `caffeinate` (Claude Code already runs it during a turn) | ✗ the Mac sleeps, Claude stops | ✓ | ✓ |
| Amphetamine, closed-display mode | ✓ | ✗ only when you end the session or its timer runs out | ✗ |
| `sudo pmset -a disablesleep 1` by hand | ✓ | ✗ only when you remember to undo it | ✗ |
| **claude-coffee** | ✓ | ✓ a second after the last turn ends | ✓ |

Watching for a `claude` process doesn't work either: an idle session is still a process, and most people have several open. The question that matters is *is any session mid-turn?*, and only the hooks know that.

## Features

- **Awake while Claude works**: lid closed, on battery, across any number of sessions at once
- **Asleep when it's done**: no toggle, no timer, nothing to remember. A lid closed mid-turn sleeps right after the turn ends
- **Background-aware**: a turn that ends with subagents or shells still running stays awake until they report back
- **Remote mode**: SSH in from your phone and the Mac stays up between turns, too. It lapses after an hour of quiet
- **Heat guard**: if the closed Mac gets hot, say in a bag, it goes to sleep anyway, mid-turn, and leaves a notification saying why
- **Can't get stuck awake**: markers expire after 30 minutes and a launch agent re-checks every minute, so Esc, crashes and `kill -9` all wear off
- **Least privilege**: sudo is allowed to run exactly two commands, `pmset -a disablesleep 0` and `… 1`. Nothing else
- **Silent**: the hooks print nothing, so not a single token ends up in Claude's context
- **Tested**: CI runs the hook against fake `pmset`, `sudo` and `ioreg`, and the installer against a throwaway `$HOME`

## How it works

<p align="center">
  <img src="docs/assets/how-it-works.svg" alt="Sequence: 1, you send Claude Code a prompt. 2, the UserPromptSubmit hook runs claude-coffee.sh on. 3, it runs pmset -a disablesleep 1, and the Mac is kept awake. You close the lid and leave; Claude keeps going. 4, on every tool call, PreToolUse runs it on again. 5, when the turn ends, Stop runs it off. 6, it runs pmset -a disablesleep 0. 7, the lid is closed, so it runs pmset sleepnow and the Mac goes to sleep." width="100%">
</p>

1. **One marker per busy session.** Hooks keep a file per session in `~/.claude/coffee/busy/`. `UserPromptSubmit` and `PreToolUse` create or refresh it; `Stop`, `StopFailure` and `SessionEnd` remove it. A `Stop` that still lists `background_tasks` keeps it.
2. **Any marker means awake.** If any marker exists, the script runs `pmset -a disablesleep 1`; if none do, `0`. That is the one switch that also holds with the lid closed.
3. **Markers go stale.** Pressing Esc never fires `Stop`, so a marker no hook has touched for 30 minutes is dropped.
4. **A launch agent re-checks every minute**, so stale markers expire and the heat guard sees long jobs, even when no hook is firing.
5. **The lid gets a second chance.** macOS decides on lid sleep only at the moment the lid closes. If it closed mid-turn, switching sleep back on isn't enough, so the script runs `pmset sleepnow` a second later. That step is skipped when an external display keeps a closed Mac running.
6. **The heat guard has the last word.** With the lid closed, if macOS reports *serious* thermal pressure or the battery reaches 45 °C, sleep is allowed and the Mac sleeps now, even mid-turn. It stays that way until you open the lid, so a brief wake in the bag can't start the heat up again.

Every one of those steps exists because something needed it. [The field notes](docs/verification.md) list what was checked on a real Mac, including two bugs that only showed up there.

## Remote mode

Driving Claude Code from your phone over SSH (Termius, Blink, a Raspberry Pi, anything)? Then the Mac must stay up *between* turns too, or it falls asleep while you type the next prompt.

So while you're logged in over SSH, claude-coffee also keeps the Mac awake when no session is busy. It lapses 60 minutes after the later of the last hook event and the login, so a dead or forgotten connection can't keep the Mac up for good.

<details>
<summary>Tips for a phone setup</summary>

- Run `claude` inside `tmux` or `screen` (`screen` ships with macOS). If the connection drops, the session survives: reattach with `screen -dr`.
- The Mac has to be awake when you connect. Remote mode keeps it up; it doesn't wake it.
- Use key login: put your phone's public key in `~/.ssh/authorized_keys` and turn off password login.
- The detection looks for your own `sshd-session: you@ttys…` process (OpenSSH 9.8+, macOS 26) or `sshd: you@ttys…` (older OpenSSH).

</details>

## Configuration

Optional. Create `~/.claude/coffee/config` with any of these:

```sh
STALE_MINUTES=30   # drop a session's marker after this long with no hook activity
REMOTE=1           # 0 turns remote mode off
REMOTE_MINUTES=60  # how long remote mode lasts after the last activity
HEAT_GUARD=1       # 0 turns the heat guard off
HOT_BATTERY_C=45   # with the lid closed, a battery this hot (°C) means sleep
```

Raise `STALE_MINUTES` if your permission prompts tend to wait longer than half an hour, or if you run background jobs that stay silent that long.

## Safety

- **sudo can do exactly two things.** The rule lists `pmset -a disablesleep 0` and `pmset -a disablesleep 1` literally. A `disablesleep *` wildcard would be shorter, but `man sudoers` says wildcards also match whitespace, so any other `pmset` setting could ride along.
- **It fails safe.** Without the sudoers rule, `sudo -n` fails instantly and the Mac sleeps as usual. Markers expire, the launch agent re-checks, and remote mode lapses. Nothing can hold sleep off forever.
- **It never talks to Claude.** The hooks write nothing to stdout, so they cost no tokens and can't steer Claude. A test enforces this.

### Heat guard

<p align="center">
  <img src="docs/assets/too-hot.svg" alt="Little Claude, sweating, peeks out of a bag next to the closed MacBook while heat rises from it. A thermometer reads 45 °C, or thermal state serious. Status: too hot, then asleep." width="100%">
</p>

Start a heavy job, close the lid and toss the Mac in a bag, and it can't get rid of its heat. So with the lid closed, claude-coffee also watches two readings that need no root: macOS's thermal state and the battery's temperature sensor. If either crosses its limit, the Mac goes to sleep, even mid-turn, and leaves a notification saying why. It stays asleep until you open the lid, so a brief wake in the bag can't start the heat up again.

| Reading | Limit | Why that limit |
|---|---|---|
| Thermal state | *serious* | Apple's definition: "fans are … running at maximum speed" and "the system begins enacting countermeasures". It's the point where Apple tells apps to cut back. In a bag the fans can't help |
| Battery temperature | 45 °C | Apple doesn't publish one; its 10–35 °C range is for the room. 45 °C is the top of the lithium-ion charging range and Apple's highest storage temperature. Cells may discharge up to 60 °C |

Sources and measurements are in the [field notes](docs/verification.md#heat-guard). It's a safety net, not an invitation: closed on a desk is fine, closed in a bag still isn't.

## Verify it yourself

```sh
pmset -g | grep SleepDisabled            # mid-turn: "SleepDisabled 1"; idle: "SleepDisabled 0" or no line
ls ~/.claude/coffee/busy                 # sessions that are mid-turn right now
launchctl kickstart gui/$(id -u)/com.github.ivaruf.claude-coffee   # run the 5-minute check now

# Why did (or didn't) the Mac sleep? The kernel says so:
log show --last 1h --style compact --predicate 'process == "kernel" AND eventMessage CONTAINS "PMRD"' \
  | grep -E 'prevented|sleep reason|Clamshell closed'
# "System sleep prevented by kPMUserDisabledAllSleep" = claude-coffee; "by kPMCPUAssertion" = some other app
```

**Lid test:** start a long turn and close the lid for two minutes. `pmset -g log | grep -E 'Entering Sleep|Wake from' | tail -5` should show no sleep inside that window. Leave the lid shut past the end of the turn, and an `Entering Sleep state due to 'Software Sleep pid=…'` entry follows about a second later.

## Known limits

- Background work that runs longer than 30 minutes without any hook firing isn't covered: the marker goes stale and the Mac may sleep.
- A permission prompt left unanswered for more than 30 minutes counts as stale, too.
- After Esc, the Mac can stay awake for up to about 31 minutes (30 minutes stale limit plus the 1 minute check).
- The heat guard hasn't been tried in an actual bag yet, and during one long tool call it only reacts once a minute.
- A fanless MacBook Air doing heavy work with the lid closed and no external display can reach *serious* on a desk too. The heat guard then puts it to sleep.
- Verified on macOS 26 on Apple silicon. Intel Macs and older macOS versions should work but haven't been tested; [reports welcome](https://github.com/ivaruf/claude-coffee/issues/new/choose).

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/ivaruf/claude-coffee/main/uninstall.sh | sh
```

Or `./uninstall.sh` from a clone.

It works in an order that never leaves sleep switched off. First it removes everything that could switch sleep off (the launch agent, the hooks, the script). Then it switches sleep back on and checks that it took. Then it removes the sudoers rule and the state. If a step fails, it carries on with the rest and tells you what is left. Your `settings.json` backup stays in place.

## FAQ

<details>
<summary><b>Doesn't Claude Code already keep my Mac awake?</b></summary>

It runs `caffeinate` during a turn, which stops *idle* sleep. Closing the lid still puts the Mac to sleep. That's the gap this fills.
</details>

<details>
<summary><b>Why does it need sudo at all?</b></summary>

Keeping a Mac awake with its lid closed and no external display takes root, and `pmset -a disablesleep` is the switch for it. It's missing from `man pmset`, but it's in the binary and works (verified on macOS 26). The sudoers rule lets your user flip that one switch and nothing else.
</details>

<details>
<summary><b>I run several sessions, and subagents. Does that work?</b></summary>

Yes. Every session gets its own marker, and the Mac stays awake while any of them is busy. A subagent either shares its session's marker or creates its own; either way, it keeps the Mac awake.
</details>

<details>
<summary><b>What happens when I press Esc?</b></summary>

Esc doesn't fire `Stop`, so the marker stays until it's 30 minutes old and the next check drops it. Your next prompt in that session refreshes it as usual.
</details>

<details>
<summary><b>Does it work in VS Code, JetBrains or the desktop app?</b></summary>

It's driven by the hooks in `~/.claude/settings.json`, so any Claude Code that loads them takes part. It was built and tested with the CLI.
</details>

<details>
<summary><b>Does it read real temperatures?</b></summary>

Two, neither needing root: the battery's own temperature sensor (via `ioreg`), and macOS's thermal state (nominal, fair, serious, critical), the same signal it uses to throttle. CPU and SoC die temperatures would need root (`powermetrics`) or private APIs, so claude-coffee doesn't use them. `claude-coffee.sh status` shows both readings.
</details>

<details>
<summary><b>Does it drain my battery?</b></summary>

Only while Claude is working, which is the point. Between turns, sleep works exactly as before (outside remote mode).
</details>

## Brewed with Claude

claude-coffee started as a question typed into the Claude app on a phone: *"maybe I could have Claude Code automatically pmset when a session is running, and turn it off when no session is active?"* A few rounds in that chat sketched the design. Then Claude Code built it on a real Mac, tested it with the lid closed and recorded every assumption it checked. Two bugs only showed up on real hardware. Both are fixed and covered by tests, and the [field notes](docs/verification.md) have the details.

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). `make test` runs everything, and it never touches your real sleep settings.

## License

[MIT](LICENSE). Not affiliated with Anthropic. Claude is a trademark of Anthropic.
