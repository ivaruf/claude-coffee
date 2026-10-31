# Contributing

Thanks for helping keep Macs caffeinated, and only when they should be.

## Run the tests

```sh
make test   # never touches your real sleep settings, sudoers or launch agents
make lint   # needs shellcheck: brew install shellcheck
```

`tests/hook.test.sh` runs the hook against fake `pmset`, `sudo`, `ioreg`, `pgrep` and `ps`. `tests/install.test.sh` runs the installer and uninstaller in a throwaway `$HOME` with fake `sudo` and `launchctl`.

> [!WARNING]
> Don't test `install.sh` by running it with a fake `$HOME` alone. It would still use your real `sudo` and `launchctl`. Use `tests/install.test.sh`.

## House rules

- **POSIX `sh`, no dependencies beyond macOS and `jq`.** The hook runs on every tool call, so keep it quick.
- **The hook prints nothing to stdout.** Anything it prints can end up in Claude's context. The tests enforce this.
- **Never exit 2 from the hook.** For `PreToolUse`, exit code 2 blocks the tool call.
- **Every behavior change comes with a test** in `tests/hook.test.sh`, with a short comment saying what it proves.
- **Hardware claims go in [docs/verification.md](docs/verification.md)**, together with how you checked them. If you tested on an Intel Mac or an older macOS, that's very welcome there.
- **Fail safe.** When in doubt, let the Mac sleep.

## Reporting a bug

Please include the output of `~/.claude/hooks/claude-coffee.sh status`, your macOS version, and your Mac model. If the Mac slept (or didn't) when it shouldn't have, the kernel's view helps most:

```sh
log show --last 1h --style compact --predicate 'process == "kernel" AND eventMessage CONTAINS "PMRD"' \
  | grep -E 'prevented|sleep reason|Clamshell closed'
```
