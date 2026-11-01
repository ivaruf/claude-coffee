# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Heat guard: with the lid closed, serious thermal pressure or a battery at 45 °C (`HOT_BATTERY_C`) puts the Mac to sleep, even mid-turn, and keeps it there until the lid opens. It leaves a notification saying why. `HEAT_GUARD=0` turns it off.
- `status` shows the battery temperature, the thermal state and the heat guard.

### Changed

- The launch agent checks every minute instead of every 5, so the heat guard notices long jobs. `install.sh` reloads an agent installed by an older version.
- When idle, the check no longer re-applies `disablesleep 0` (a `sudo` call) every time.

### Fixed

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
