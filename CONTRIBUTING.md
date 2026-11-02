# Contributing

Thanks for helping keep Macs caffeinated, and only when they should be.

## Run the tests

```sh
make test   # never touches your real sleep settings, sudoers or launch agents
make lint   # needs shellcheck: brew install shellcheck
```

`tests/hook.test.sh` holds the hook's scenarios; `tests/fixtures/<os>.sh` fakes one system's commands (and `uname`) for them, so every backend runs on any machine. `tests/install-<os>.test.sh` runs that system's installer and uninstaller in a throwaway `$HOME`. `tests/run.sh` (and `make test`) runs them all.

> [!WARNING]
> Don't test `install.sh` by running it with a fake `$HOME` alone. It would still use your real `sudo` and `launchctl`. Use `tests/install.test.sh`.

## House rules

- **POSIX `sh`, no dependencies beyond macOS and `jq`.** The hook runs on every tool call, so keep it quick.
- **The hook prints nothing to stdout.** Anything it prints can end up in Claude's context. The tests enforce this.
- **Never exit 2 from the hook.** For `PreToolUse`, exit code 2 blocks the tool call.
- **Every behavior change comes with a test** in `tests/hook.test.sh`, with a short comment saying what it proves.
- **One condition per command in tests.** The suites rely on `set -e`, which ignores a failure anywhere in an `a && b` list except the last command, so `[ a ] && [ b ]` never checks `a`. Write `[ a ]; [ b ]` instead.
- **Hardware claims go in [docs/verification.md](docs/verification.md)**, together with how you checked them. If you tested on an Intel Mac or an older macOS, that's very welcome there.
- **Fail safe.** When in doubt, let the Mac sleep.

## Reporting a bug

Please include the output of `~/.claude/hooks/claude-coffee.sh status`, your macOS version, and your Mac model. If the Mac slept (or didn't) when it shouldn't have, the kernel's view helps most:

```sh
log show --last 1h --style compact --predicate 'process == "kernel" AND eventMessage CONTAINS "PMRD"' \
  | grep -E 'prevented|sleep reason|Clamshell closed'
```
