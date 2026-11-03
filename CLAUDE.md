# claude-coffee

One POSIX `sh` script (`claude-coffee.sh`) wired into Claude Code hooks, plus `install.sh`/`uninstall.sh`.

- Test with `make test`. It uses fakes and is safe at any time.
- Never run `install.sh` or `uninstall.sh` directly, not even with a fake `$HOME`: they would call the real `sudo`, `launchctl`, `systemctl` or `powercfg`. `tests/install-<os>.test.sh` is the safe way.
- The hook must print nothing to stdout and must never exit 2 (that blocks `PreToolUse`). The one exception is `wait`: only the `StopFailure` group runs it, in the background (`asyncRewake`), and its exit 2 is what wakes Claude to carry on. And `off`, on a `StopFailure` the internet cut short, prints one `terminalSequence` (the terminal title; Claude Code discards every other output of `StopFailure`). The session's next `on`, and the woken turn's `Stop`, print one too: "back", then the session's own title.
- Platform-specific code lives in the `case $(uname -s)` block of `claude-coffee.sh` and in `<os>_*` functions of the installers; each OS has a fixture in `tests/fixtures/` that fakes its commands, and `make test` runs every backend on any machine.
- New behavior → a test in `tests/hook.test.sh`; real-hardware findings → `docs/verification.md`.
