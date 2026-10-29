---
name: papercuts
description: >-
  Review the friction agents logged while working, grouped, deduped and ranked,
  with a concrete fix for each. Use when the user asks what friction agents hit,
  what has been annoying or getting in the way, what tooling should be fixed,
  what papercuts have piled up, or asks to review, triage or prune the
  papercuts log.
argument-hint: "[stats] [--since=7d] [--project=X] [--agent=A] [--category=Y] [--tool=Z] [--fixable=yes]"
allowed-tools: [Bash, Read, Edit, Write]
---

# papercuts: turn the friction log into a fix list

This is the read side of the `papercut` CLI. Agents append one line per friction event;
this skill clusters those lines and says what to change.

**The deliverable is the fix list, not the report.** "gh came up 6 times" is half the job.
Naming the file to edit and what to change in it is the whole job.

## Data

- Log: the `log:` path from `papercut --where`, one JSON object per line:
  `ts, session_id, agent, project, cwd, git_branch, category, tool, text, fixable`.
  - `agent`: claude | codex | grok | unknown. Friction that hit several agents is one root
    cause; say which agents it hit.
  - `category`: tooling | env | docs | shell | test | codebase | other.
  - `fixable`: `yes` (could have been fixed, wasn't), `no` (not ours), `fixed` (already fixed,
    logged so it still counts).
  - `tool`: the clustering key. It may be empty; then cluster by text similarity.
- Ledger: the `ledger:` path from `papercut --where`, one decision per line:
  `{ts, tool, match, status, reason, ref, fixable?}` where status is fixed | wontfix | ticketed.
  - A decision covers an entry when every selector it sets matches: `tool` exactly, `match` as a
    case-insensitive regex on the text, `fixable` exactly. `fixable` may be the only selector.
  - A decision is a point in time. Entries at or before its `ts` are resolved; later ones are signal.

## Arguments

| Argument | Meaning |
|---|---|
| `stats` | Stats mode (see the end). |
| `--since=7d` or `--since=YYYY-MM-DD` | Time window. Default: all time. |
| `--project=X` | Substring match on `project` or `cwd`. |
| `--agent=A` | Exact match on `agent`. |
| `--category=Y` | Exact match on `category`. |
| `--tool=Z` | Substring match on `tool`. |
| `--fixable=yes` | Exact match on `fixable`. |

A bare invocation triages everything, all time.

## Procedure

### 1. Load

```bash
papercut --count                                 # total entries
ANN=$(mktemp); papercut --annotate > "$ANN"      # every entry as JSON, damaged lines skipped
```

Work from `$ANN`, not the raw log file: `papercut --annotate` skips any damaged line
instead of stopping at it, and adds the triage state used in step 2.

