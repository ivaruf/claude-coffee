# Field notes: what was checked, and how

claude-coffee was built on a real Mac on 2026-10-31: a MacBook Pro on macOS 26.6.2, Apple silicon, OpenSSH 10.3. Every assumption the design depends on was checked against the docs or the hardware. This is the record, warts included.

## The two bugs real hardware found

Both passed a first round of reasoning and only failed on the machine. Both are now covered by `tests/hook.test.sh`.

### 1. `Stop` didn't remove the marker

macOS `/bin/sh` has `echo` expand escape sequences. The `Stop` hook input includes Claude's last reply as a JSON string, and the `\n` in it turned into a raw newline. `jq` then rejected the JSON, so there was no `session_id`, so the marker stayed and the Mac stayed awake until the 30-minute limit.

**Fix:** `printf '%s\n'` instead of `echo`. The test sends a reply containing `\n` and `\"`.

### 2. Turning sleep back on with the lid already closed didn't sleep the Mac

The kernel logged `System sleep prevented by kPMUserDisabledAllSleep` when the lid closed and never looked again when the value went back to 0. So a lid closed mid-turn left the Mac awake after the turn, indefinitely.

**Fix:** when the last session finishes, the lid is closed and closing the lid normally causes sleep, wait a second and run `pmset sleepnow`. Verified: `sleep reason Software Sleep`, requested by `pmset`, 1.1 s after re-enabling. `pmset sleepnow` works without root.

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
| `pmset -g` shows `SleepDisabled` | It shows ` SleepDisabled		1` when the value is 1 and no line at all when it's 0. The script treats a missing line as "re-apply 0", so it can't get stuck awake. |
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
```

The lid test and the kernel log query are in the [README](../README.md#verify-it-yourself).
