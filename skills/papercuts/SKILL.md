---
name: papercuts
description: >-
  Review the friction agents logged while working, grouped, deduped and ranked,
  with a concrete fix for each. Use when the user asks what friction agents hit,
  what has been annoying or getting in the way, what tooling should be fixed,
  what papercuts have piled up, or asks to review, triage or prune the
  papercuts log.
argument-hint: "[stats] [--since 7d] [--project X] [--agent A] [--category C] [--tool T] [--fixable yes]"
allowed-tools: [Bash, Read, Edit, Write]
---

# papercuts: turn the friction log into a fix list

This is the read side of the `papercut` CLI. Agents append one line per friction event;
this skill clusters those lines by root cause and says what to change.

**The deliverable is the fix list, not the report.** "gh came up 6 times" is half the job.
Naming the file to edit and what to change in it is the whole job.

## Arguments

`stats` switches to stats mode (see the end). Any other argument is a filter, passed straight
to `papercut`:
- `--since 7d`, `--since 12h` or `--since 2026-10-01`
- `--project X` (substring of the project or cwd)
- exact `--agent`, `--category`, `--tool` and `--fixable`

Filters go after the mode flag (`papercut --group --since 7d`), since the first argument picks
the mode. A bare invocation triages everything, all time.

## Procedure

### 1. Load

```bash
papercut --group --top 15 --limit 5 [filters]
```

