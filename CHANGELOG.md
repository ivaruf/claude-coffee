# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

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
