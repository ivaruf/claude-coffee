# Security

On Linux and Windows, claude-coffee asks for no privilege at all: a logind lock (Linux) and your own power plan (Windows) are yours to change.

On macOS it asks for one: a sudoers rule that lets your user run exactly

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

without a password. Nothing else runs as root. The rule names both commands literally, because a `disablesleep *` wildcard would also match whitespace and let any other `pmset` setting be appended. The installer checks the rule with `visudo -cf` before installing it as `root:wheel 0440`.

The hook trusts only the `session_id` from Claude Code's hook input, and strips it to `[A-Za-z0-9_-]` before using it as a filename.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (**Security → Report a vulnerability** on the repository) instead of a public issue.
