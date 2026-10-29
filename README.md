# papercut

papercut gives coding agents (Claude Code, Codex, Grok) a one-line way to
report friction they hit while working (a missing flag, a stale doc, a shell
trap) without stopping. A companion skill turns those reports into a ranked
list of fixes.

Agents usually push through friction without saying anything, so you never
hear about it and the next session runs into it again. With papercut, each
time an agent hits something like that, it runs a command like this:

```bash
papercut --tool rg --category shell 'Searching for callers, an unquoted ** glob failed in zsh before rg ran. Quoting the glob avoids it.'
```

You don't run that yourself; your agents do. You read the results.

## What you get

- `papercut`, a small CLI (bash + jq) that appends each report to a log
- `AGENT-INSTRUCTIONS.md`, the instructions your agents get: when to log and how
- the `papercuts` skill, which groups the log by root cause, ranks it, and names
  the file to change for each problem

## Install

You need bash, curl, tar, [jq](https://jqlang.org) and python3 (`brew install jq`
or `apt install jq`). Python 3.11 or later is only needed for the Codex config
edit; without it that one step is skipped.

```bash
curl -fsSL https://raw.githubusercontent.com/nkrebs13/papercut/main/get.sh | bash
```

That downloads the latest release into `~/.local/share/papercut` and sets up
every agent that has a home directory on your machine (`~/.claude`, `~/.codex`,
`~/.grok`). To choose, pass `--agents`:
`curl -fsSL … | bash -s -- --agents claude,codex`. Run the same line again to
update. Here's what it changes:

| Agent | Changes |
|---|---|
| all | symlinks `~/.local/bin/papercut` into `~/.local/share/papercut` |
| Claude Code | adds the instructions to `~/.claude/rules/` and the skill to `~/.claude/skills/` |
| Codex | adds the instructions to `~/.codex/AGENTS.md`, the skill to `~/.codex/skills/`, and the log folder to the sandbox's writable folders in `~/.codex/config.toml` |
| Grok | nothing if Claude Code is set up too, since Grok reads Claude's copy by default; otherwise the instructions and the skill in `~/.grok/` |

The installer backs up every file before changing it. To check or remove it:

```bash
~/.local/share/papercut/install.sh --check    # what's missing or out of date
~/.local/share/papercut/install.sh --uninstall && rm -rf ~/.local/share/papercut
```

Uninstall removes the `papercut` command and everything else it added, and keeps
your log and the `*.bak-papercut-*` backups.

To work from a clone instead:

```bash
git clone https://github.com/nkrebs13/papercut.git && cd papercut && ./install.sh
```

It takes the same flags. The installed pieces then point into the clone (it
repoints any made by the one-liner), so keep the clone where it is and run
`./install.sh` again after a `git pull`.

Grok reads Claude's rules and skills unless `[compat.claude]` in
`~/.grok/config.toml` turns that off. So if you install for Claude but not
Grok, Grok still sees papercut.

## Use

Once installed, your agents log on their own. To read what they've logged,
run `/papercuts` in Claude Code or Grok, or `$papercuts` in Codex. When you
fix something, record it:

```bash
papercut --resolve --status fixed --tool rg --match glob --reason 'quoted the globs in AGENTS.md'
```

The skill then stops reporting that problem, and moves it to the top if it
comes back. A few other commands:

```bash
papercut --tail 5                 # the latest entries
papercut --stats --since 7d       # counts, trends, and how often each agent logs
papercut --group --tool gh        # what the skill reads, as JSON, for one tool
papercut --where                  # where the log is
papercut --help                   # everything else
```

The log is one shared file for all your agents. By default it's
`~/.local/state/papercut/papercuts.jsonl`, one JSON object per line. It's
append-only, so many sessions can write to it at once.

## Develop

```bash
shellcheck bin/papercut install.sh get.sh tests/*.sh
(for t in tests/test-*.sh; do bash "$t" || exit 1; done)
```

The tests use a throwaway `HOME` and never touch your real setup.

## Credits

The idea comes from [Steve Ruiz's papercuts tool](https://x.com/steveruizok/status/2075303919664734295).
MIT licensed; see [LICENSE](LICENSE).
