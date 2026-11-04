# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `AWAKE_ON_AC=1`: while plugged in, the machine stays awake, lid closed too, whether Claude is working or not, so you can reach it from elsewhere. Unplugged, the usual rules are back within a minute, and the heat guard still applies. Off by default.
- Auto-continue: when the internet cuts a turn short, claude-coffee keeps the machine awake, checks every 20 seconds whether the API answers, then wakes Claude to carry on (a background `StopFailure` hook with `asyncRewake`). It gives up after `OFFLINE_MINUTES` (60), after three tries in a row with no tool call, or when a guard steps in, and lets the machine sleep. Notifications, the terminal's title (the session's name, with a note while it waits and a cheer when it's back) and `status` keep you posted, with little Claude's worries. `AUTO_CONTINUE=0` turns it off.

- Linux (beta): a logind lock on sleep, idle and the lid switch, held by a transient user unit, with no root; a systemd user timer for the minute check; lid from logind, power and heat from sysfs. Not yet run on real hardware.
- Windows in Git Bash (beta): the power plan's lid action and sleep timeout, set to "do nothing" and "never" while Claude works and put back afterwards, with no admin; a scheduled task for the minute check; lid, power, heat and processes through PowerShell, cached for the hooks. Not yet run on real hardware.
- Tests for every backend run on any machine (each fixture fakes its system's commands and `uname`), and CI runs them on macOS, Ubuntu and Windows.
- Battery guard: on battery at 20% or less (`LOW_BATTERY`), claude-coffee stops keeping the Mac awake, even mid-turn, and with the lid closed the Mac sleeps right away. It leaves one notification, and plugging in clears it. `status` shows the power source and charge.
- Long jobs: a marker no hook has touched for 30 minutes now stays, for up to `MAX_QUIET_HOURS` (4), while Claude Code is still at work. That means its own `caffeinate` is running (a long tool call), or processes it started use CPU or start new ones (a background build). An idle dev server doesn't count.
- Install and uninstall straight from GitHub: `curl -fsSL https://raw.githubusercontent.com/ivaruf/claude-coffee/main/install.sh | sh`. Without a clone, the installer downloads `claude-coffee.sh` from the same branch. Both scripts run only once they're fully downloaded.
- Heat guard: with the lid closed, serious thermal pressure or a battery at 45 °C (`HOT_BATTERY_C`) puts the Mac to sleep, even mid-turn, and keeps it there until the lid opens. It leaves a notification saying why. `HEAT_GUARD=0` turns it off.
- `status` shows the battery temperature, the thermal state and the heat guard.

### Changed

- After a restart, markers from before it are dropped (macOS keeps `disablesleep` across a restart), and the launch agent also runs at login, so a Mac restarted mid-turn gets its sleep back as soon as you log in. Windows has no cheap boot ID; there those markers expire after 30 minutes.
- Before `pmset sleepnow`, the hook waits (up to 5 s) for the kernel's own `SleepDisabled` flag to clear, rather than a fixed second: `pmset -g` shows the saved setting, and the kernel refuses to sleep until powerd has applied it.
- Linux on GNOME: the lock also runs `gnome-session-inhibit --inhibit suspend`, since GNOME's automatic suspend asks gnome-session, and before systemd 257 got past a user's own logind locks. Without GNOME it falls back to a plain wait.
- The launch agent checks every minute instead of every 5, so the heat guard notices long jobs. `install.sh` reloads an agent installed by an older version.
- When idle, the check no longer re-applies `disablesleep 0` (a `sudo` call) every time.

### Fixed

- macOS remote mode missed the SSH login Claude itself runs in (`pgrep` leaves out its own ancestors without `-a`), so with the lid closed the Mac slept at the end of every turn sent from a phone.
- `curl … | sh` decides that it was piped from `$0` alone, so a `claude-coffee.sh` in the current folder can't be installed instead of the download.
- If a turn started during the one-second wait before `pmset sleepnow`, the Mac could be put to sleep mid-turn. The hook now checks again right before sleeping.
- `uninstall.sh` stopped before restoring sleep when `settings.json` was invalid JSON, and never checked whether sleep was actually restored. It now removes the script before restoring sleep, checks the result, finishes the remaining steps, and exits 1 listing what is left.
- The shellcheck findings that turned CI red.
- Three test checks written as `[ a ] && [ b ]`. Under `set -e` they never checked `a`.

## [0.1.0] - 2026-10-31

First public release, extracted from a personal setup that ran for a day of real use.

### Added

- `claude-coffee.sh`: keeps the Mac awake, lid closed too, while any Claude Code session is mid-turn
- Background-aware `Stop`: stays awake while subagents or background shells are still running
- Lid-closed sleep: runs `pmset sleepnow` when the last turn ends with the lid already shut
- Remote mode: stays awake between turns while you're logged in over SSH, and lapses after 60 quiet minutes
- `status` command
- Optional config file (`~/.claude/coffee/config`)
- `install.sh` and `uninstall.sh`, with an exact two-command sudoers rule validated by `visudo`
- Test suites for the hook and the installer, and CI with shellcheck on macOS

[0.1.0]: https://github.com/ivaruf/claude-coffee/releases/tag/v0.1.0
