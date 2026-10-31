# claude-coffee

One POSIX `sh` script (`claude-coffee.sh`) wired into Claude Code hooks, plus `install.sh`/`uninstall.sh`.

- Test with `make test`. It uses fakes and is safe at any time.
- Never run `install.sh` or `uninstall.sh` directly, not even with a fake `$HOME`: they would call the real `sudo` and `launchctl`. `tests/install.test.sh` is the safe way.
- The hook must print nothing to stdout and must never exit 2 (that blocks `PreToolUse`).
- New behavior → a test in `tests/hook.test.sh`; real-hardware findings → `docs/verification.md`.
