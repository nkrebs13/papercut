#!/usr/bin/env bash
# Contract tests for the papercut CLI: flags, exit codes, the JSONL schema, agent
# detection, the triage ledger. Black-box only; runs in a temp HOME and never
# touches the real log.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PC="${PAPERCUT_BIN:-$HERE/bin/papercut}"
T="$(mktemp -d)"; trap 'command rm -rf "$T"' EXIT
export HOME="$T/home"
mkdir -p "$HOME"
LOG="$T/log.jsonl"; LEDGER="$T/triage.jsonl"
unset XDG_STATE_HOME
export PAPERCUT_LOG="$LOG" PAPERCUT_TRIAGE="$LEDGER"

pass=0; fail=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
reset() { command rm -f "$LOG" "$LEDGER"; }
lines() { [[ -f "$1" ]] && grep -c . "$1" || echo 0; }
last() { tail -n 1 "$LOG" | jq -r "$1"; }

# Run papercut with every agent marker cleared; extra NAME=value pairs come first.
pc() {
  local vars=()
  while [[ $# -gt 0 && "$1" == *=* && "$1" != -* ]]; do vars+=("$1"); shift; done
  env -u CODEX_THREAD_ID -u CODEX_SESSION_ID -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID \
      -u PAPERCUT_AGENT ${vars[@]+"${vars[@]}"} "$PC" "$@"
}
e() { # ts tool text fixable [session_id]
  jq -nc --arg ts "$1" --arg tool "$2" --arg text "$3" --arg f "$4" --arg s "${5:-unknown}" \
    '{ts:$ts,session_id:$s,agent:"claude",project:"-p",cwd:"/p",git_branch:"",category:"tooling",tool:$tool,text:$text,fixable:$f}' >> "$LOG"
}
d() { # raw decision JSON
  echo "$1" >> "$LEDGER"
}

echo '# write mode'
reset
out=$(pc --tool rg --category shell 'what -> broke -> fix' 2>&1); rc=$?
check "write exits 0" 0 "$rc"
check "write is silent" "" "$out"
check "write appends one line" 1 "$(lines "$LOG")"
check "schema field order" '["ts","session_id","agent","project","cwd","git_branch","category","tool","text","fixable"]' \
  "$(last 'keys_unsorted | tojson')"
check "category stored" shell "$(last .category)"
check "tool stored" rg "$(last .tool)"
check "fixable default" no "$(last .fixable)"
check "ts is ISO-8601 with offset" 1 \
  "$(last .ts | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)$')"

reset; pc 'plain text'
check "category default" tooling "$(last .category)"
check "tool default empty" "" "$(last .tool)"

reset; pc --fixed 'x'
check "--fixed" fixed "$(last .fixable)"
reset; pc --fixable yes 'x'
check "--fixable yes" yes "$(last .fixable)"

reset; pc --tool t one two three
check "positional words join with spaces" "one two three" "$(last .text)"
reset; pc first --tool t second
check "text may surround flags" "first second" "$(last .text)"
reset; pc -- --looks-like-a-flag text
check "-- ends flag parsing" "--looks-like-a-flag text" "$(last .text)"
reset; pc "$(printf 'line one\nline two\r\nthree')"
check "newlines collapse to one space" "line one line two three" "$(last .text)"
check "still one JSONL line" 1 "$(lines "$LOG")"

reset
pc --tool t - <<'EOF'
it's `rg` and $HOME, verbatim
EOF
# shellcheck disable=SC2016 # the literal $HOME and backticks are the point
check "stdin text verbatim" 'it'"'"'s `rg` and $HOME, verbatim' "$(last .text)"
reset; printf 'tail' | pc --tool t head -
check "stdin joins positional text" "head tail" "$(last .text)"

for c in tooling env docs shell test codebase other; do
  reset; pc --category "$c" x
  check "category $c accepted" "$c" "$(last .category)"
done

echo '# write-mode errors (exit 2, log untouched)'
reset
err() { # name args...
  local name="$1"; shift
  pc "$@" >/dev/null 2>&1 </dev/null; local rc=$?
  check "$name exits 2" 2 "$rc"
  check "$name writes nothing" 0 "$(lines "$LOG")"
}
err "no text"           --tool rg
err "blank text"        '   '
err "bad category"      --category nope x
err "bad fixable"       --fixable maybe x
err "unknown flag"      --bogus x
err "--tool w/o value"  --tool
err "--category w/o value" --category
err "--agent w/o value" --agent
out=$(pc --tool rg 2>&1 </dev/null)
check "no-text error names the problem" 1 "$(echo "$out" | grep -ci 'no .*text')"

echo '# agent + session detection'
reset; pc CODEX_THREAD_ID=th1 CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=cc1 x
check "codex wins over inherited claude" "codex th1" "$(last '"\(.agent) \(.session_id)"')"
reset; pc CODEX_SESSION_ID=cs1 x
check "codex via CODEX_SESSION_ID" "codex cs1" "$(last '"\(.agent) \(.session_id)"')"
reset; pc CODEX_THREAD_ID=th1 CODEX_SESSION_ID=cs1 x
check "CODEX_THREAD_ID preferred" "codex th1" "$(last '"\(.agent) \(.session_id)"')"
reset; pc CLAUDECODE=1 x
check "claude without session id" "claude unknown" "$(last '"\(.agent) \(.session_id)"')"
reset; pc CLAUDE_CODE_SESSION_ID=cc1 x
check "claude session id" "claude cc1" "$(last '"\(.agent) \(.session_id)"')"
reset; pc x
check "no markers" "unknown unknown" "$(last '"\(.agent) \(.session_id)"')"
reset; pc PAPERCUT_AGENT=bot CLAUDE_CODE_SESSION_ID=cc1 x
check "PAPERCUT_AGENT overrides agent only" "bot cc1" "$(last '"\(.agent) \(.session_id)"')"
reset; pc PAPERCUT_AGENT=bot --agent grok x
check "--agent beats PAPERCUT_AGENT" grok "$(last .agent)"

echo '# context capture'
dir="$T/odd dir.v2"; mkdir -p "$dir"
reset; (cd "$dir" && pc x)
check "cwd is \$PWD" "$dir" "$(last .cwd)"
check "project slug: non-alnum -> -" "$(printf %s "$dir" | tr -c 'a-zA-Z0-9' '-')" "$(last .project)"
check "no git -> empty branch" "" "$(last .git_branch)"
repo="$T/repo"; git init -q "$repo"; git -C "$repo" checkout -q -b feat/x
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
reset; (cd "$repo" && pc x)
check "git branch captured" feat/x "$(last .git_branch)"

echo '# --count'
reset
out=$(pc --count)
check "--count with no log" $'total: 0\nthis session: 0' "$out"
e 2026-01-01T00:00:00-07:00 a x no s1
e 2026-01-01T00:00:01-07:00 a y no s1
e 2026-01-01T00:00:02-07:00 a z no s2
check "--count by session" $'total: 3\nthis session: 2' "$(pc CLAUDE_CODE_SESSION_ID=s1 --count)"
check "--count unknown session" $'total: 3\nthis session: 0' "$(pc --count)"

echo '# --tail'
reset
check "--tail with no log" "no papercuts logged yet" "$(pc --tail)"
jq -nc '{ts:"2026-01-01T00:00:00-07:00",session_id:"s",agent:"codex",project:"p",cwd:"/",git_branch:"",category:"shell",tool:"rg",text:"one",fixable:"yes"}' >> "$LOG"
jq -nc '{ts:"2026-01-02T00:00:00-07:00",session_id:"s",agent:"claude",project:"p",cwd:"/",git_branch:"",category:"docs",tool:"",text:"two",fixable:"no"}' >> "$LOG"
check "--tail format" $'2026-01-01T00:00:00-07:00  codex  [shell/rg]  fixable=yes\n  one\n\n2026-01-02T00:00:00-07:00  claude  [docs]  fixable=no\n  two' "$(pc --tail)"
check "--tail N" $'2026-01-02T00:00:00-07:00  claude  [docs]  fixable=no\n  two' "$(pc --tail 1)"

# ESC and BEL are dropped, so the OSC sequence prints as inert text.
check "--tail strips control characters" '  ]0;title' \
  "$(jq -nc '{ts:"t",agent:"a",category:"c",tool:"",text:"\u001b]0;title\u0007",fixable:"no"}' > "$LOG"; pc --tail 1 | sed -n 2p)"
check "the log keeps the text verbatim" 1 "$(grep -c 'u001b' "$LOG")"

echo '# --help'
command rm -rf "$T/fresh"
pc HOME="$T/fresh" --help >/dev/null
check "--help creates no state dirs" no "$([[ -e "$T/fresh" ]] && echo yes || echo no)"
out=$(pc --help); rc=$?
check "--help exits 0" 0 "$rc"
check "--help documents --resolve" 1 "$([[ "$out" == *--resolve* ]] && echo 1 || echo 0)"
check "-h same as --help" "$out" "$(pc -h)"
check "--version" 'papercut 0.1.0' "$(pc --version)"

echo '# --resolve validation (exit 2, ledger untouched)'
reset
e 2026-01-01T00:00:00-07:00 rg 'Glob broke' no
e 2026-01-01T00:00:01-07:00 rgx 'other' no
rerr() { # name args...
  local name="$1"; shift
  pc --resolve "$@" >/dev/null 2>&1; local rc=$?
  check "$name exits 2" 2 "$rc"
  check "$name writes nothing" 0 "$(lines "$LEDGER")"
}
rerr "missing --status"   --tool rg --reason r
rerr "invalid --status"   --status 'done' --tool rg --reason r
rerr "no selector"        --status fixed --reason r
rerr "fixed w/o reason"   --status fixed --tool rg
rerr "wontfix w/o reason" --status wontfix --tool rg
rerr "blank reason"       --status fixed --tool rg --reason '  '
rerr "bad regex"          --status fixed --match '(' --reason r
rerr "unknown flag"       --status fixed --tool rg --reason r --nope
rerr "stray positional"   --status fixed --tool rg 'oops'
rerr "zero matches"       --status fixed --tool nope --reason r
rerr "--status w/o value" --status

echo '# --resolve matching + writing'
cnt() { pc --resolve --dry-run --status fixed --reason r "$@" 2>&1 | sed -n 's/.*matches \([0-9]*\) log entries.*/\1/p'; }
check "tool is exact, not substring" 1 "$(cnt --tool rg)"
check "match is case-insensitive regex" 1 "$(cnt --match 'glob b.oke')"
check "tool AND match" 0 "$(cnt --tool rgx --match glob)"
out=$(pc --resolve --dry-run --status fixed --tool rg --reason r 2>&1); rc=$?
check "dry-run exits 0" 0 "$rc"
check "dry-run writes nothing" 0 "$(lines "$LEDGER")"
pc --resolve --status ticketed --tool rg >/dev/null 2>&1
check "ticketed needs no reason" 1 "$(lines "$LEDGER")"
reset
e 2026-01-01T00:00:00-07:00 rg 'Glob broke' no
pc --resolve --status fixed --tool rg --reason "$(printf 'a\nb')" --ref PR#12 >/dev/null 2>&1
check "decision field order (no fixable)" '["ts","tool","match","status","reason","ref"]' \
  "$(jq -c 'keys_unsorted' "$LEDGER")"
check "decision values" '{"tool":"rg","match":null,"status":"fixed","reason":"a b","ref":"PR#12"}' \
  "$(jq -c 'del(.ts)' "$LEDGER")"
reset
e 2026-01-01T00:00:00-07:00 rg 'x' fixed
pc --resolve --status fixed --fixable fixed --reason r >/dev/null 2>&1
check "decision with fixable appends the field last" '["ts","tool","match","status","reason","ref","fixable"]' \
  "$(jq -c 'keys_unsorted' "$LEDGER")"

echo '# --resolve zero-match hint'
reset
jq -nc '{ts:"2026-01-01T00:00:00-07:00",tool:"evil\u001b]0;x\u0007tool",text:"t",fixable:"no"}' > "$LOG"
hint=$(pc --resolve --status fixed --tool evil --reason r 2>&1)
check "zero-match hint lists the similar tool" 1 "$(grep -cF '1 evil]0;xtool' <<<"$hint")"
check "zero-match hint has no ESC byte" 0 "$(grep -c $'\x1b' <<<"$hint")"

echo '# --triage'
reset
out=$(pc --triage); rc=$?
check "--triage with no ledger exits 0" 0 "$rc"
check "--triage with no ledger says so" 1 "$(echo "$out" | grep -c '^no triage decisions yet')"
e 2026-01-01T00:00:00-07:00 rg 'before' no
e 2026-03-01T00:00:00-07:00 rg 'after' no
d '{"ts":"2026-02-01T00:00:00-07:00","tool":"rg","match":null,"status":"fixed","reason":"why","ref":"PR#1"}'
out=$(pc --triage)
check "--triage counts" 1 "$(echo "$out" | grep -c 'matches: 2  (after decision: 1)')"
check "--triage flags regressions" 1 "$(echo "$out" | grep -c 'FIXED BUT STILL BITING')"
check "--triage shows reason" 1 "$(echo "$out" | grep -c 'reason: why')"
check "--triage shows ref" 1 "$(echo "$out" | grep -c 'ref: PR#1')"
reset
for i in 1 2 3 4 5; do e "2026-03-0${i}T00:00:00-07:00" docker "hit $i" no; done
d '{"ts":"2026-02-01T00:00:00-07:00","tool":"docker","match":null,"status":"wontfix","reason":"upstream","ref":null}'
check "--triage flags re-surfacing wontfix at 5" 1 "$(pc --triage | grep -c 'wontfix re-surfacing')"

echo '# --annotate'
reset
check "--annotate with no log is empty" "" "$(pc --annotate)"
st() { pc --annotate | jq -r --arg x "$1" 'select(.text == $x) | .triage.state // "untriaged"'; }
e 2026-01-01T00:00:00-07:00 rg 'old rg' no
e 2026-03-01T00:00:00-07:00 rg 'new rg' no
e 2026-03-01T00:00:00-07:00 gh 'new gh' no
e 2026-03-01T00:00:00-07:00 fd 'new fd' no
e 2026-03-01T00:00:00-07:00 zz 'untouched' no
d '{"ts":"2026-02-01T00:00:00-07:00","tool":"rg","match":null,"status":"fixed","reason":"r","ref":null}'
d '{"ts":"2026-02-01T00:00:00-07:00","tool":"gh","match":null,"status":"ticketed","reason":null,"ref":"T-1"}'
d '{"ts":"2026-02-01T00:00:00-07:00","tool":"fd","match":null,"status":"wontfix","reason":"r","ref":null}'
check "annotate keeps every entry" 5 "$(pc --annotate | grep -c .)"
check "resolved" resolved "$(st 'old rg')"
check "regressed" regressed "$(st 'new rg')"
check "after_ticketed" after_ticketed "$(st 'new gh')"
check "after_wontfix" after_wontfix "$(st 'new fd')"
check "untriaged is null" untriaged "$(st 'untouched')"
check "triage object fields" '["state","status","decision_ts","tool","match","fixable","reason","ref"]' \
  "$(pc --annotate | jq -c 'select(.text == "new gh") | .triage | keys_unsorted')"
check "entry fields preserved, triage appended" \
  '["ts","session_id","agent","project","cwd","git_branch","category","tool","text","fixable","triage"]' \
  "$(pc --annotate | jq -c 'select(.text == "untouched") | keys_unsorted')"
d '{"ts":"2026-04-01T00:00:00-07:00","tool":"rg","match":null,"status":"wontfix","reason":"later","ref":null}'
check "a later covering decision beats regressed" resolved "$(st 'new rg')"
check "latest covering decision is reported" wontfix \
  "$(pc --annotate | jq -r 'select(.text == "new rg") | .triage.status')"
reset
# 17:30Z is BEFORE 10:00-08:00 (= 18:00Z); a plain string compare gets this wrong.
e 2026-03-01T17:30:00+00:00 rg 'offset entry' no
d '{"ts":"2026-03-01T10:00:00-08:00","tool":"rg","match":null,"status":"fixed","reason":"r","ref":null}'
check "timestamps compare by instant, not string" resolved "$(st 'offset entry')"
reset
e 2026-01-01T00:00:00-07:00 rg 'a sprint gap' no
e 2026-01-01T00:00:00-07:00 rg 'auth failure' no
d '{"ts":"2026-02-01T00:00:00-07:00","tool":"rg","match":"SPRINT","status":"fixed","reason":"r","ref":null}'
check "match selector scopes the decision" "resolved untriaged" "$(st 'a sprint gap') $(st 'auth failure')"

echo '# --resolve --fixable'
reset
e 2026-01-01T00:00:00-07:00 rg 'glob broke' fixed
e 2026-01-01T00:00:01-07:00 rg 'glob again' no
e 2026-01-01T00:00:02-07:00 gh 'gh thing' fixed
e 2026-01-01T00:00:03-07:00 gh 'gh other' yes
check "--fixable alone selects" 2 "$(cnt --fixable fixed)"
check "--fixable AND --tool" 1 "$(cnt --fixable fixed --tool rg)"
check "--fixable AND --match" 1 "$(cnt --fixable fixed --match 'gh')"
rerr "invalid --fixable" --status fixed --reason r --fixable bogus
rerr "empty --fixable" --status fixed --reason r --tool rg --fixable ''
rerr "--fixable no + --tool gh matches none" --status fixed --reason r --fixable no --tool gh
d '{"ts":"2026-02-01T00:00:00-07:00","tool":"rg","match":null,"status":"fixed","reason":"r","ref":null}'
check "a decision without a fixable field still covers by tool" "resolved resolved untriaged" \
  "$(st 'glob broke') $(st 'glob again') $(st 'gh thing')"
pc --resolve --status fixed --fixable fixed --reason 'self-reported' >/dev/null 2>&1
check "--fixable-only decision recorded" 1 "$(jq -c 'select(.fixable == "fixed")' "$LEDGER" | grep -c .)"
check "...covers the fixed entry" resolved "$(st 'gh thing')"
check "...not the yes entry" untriaged "$(st 'gh other')"
e 2099-01-01T00:00:00-07:00 gh 'later fixed' fixed
check "a fixed entry after the decision is a regression" regressed "$(st 'later fixed')"
check "--triage shows fixable=" 1 "$(pc --triage | grep -c 'fixable=fixed')"

echo '# latest decision wins'
reset
e 2026-03-01T00:00:00-07:00 rg 'came back' no
d '{"ts":"2026-01-01T00:00:00-07:00","tool":"rg","match":null,"status":"fixed","reason":"r","ref":null}'
d '{"ts":"2026-02-01T00:00:00-07:00","tool":"rg","match":null,"status":"wontfix","reason":"later call","ref":null}'
check "a newer wontfix supersedes an older fixed" "after_wontfix later call" \
  "$(pc --annotate | jq -r '"\(.triage.state) \(.triage.reason)"')"

echo '# damaged lines'
reset
e 2026-01-01T00:00:00-07:00 rg 'first' no
printf '{"ts":"2026-01-01T00:00:01-07:00","tool":"rg","te\n' >> "$LOG"
e 2026-01-01T00:00:02-07:00 rg 'after the damage' no
d '{"ts":"2026-02-01T00:00:00-07:00","tool":"rg","match":null,"status":"fixed","reason":"r","ref":null}'
printf 'not json\n' >> "$LEDGER"
check "--annotate skips the bad line, keeps the rest" 2 "$(pc --annotate | grep -c .)"
check "--tail skips it too" 1 "$(pc --tail | grep -c 'after the damage')"
check "--count reports it" "total: 2
this session: 0
skipped: 1 lines that aren't valid JSON" "$(pc --count)"
check "--resolve still counts the good entries" 2 "$(cnt --tool rg)"
check "--triage skips the bad ledger line" 1 "$(pc --triage 2>&1 | grep -c 'matches: 2')"

echo '# write failures'
reset
mkdir -p "$T/ro"; chmod 555 "$T/ro"
e 2026-01-01T00:00:00-07:00 rg 'x' no
PAPERCUT_TRIAGE="$T/ro/sub/triage.jsonl" pc --resolve --status ticketed --tool rg >/dev/null 2>&1
check "an unwritable ledger exits 1" 1 "$?"
PAPERCUT_LOG="$T/ro/sub/log.jsonl" pc x >/dev/null 2>&1
check "an unwritable log exits 1" 1 "$?"
chmod 755 "$T/ro"

echo '# arguments and paths'
for m in --count --triage --annotate --where --version; do
  pc "$m" extra >/dev/null 2>&1; check "$m rejects extra arguments" 2 "$?"
done
pc --tail 3 extra >/dev/null 2>&1; check "--tail rejects a second argument" 2 "$?"
check "--where shows both paths" "log: $LOG
ledger: $LEDGER" "$(pc --where)"
check "no text: a two-line error, no help dump" 2 "$(pc --tool x 2>&1 </dev/null | grep -c .)"
xh="$T/xdg"; mkdir -p "$xh"
where() { env -u PAPERCUT_LOG -u PAPERCUT_TRIAGE -u XDG_STATE_HOME HOME="$xh" "$@" "$PC" --where | head -1; }
check "default state dir: ~/.local/state/papercut" "log: $xh/.local/state/papercut/papercuts.jsonl" "$(where)"
check "...or XDG_STATE_HOME/papercut" "log: $xh/st/papercut/papercuts.jsonl" "$(where XDG_STATE_HOME="$xh/st")"
env -u PAPERCUT_LOG -u PAPERCUT_TRIAGE -u XDG_STATE_HOME HOME="$T/never" "$PC" --help >/dev/null
check "read modes create no directories" no "$([[ -e "$T/never" ]] && echo yes || echo no)"

echo '# concurrency'
reset
long=$(printf 'x%.0s' $(seq 1 1900))
for i in $(seq 1 60); do pc --tool c "parallel write $i $long" & done; wait
check "60 parallel ~2KB writes -> 60 lines" 60 "$(lines "$LOG")"
check "every line is valid JSON" 60 "$(jq -c -R 'fromjson? // empty' "$LOG" | grep -c .)"
reset; pc "$(printf 'y%.0s' $(seq 1 2500))"
check "text is capped at 2000 characters" 2000 "$(last '.text | length')"

echo '# missing jq'
nojq="$T/nojq"; mkdir -p "$nojq"
for b in bash env mkdir dirname date sed git cat tr awk grep tail head; do
  p=$(command -v "$b") && ln -sf "$p" "$nojq/$b"
done
PATH="$nojq" "$nojq/bash" "$PC" x >/dev/null 2>&1
check "missing jq exits 3" 3 "$?"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