If the log is missing or empty, say so plainly, mention that agents log with
`papercut '...'` as described in `AGENT-INSTRUCTIONS.md` (https://github.com/nkrebs13/papercut), and stop.
Never invent entries.

Filter examples. The window start must be portable, so try BSD `date`, then GNU:

```bash
# window start: macOS (BSD date) first, GNU date as the fallback
SINCE=$(date -v-7d +%Y-%m-%dT00:00:00 2>/dev/null || date -d '7 days ago' +%Y-%m-%dT00:00:00)

# time window (a text comparison of timestamps: approximate, fine for a day-level window)
jq -c --arg s "$SINCE" 'select(.ts >= $s)' "$ANN"

# category + fixable
jq -c 'select(.category == "tooling" and .fixable == "yes")' "$ANN"

# group counts by tool
jq -r '.tool' "$ANN" | sort | uniq -c | sort -rn
```

### 2. Apply the ledger

Never re-implement the matching. `papercut --annotate` is the single source of truth. It emits
every log entry with a `.triage` field, either null or an object with `state`, `status`,
`decision_ts`, `tool`, `match`, `fixable`, `reason`, `ref`. Apply the same window and
`--project/--agent/--category/--tool/--fixable` filters to its output as in step 1.

| `.triage.state` | Where it goes in the report |
|---|---|
| null | Normal clustering. |
| `resolved` | Only the one-line Resolved tail. |
| `regressed` | "Fixed but still biting", at the TOP. |
| `after_wontfix` | Back into Watch only at 5 or more hits for that decision; otherwise just counted. |
| `after_ticketed` | Normal clustering, annotated with the ref. |

Recipes over `$ANN` from step 1:

```bash
# state summary; the counts add up to the total from `papercut --count`
jq -rs 'group_by(.triage.state // "untriaged") | map("\(.[0].triage.state // "untriaged")\t\(length)")[]' "$ANN"

# step 3 input: untriaged entries plus after_ticketed
jq -c 'select(.triage == null or .triage.state == "after_ticketed")' "$ANN"

# regressions, grouped per decision
jq -rs '[.[] | select(.triage.state == "regressed")]
  | group_by([.triage.decision_ts, .triage.tool, .triage.match])
  | map({tool: .[0].triage.tool, ref: .[0].triage.ref, reason: .[0].triage.reason,
         since: length, newest: (max_by(.ts) | .text)})[]
  | "\(.tool)\t\(.ref)\t\(.since) hits since\t\(.reason)\t\(.newest)"' "$ANN"

# wontfix decisions re-surfacing at 5 or more hits
jq -rs '[.[] | select(.triage.state == "after_wontfix")]
  | group_by([.triage.decision_ts, .triage.tool, .triage.match])
  | map(select(length >= 5))[]
  | "\(.[0].triage.tool // "-")\t\(.[0].triage.match // "-")\t\(length)\t\(.[0].triage.reason)"' "$ANN"

# resolved tail: entry count and cluster (decision) count
jq -s '[.[] | select(.triage.state == "resolved")] as $r
  | {entries: ($r | length),
     clusters: ($r | map(.triage | [.decision_ts, .tool, .match, .fixable]) | unique | length)}' "$ANN"
```

`papercut --triage` lists the ledger itself (matches per decision, hits since), for eyeballing.

### 3. Cluster

- Group by `tool`.
- Within a group, cluster by root cause by reading the texts. Two entries about the same missing
  flag are ONE papercut with count 2. An auth failure for the same tool is a separate cluster.
- Entries with an empty tool cluster by text similarity, or fold into an obvious match.
- Rank by cluster size, then by most recent.
- Use judgment: never report near-identical lines as separate findings.

### 4. Report

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

Section order:

1. **🔁 Fixed but still biting** (first). Give the reason, ref, hits since, and newest text.
   Say whether the fix was incomplete, didn't reach the path agents actually use, or the
   selector was too broad.
2. **🔧 Fix now.** Count of 3 or more, fixable yes or no.
3. **👀 Watch.** Count 2, or 1 with high severity, plus wontfix decisions at 5 or more hits
   since, with the original reason.
4. **✅ Already fixed.** `fixable=fixed` clusters that no decision covers yet. Offer one decision
   selected by field:
   ```bash
   papercut --resolve --dry-run --status fixed --fixable fixed --reason 'self-reported fixed at log time'
   ```
   then the same without `--dry-run`. It is a point in time, so re-run it periodically.
5. **📋 Not ours.** `fixable=no` with no local fix path. Offer a wontfix decision whose reason
   names where the workaround is written down.
6. **Tail:** `Resolved: N clusters (M entries)`. Keep it scannable and summarize one-offs as a count.

### 5. Offer to act

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
| `ticketed` | Tracked elsewhere, with the ref in `--ref`. Stays visible, annotated. |

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
ANN=$(mktemp); papercut --annotate > "$ANN"
jq -s 'length' "$ANN"                                   # total
for f in category project agent fixable; do            # breakdowns
  echo "-- $f"; jq -r --arg f "$f" '.[$f]' "$ANN" | sort | uniq -c | sort -rn
done

# per-day trend, last 14 days (portable day list)
DAYS=$(for i in $(seq 13 -1 0); do date -v-${i}d +%F 2>/dev/null || date -d "$i days ago" +%F; done)
jq -rs --arg days "$DAYS" '($days | split("\n")) as $d
  | (map(.ts[0:10]) | group_by(.) | map({(.[0]): length}) | add // {}) as $c
  | $d[] | "\(.) \($c[.] // 0)"' "$ANN"
```

Logging rate per agent: papercuts per session over the last 30 days. Session counts come from
counting each agent's session files; nothing reads their contents.

```bash
claude=$(find ~/.claude/projects -mindepth 2 -maxdepth 2 -name '*.jsonl' -mtime -30 2>/dev/null | wc -l | tr -d " ")
codex=$(find ~/.codex/sessions -name 'rollout-*.jsonl' -mtime -30 2>/dev/null | wc -l | tr -d " ")
grok=$(find ~/.grok/sessions -mindepth 2 -maxdepth 2 -type d -mtime -30 2>/dev/null | wc -l | tr -d " ")   # sessions/<cwd>/<id>

# rolling 30x24h cutoff, the same window as find -mtime -30
S30=$(date -v-30d -Iseconds 2>/dev/null || date -d '30 days ago' -Iseconds)
for a in claude codex grok; do
  cuts=$(jq -s --arg a "$a" --arg s "$S30" '[.[] | select(.agent == $a and .ts >= $s)] | length' "$ANN")
  case "$a" in claude) sessions=$claude ;; codex) sessions=$codex ;; grok) sessions=$grok ;; esac
  if [ "$sessions" -gt 0 ]; then
    echo "$a: $cuts papercuts / $sessions sessions = $(awk -v c="$cuts" -v n="$sessions" 'BEGIN { printf "%.2f", c / n }') per session"
  else
    echo "$a: $cuts papercuts, no sessions found"
  fi
done
echo "unknown: $(jq -s --arg s "$S30" '[.[] | select((.agent // "unknown") == "unknown" and .ts >= $s)] | length' "$ANN") papercuts"
```

Reading it:

- A rate near zero for one agent means its instructions aren't reaching it or aren't firing.
  Check its global instructions: `~/.claude/rules/papercuts.md` for Claude Code (and Grok, unless
  Grok has its own copy in `~/.grok/AGENTS.md`), `~/.codex/AGENTS.md` for Codex. Run
  `install.sh --check` in the papercut repo, and check the Codex sandbox's writable roots.
- Many `unknown` entries usually means Grok logged without `--agent grok`.