If `entries` is 0, say so plainly. Mention that agents log with `papercut '...'` as described
in `AGENT-INSTRUCTIONS.md` (https://github.com/nkrebs13/papercut), and stop. Never invent
entries. If there are entries but `group_count` is 0 and both `regressions` and
`wontfix_resurfacing` are empty, say that nothing needs attention, give the `resolved` counts,
and stop.

`papercut --group` prints one JSON object with everything triage needs. Damaged log lines
are already skipped, and the triage ledger is already applied:

| Field | What it holds |
|---|---|
| `entries` | How many entries passed the filters. |
| `states` | Those entries counted by triage state: untriaged, resolved, regressed, after_ticketed, after_wontfix. |
| `groups` | Open entries (untriaged, or logged after a ticketed decision), grouped by tool, biggest first. Each has `count`, `first`, `last`, `categories`, `agents`, `fixable`, `projects`, and the newest `entries` (ts, agent, category, fixable, project, text, plus `ticket` when a ticketed decision covers it), with `omitted` for the rest. |
| `group_count` | How many groups there are in all. `--top` shows only the biggest. |
| `regressions` | Fixes that didn't hold: per `fixed` decision, its reason, ref, the hits logged since, and their texts. |
| `wontfix_resurfacing` | `wontfix` decisions with 5 or more hits since, with the original reason. |
| `already_fixed` | Untriaged entries logged as `fixable: fixed`, as a count and per tool. |
| `resolved` | Entries covered by a decision, and how many decisions cover them. |

For each group you'll report whose `omitted` is above 0, load all its texts before clustering:
`papercut --group [same filters] --tool '<tool>' --limit <the group's count>` (`--tool ''` for
the group without a tool).
Groups with `omitted: 0` are complete. If `group_count` is more than the groups you loaded,
say how many you skipped.

### 2. Cluster

- A group is one tool. Within it, cluster by root cause by reading the texts. Two entries about
  the same missing flag are ONE papercut with count 2; an auth failure for the same tool is a
  separate cluster.
- The group with an empty tool clusters by text similarity, or folds into an obvious match.
- Rank clusters by size, then by most recent.
- Use judgment: never report near-identical lines as separate findings. Friction that hit
  several agents (`agents`) is one root cause; say which agents it hit.

### 3. Report

Per cluster:

```
<count> × <label>   [<categories>]
  Root cause:     <one sentence>
  Seen:           <first date> → <last date>, <projects>, fixable=<values>
  Representative: "<the clearest text>"
  Fix:            <the specific file and the specific change>
```

The Fix line is the deliverable. Read the file before recommending a change if you need to.

Where fixes usually go:

| Friction | Fix lands in |
|---|---|
| The papercut CLI, this skill or its doctrine | The papercut repo (where this skill is installed from); then re-run its `install.sh` so the copies in `~/.codex/AGENTS.md` and `~/.grok/AGENTS.md` refresh. |
| Claude Code doctrine | `~/.claude/CLAUDE.md` or `~/.claude/rules/*.md` |
| Codex | `~/.codex/AGENTS.md`, `~/.codex/config.toml` |
| Grok | Reads `~/.claude/rules` unless `[compat.claude]` turns that off; Grok-only rules go in `~/.grok/AGENTS.md` |
| Project context | That repo's `AGENTS.md` / `CLAUDE.md` |
| Hooks | That agent's hooks config |
| A skill gap | That skill's `SKILL.md` |
| A repeated manual sequence | A new script or skill |
| Codebase friction | Usually a refactor in that repo; say so. |

Friction only one agent hits usually points at that agent's instructions or permissions.

Section order. Each entry belongs to exactly one section: entries logged `fixable: fixed` go
only under Already fixed and don't count toward their cluster's size.

1. **🔁 Fixed but still biting** (first), from `regressions`. Give the reason, ref, hits since,
   and newest text. Say whether the fix was incomplete, didn't reach the path agents actually
   use, or the selector was too broad.
2. **🔧 Fix now.** Clusters of 3 or more that have a local fix, whatever their fixable value.
3. **👀 Watch.** Clusters of 2, or a single entry that blocked the task, plus
   `wontfix_resurfacing` with the original reason.
4. **✅ Already fixed**, from `already_fixed`. Offer one decision that covers them by field:
   ```bash
   papercut --resolve --dry-run --status fixed --fixable fixed --reason 'self-reported fixed at log time'
   ```
   then the same without `--dry-run`. It is a point in time, so re-run it periodically.
5. **📋 Not ours.** Clusters with no local fix path (usually `fixable: no`), whatever their
   size. Offer a wontfix decision whose reason names where the workaround is written down.
6. **Tail:** `Resolved: <resolved.decisions> decisions (<resolved.entries> entries)`, and a
   count of the one-off entries you didn't list. Keep the report scannable.

Mark a cluster whose entries carry a `ticket` as `(ticketed: <ref>)`.

### 4. Offer to act

Be concrete. Never ask "what would you like to do?".

- "Fix the top item now: `<name it>`?" If yes, do the full job: make the fix, verify it against
  the real system, update the docs.
- "Record these decisions?" with the exact `papercut --resolve` commands.

## Recording decisions

Never edit the log to record a decision. Dry-run first, then record:

```bash
# fixed: scoped to the one root cause you fixed
papercut --resolve --dry-run --status fixed --tool 'pnpm test' --match 'wrong cwd|no files' \
  --reason 'documented the cwd in docs/setup.md' --ref 'PR#42'

# wontfix: the reason names where the workaround is written
papercut --resolve --status wontfix --tool docker --match 'compose.*orphan' \
  --reason 'upstream behavior; workaround is in docs/setup.md'

# ticketed: tracked elsewhere; give --ref, no reason needed
papercut --resolve --status ticketed --tool ./scripts/deploy.sh --ref 'PR#57'

# fixed, selected by field alone
papercut --resolve --status fixed --fixable fixed --reason 'self-reported fixed at log time'
```

| Status | Meaning |
|---|---|
| `fixed` | The problem is gone. Later hits are regressions and show at the top. |
| `wontfix` | Not ours or not worth it, and the workaround is written down. The reason must say where. Returns to Watch at 5 or more later hits. |
| `ticketed` | Tracked elsewhere, with the ref in `--ref`. Entries up to it count as resolved; later hits come back in `groups`, carrying the ref as `ticket`. |

Ledger honesty:

- Scope a selector to ONE root cause. Use `--match` for the cluster you actually fixed and check
  the dry-run count against the cluster size. An over-broad `fixed` decision hides live friction.
  Oniguruma lookahead works for exclusions, e.g. `'^(?!.*auth).*timeout'`.
- A selector that matches nothing is refused with exit 2, and the error lists similar tool values.
- Only record decisions the user asked for or clearly approved, and quote the command you ran.

## Pruning (rare)

The log is appended by concurrent sessions, and writers take no lock, so any rewrite can race
one. Prune only on an explicit user request (for example, a secret was pasted into an entry), and
ask the user to stop other agent sessions first. Back up, filter a fixed prefix of the file,
carry over any lines appended meanwhile, `mv` it over, and report line counts:

```bash
LOG=$(papercut --where | sed -n 's/^log: //p')
BAK="$LOG.bak.$(date +%Y%m%d%H%M%S)"; cp "$LOG" "$BAK"
n=$(wc -l < "$LOG" | tr -d ' ')
# keep every other line exactly as it is, damaged ones included
head -n "$n" "$LOG" | jq -R -r '. as $raw | (try fromjson catch null) as $o
  | if $o != null and ($o.text // "" | test("the-secret-or-pattern"; "i")) then empty else $raw end' > "$LOG.tmp"
tail -n +"$((n + 1))" "$LOG" >> "$LOG.tmp"   # entries written while filtering
mv "$LOG.tmp" "$LOG"
echo "lines: $n -> $(wc -l < "$LOG" | tr -d ' ')"
```

This narrows the window to the instant between the carry-over and the `mv`; it doesn't close
it, which is why other sessions should be stopped.

If the prune removed a secret, the backup still contains it. Once the line counts check out,
delete it (`rm "$BAK"`) and tell the user you did. For any other prune, keep the backup and say
where it is.

## Stats mode

```bash
papercut --stats [filters]
```

It prints:
- counts by category, agent, fixable and project;
- a 14-day trend;
- papercuts per session for each agent, over the `--since` window in days (default 30).

Report the highlights in a few lines.

Reading the per-session rate:

- A rate near zero for one agent means its instructions aren't reaching it or aren't firing.
  Check its global instructions: `~/.claude/rules/papercuts.md` for Claude Code (and Grok,
  unless Grok has its own copy in `~/.grok/AGENTS.md`), `~/.codex/AGENTS.md` for Codex. Run
  `install.sh --check` in the papercut repo, and check the Codex sandbox's writable roots.
- `n/a (no session files found)` means the rate couldn't be measured on this machine, not
  that it is zero.
- Many entries with no agent usually means Grok logged without `--agent grok`.
