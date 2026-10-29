# Changelog

## 0.1.0 - 2026-10-28

First public release.

- `papercut`, a bash + jq CLI that appends one-line friction reports to a
  shared JSONL log. It detects Claude Code and Codex sessions automatically;
  Grok, or anything else, passes `--agent` or sets `PAPERCUT_AGENT`.
- Read modes: `--tail`, `--count`, `--annotate` and `--where`. A damaged log
  line is skipped rather than hiding the rest, and control characters are
  stripped before anything is printed.
- A triage ledger. `--resolve` records fixed, wontfix or ticketed decisions in
  a separate file instead of rewriting the log, and `--triage` lists them,
  flagging fixes that didn't hold.
- The `papercuts` skill for Claude Code, Codex and Grok: it groups the log by
  root cause and ranks it into a fix list.
- `install.sh` sets it up for any mix of Claude Code, Codex and Grok
  (`--agents`), with `--check` and `--uninstall`. Uninstall removes what
  install added and deletes the files it created.
