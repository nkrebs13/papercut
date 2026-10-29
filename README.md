# papercut

Coding agents (Claude Code, Codex, Grok) log friction they hit, e.g. a missing flag or a stale doc, with one command and keep working. The `/papercuts` skill groups the log by root cause and ranks fixes.

An agent's log entry:

```bash
papercut --tool rg --category shell 'Searching for callers, an unquoted ** glob failed in zsh before rg ran. Quoting the glob avoids it.'
```

## Requirements

bash, curl, tar, [jq](https://jqlang.org), python3. The Codex `config.toml` edit needs Python 3.11+ and is skipped otherwise.

## Install

Every agent with a home directory (`~/.claude`, `~/.codex`, `~/.grok`). With none of them present, pass `--agents`.

```bash
curl -fsSL https://raw.githubusercontent.com/nkrebs13/papercut/main/get.sh | bash
```

Claude Code only:

```bash
curl -fsSL https://raw.githubusercontent.com/nkrebs13/papercut/main/get.sh | bash -s -- --agents claude
```

Claude Code and Codex:

```bash
curl -fsSL https://raw.githubusercontent.com/nkrebs13/papercut/main/get.sh | bash -s -- --agents claude,codex
```

Re-run the same command to update. Edited files are backed up to `<file>.bak-papercut-<time>`.

```bash
~/.local/share/papercut/install.sh --check       # report missing or stale pieces
~/.local/share/papercut/install.sh --help        # list every change, per agent
~/.local/share/papercut/install.sh --uninstall && rm -rf ~/.local/share/papercut
```

Uninstall keeps the log and the backups.

## Usage

Agents log on their own. To review the log, run the skill in Claude Code or Grok (`$papercuts` in Codex):

```
/papercuts                # ranked friction, grouped by root cause
/papercuts --since 7d     # last 7 days
/papercuts --tool gh      # one tool
/papercuts stats          # counts, 14-day trend, per-agent rates
```

Each group names the file to change. The skill can fix the top item and record decisions. Resolved items drop off the list; a fix that didn't hold returns to it.

The log is `~/.local/state/papercut/papercuts.jsonl`, shared by all agents. `PAPERCUT_LOG` or `XDG_STATE_HOME` moves it, and `papercut --where` prints the path. `papercut --help` documents the CLI.

## Development

```bash
git clone https://github.com/nkrebs13/papercut.git && cd papercut && ./install.sh
```

The installed symlinks point into the clone, so keep it in place. After `git pull`, re-run `./install.sh` to refresh the `AGENTS.md` copies for Codex and Grok.

```bash
shellcheck bin/papercut install.sh get.sh tests/*.sh
(for t in tests/test-*.sh; do bash "$t" || exit 1; done)
```

Tests run against a temporary `HOME`.

## Credits

Based on [Steve Ruiz's papercuts tool](https://x.com/steveruizok/status/2075303919664734295). MIT licensed, see [LICENSE](LICENSE).
