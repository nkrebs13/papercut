# Papercuts: log the friction you hit

Applies to every agent on this machine: Claude Code, Codex, and Grok. They all
write to one shared log.

## The rule

**When you hit friction during work, log it with one shell command, then keep working.**

```bash
papercut --tool <what-caused-it> 'what I was doing -> what broke -> what would have avoided it'
```

- **Single-quote the text.** Inside double quotes the shell runs backticks and
  expands `$name`, so the logged text gets corrupted (or a command runs). If the text
  itself contains a `'`, pass it on stdin with a quoted heredoc instead:
  `papercut --tool rg - <<'EOF'` … `EOF`.
- **Grok must add `--agent grok`.** Codex and Claude Code are detected automatically.
- If `papercut` is not on PATH, use the full path: `~/.local/bin/papercut`.
- It prints nothing on success. Don't narrate it, don't ask permission, don't stop
  the task. Log it and carry on.

## Why

Friction gets worked around silently. A missing flag becomes a hand-rolled curl,
a bad glob gets retyped, a stale README gets reverse-engineered. The task
succeeds, so the friction never shows up in the summary. Your user can only fix
friction they can see, and every unlogged papercut gets rediscovered and paid for
again by the next session.

Log the 30-second workaround too. Multiplied across every session and agent,
that's where the time goes.

## When to log

Pick the matching `--category` (default is `tooling`).

- **tooling**: a CLI or script lacked a flag you needed; you hand-rolled a
  `curl`/`python3`/`node` call around a wrapper; a tool silently guessed instead
  of refusing an ambiguous input; output buried the useful line.
- **env**: auth, a token, or config was somewhere other than documented; a build
  needed a gitignored local file nobody mentioned; a daemon or service had to be
  in an unmentioned state.
- **docs**: an AGENTS.md, CLAUDE.md, rule file, or README was stale or wrong; two
  docs disagreed; something you needed existed nowhere.
- **shell**: quoting, globbing, or expansion bit you (zsh `nomatch` on an
  unquoted glob, a word starting with `=`, missing word-splitting); a command
  needed a non-obvious cwd.
- **test**: tests ran from the wrong cwd and found nothing or passed vacuously;
  a build/test target name wasn't discoverable; a cache lied.
- **codebase**: a module fought you for non-obvious reasons; misleading naming;
  inconsistent patterns.
- Any category: an error message that didn't point at its fix.

## How to write one

Three parts: **what I was doing → what broke → what would have avoided it.**
One or two sentences. The third part turns a complaint into a fix.

Bad: `"rg was annoying"`, `"the build failed"`, `"docs were wrong"`.

Good:
- `papercut --category shell --tool rg 'Searching for callers, an unquoted zsh ** glob gave a no-matches error before rg ran, which read as zero callers. Quoting the glob avoids it.'`
- `papercut --category test --tool 'pnpm test' 'Verifying a form fix in a monorepo, vitest found no files from the repo root because tests resolve from apps/web. Documenting the cwd in AGENTS.md would avoid it.'`

Always pass `--tool` when you can name the culprit (`rg`, `gh`, `pnpm test`,
`./gradlew`, a script path, a module). It's the clustering key.

`--fixable`: `yes` = you could have fixed it but didn't; `no` (default) = not
yours to fix; `fixed` (or `--fixed`) = you fixed it and are logging so the
friction still counts.

## Logging does not replace fixing

If the friction is in a tool or doc you can edit, fix it as part of the task,
then log with `--fixed`. Logging is for making friction visible, not an excuse
to skip a fix. It's most useful for things you can't fix in this session:
upstream CLIs, another repo, a decision that's your user's to make.

## Don't log

- Your own mistakes with no tooling lesson (a typo, a misread file).
- The same root cause twice in one session.
- Things that worked, even if the task was hard.
- Speculation about what might confuse someone else.

## Reading them back

- `papercut --tail 10`: recent entries. `papercut --count`: totals.
- The `papercuts` skill (`/papercuts` in Claude Code or Grok, `$papercuts` in
  Codex) groups, dedupes, and ranks the log, then recommends concrete fixes.
- When a cluster is dealt with, record a decision instead of editing the log:
  `papercut --resolve --status fixed --tool <tool> --match '<regex>' --reason '<what changed>'`.
  Dry-run first with `--dry-run`. Never edit `papercuts.jsonl` in place; other
  sessions append to it concurrently.

`papercut --where` prints the log's path. The tool, this file and the skill
come from the papercut repo; `~/.local/bin/papercut` is a symlink into it.
