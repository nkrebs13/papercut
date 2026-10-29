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

You don't run that yourself; your agents do. You read the results with
`/papercuts`.

## Install

You need bash, curl, tar, [jq](https://jqlang.org) and python3 (`brew install jq`
or `apt install jq`). Python 3.11 or later is only needed for the Codex config
edit; without it that one step is skipped.

```bash
curl -fsSL https://raw.githubusercontent.com/nkrebs13/papercut/main/get.sh | bash
```

That sets up every agent with a home directory on your machine (`~/.claude`,
`~/.codex`, `~/.grok`): the `papercut` command, the instructions that tell
agents when to log, and the `papercuts` skill. To choose agents, add
`-s -- --agents claude,codex` after `bash`. Run the same line again to update.
Every file it changes is backed up first.

```bash
~/.local/share/papercut/install.sh --check    # what's missing or out of date
~/.local/share/papercut/install.sh --help     # exactly what it changes, per agent
~/.local/share/papercut/install.sh --uninstall && rm -rf ~/.local/share/papercut
```

Uninstall keeps your log and the `*.bak-papercut-*` backups.

## Use

Once installed, your agents log on their own. To see what they've hit, run
`/papercuts` in Claude Code or Grok (`$papercuts` in Codex). You get the
friction grouped by root cause and ranked, with the file to change for each
problem. The skill then offers to fix the top item and to record what you've
fixed or decided to live with, so those drop off the list, and a fix that
didn't hold comes back to the top.

Narrow it with filters, e.g. `/papercuts --since 7d` or `/papercuts --tool gh`,
or run `/papercuts stats` for counts, trends and how often each agent logs.

The log is one append-only file shared by all your agents, at
`~/.local/state/papercut/papercuts.jsonl`. The `papercut` CLI is for agents;
`papercut --help` documents it if you want to poke at the log directly.

## Develop

Work from a clone instead of the one-liner:

```bash
git clone https://github.com/nkrebs13/papercut.git && cd papercut && ./install.sh
```

It takes the same flags. The installed pieces then point into the clone (it
repoints any made by the one-liner), so keep the clone where it is and run
`./install.sh` again after a `git pull`.

```bash
shellcheck bin/papercut install.sh get.sh tests/*.sh
(for t in tests/test-*.sh; do bash "$t" || exit 1; done)
```

The tests use a throwaway `HOME` and never touch your real setup.

## Credits

The idea comes from [Steve Ruiz's papercuts tool](https://x.com/steveruizok/status/2075303919664734295).
MIT licensed; see [LICENSE](LICENSE).
