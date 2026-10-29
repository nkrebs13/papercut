#!/usr/bin/env bash
# install.sh round trip in a temp HOME: install, check, idempotent re-run,
# uninstall. Pre-existing Codex config must come back byte for byte.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'command rm -rf "$T"' EXIT
export HOME="$T"
unset PAPERCUT_LOG PAPERCUT_TRIAGE XDG_STATE_HOME   # never point at a real log
mkdir -p "$HOME/.codex" "$HOME/.claude"
printf 'model = "x"\n\n[sandbox_workspace_write]\nwritable_roots = ["/tmp/a"]\nnetwork_access = true\n' > "$HOME/.codex/config.toml"
printf '# My rules\n\nBe nice.\n' > "$HOME/.codex/AGENTS.md"
cp "$HOME/.codex/config.toml" "$T/config.orig"; cp "$HOME/.codex/AGENTS.md" "$T/agents.orig"
LOG_DIR="$(dirname "$("$HERE/bin/papercut" --where | sed -n 's/^log: //p')")"

pass=0; fail=0
HAVE_TOML=1; python3 -c 'import tomllib' 2>/dev/null || HAVE_TOML=0
check() { if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi; }
has() { [[ -L "$HOME/$1" || -f "$HOME/$1" ]] && echo yes || echo no; }
blocks() { cat "$1" 2>/dev/null | grep -c 'papercut:begin'; }
state() { "$HERE/install.sh" --check | awk '/^  /{print $1}' | sort | uniq -c | tr -s ' ' | tr '\n' ';'; }

if [[ "$HAVE_TOML" -eq 0 ]]; then
  # Without python3 >= 3.11 the Codex steps are skipped; the rest must still work.
  out=$("$HERE/install.sh" 2>&1); check "without tomllib: install exits 1 (one step skipped)" 1 "$?"
  check "...says which step and why" 1 "$(grep -c 'writable_roots edit needs python3 >= 3.11' <<<"$out")"
  check "...still installs the Codex instructions" 1 "$(blocks "$HOME/.codex/AGENTS.md")"
  check "CLI symlink" "$HERE/bin/papercut" "$(readlink "$HOME/.local/bin/papercut")"
  check "Codex config untouched" same "$(cmp -s "$T/config.orig" "$HOME/.codex/config.toml" && echo same)"
  echo; echo "$pass passed, $fail failed (python3 < 3.11: Codex checks skipped)"
  [[ "$fail" -eq 0 ]]; exit
fi

"$HERE/install.sh" >/dev/null; check "install exits 0" 0 "$?"
check "check: all ok" " 6 ok;" "$(state)"
check "re-run changes nothing" 6 "$("$HERE/install.sh" | grep -c '^  ok ')"
check "CLI symlink" "$HERE/bin/papercut" "$(readlink "$HOME/.local/bin/papercut")"
check "rules symlink" "$HERE/AGENT-INSTRUCTIONS.md" "$(readlink "$HOME/.claude/rules/papercuts.md")"
check "skill symlinks" "$HERE/skills/papercuts $HERE/skills/papercuts" \
  "$(readlink "$HOME/.claude/skills/papercuts") $(readlink "$HOME/.codex/skills/papercuts")"
check "log dir created" yes "$([[ -d "$LOG_DIR" ]] && echo yes)"
check "writable_roots extended" "[\"/tmp/a\", \"$LOG_DIR\"]" \
  "$(python3 -c 'import tomllib,json,sys; print(json.dumps(tomllib.load(open(sys.argv[1],"rb"))["sandbox_workspace_write"]["writable_roots"]).replace("\",\"","\", \""))' "$HOME/.codex/config.toml")"
check "managed block present once" 1 "$(grep -c '<!-- papercut:begin' "$HOME/.codex/AGENTS.md")"
check "user content kept" 1 "$(grep -c '^Be nice.$' "$HOME/.codex/AGENTS.md")"
check "backups written" 2 "$(find "$HOME/.codex" -maxdepth 1 -name '*.bak-papercut-*' | wc -l | tr -d ' ')"
"$HERE/install.sh" --check >/dev/null; check "--check exits 0" 0 "$?"
"$HERE/install.sh" --bogus >/dev/null 2>&1; check "unknown arg exits 2" 2 "$?"

# A real file where a symlink would go is refused, not clobbered.
command rm "$HOME/.claude/rules/papercuts.md"; echo mine > "$HOME/.claude/rules/papercuts.md"
"$HERE/install.sh" >/dev/null 2>&1; check "real file refused (exit 1)" 1 "$?"
check "real file untouched" mine "$(cat "$HOME/.claude/rules/papercuts.md")"
command rm "$HOME/.claude/rules/papercuts.md"; "$HERE/install.sh" >/dev/null

echo 'log line' > "$LOG_DIR/papercuts.jsonl"
"$HERE/install.sh" --uninstall >/dev/null; check "uninstall exits 0" 0 "$?"
check "config restored byte for byte" same "$(cmp -s "$T/config.orig" "$HOME/.codex/config.toml" && echo same)"
check "AGENTS.md restored byte for byte" same "$(cmp -s "$T/agents.orig" "$HOME/.codex/AGENTS.md" && echo same)"
check "the rules/ and skills/ folders it linked into are removed" no \
  "$([[ -e "$HOME/.claude/rules" || -e "$HOME/.claude/skills" || -e "$HOME/.codex/skills" ]] && echo yes || echo no)"
check "symlinks gone" 0 "$(find "$HOME" -type l | wc -l | tr -d ' ')"
check "log kept" 'log line' "$(cat "$LOG_DIR/papercuts.jsonl")"
check "check after uninstall: nothing ok" 0 "$("$HERE/install.sh" --check | grep -c '^  ok ')"
"$HERE/install.sh" --uninstall >/dev/null; check "second uninstall is a no-op" 0 "$?"

# A foreign symlink at a managed path is left alone by uninstall.
mkdir -p "$HOME/.local/bin"; ln -s /usr/bin/true "$HOME/.local/bin/papercut"
"$HERE/install.sh" --uninstall >/dev/null
check "foreign symlink kept" /usr/bin/true "$(readlink "$HOME/.local/bin/papercut")"

check "foreign symlink: install repoints and says so" 1 \
  "$("$HERE/install.sh" | grep -c "papercut -> $HERE/bin/papercut (was /usr/bin/true)")"
"$HERE/install.sh" --uninstall >/dev/null

# round_trip <name> <config.toml contents> <AGENTS.md contents>: install twice,
# uninstall, and expect both files back byte for byte.
# An optional 4th argument is the expected AGENTS.md when it can't come back
# exactly (a file without a final newline gains one).
round_trip() {
  printf '%s' "$2" > "$HOME/.codex/config.toml"; printf '%s' "$3" > "$HOME/.codex/AGENTS.md"
  cp "$HOME/.codex/config.toml" "$T/c"; printf '%s' "${4-$3}" > "$T/a"
  "$HERE/install.sh" >/dev/null 2>&1 || { check "$1: install" 0 "$?"; return; }
  check "$1: second install is a no-op" 0 "$("$HERE/install.sh" | grep -cE '^  (updated|linked) ')"
  "$HERE/install.sh" --uninstall >/dev/null 2>&1
  check "$1: config.toml restored" same "$(cmp -s "$T/c" "$HOME/.codex/config.toml" && echo same)"
  check "$1: AGENTS.md restored" same "$(cmp -s "$T/a" "$HOME/.codex/AGENTS.md" && echo same)"
}
round_trip "no sandbox table" $'model = "x"\n' $'# Rules\n'
printf '' > "$HOME/.codex/config.toml"; printf '' > "$HOME/.codex/AGENTS.md"
"$HERE/install.sh" >/dev/null; "$HERE/install.sh" --uninstall >/dev/null
check "empty files: uninstall removes what only held papercut" "no no" \
  "$([[ -e "$HOME/.codex/config.toml" ]] && echo yes || echo no) $([[ -e "$HOME/.codex/AGENTS.md" ]] && echo yes || echo no)"
mkdir -p "$HOME/.codex"
round_trip "user formatting kept" $'[sandbox_workspace_write]\nwritable_roots = [ \'/a\' ]\n\n[other]\nk = 1\n' \
  'no trailing newline' $'no trailing newline\n'
round_trip "table without the key" $'[sandbox_workspace_write]\nnetwork_access = true\n' $'\n\n# Rules\n\n\n'
round_trip "user's own empty array" $'[sandbox_workspace_write]\nwritable_roots = []\n' $'x\n'
round_trip "trailing user comment" $'[sandbox_workspace_write]\nwritable_roots = ["/a"] # mine\n' $'x\n'
round_trip "table mid-file" $'a = 1\n\n[sandbox_workspace_write]\nwritable_roots = ["/x"]\n\n[b]\nc = 2\n' $'x\n'

# A root the user already had is not install's to remove.
printf '[sandbox_workspace_write]\nwritable_roots = ["%s"]\n' "$LOG_DIR" > "$HOME/.codex/config.toml"
cp "$HOME/.codex/config.toml" "$T/c"
"$HERE/install.sh" >/dev/null; "$HERE/install.sh" --uninstall >/dev/null
check "pre-existing root kept on uninstall" same "$(cmp -s "$T/c" "$HOME/.codex/config.toml" && echo same)"

# --- agent selection ----------------------------------------------------------
# fresh <dirs...>: a new empty HOME containing the given agent dirs.
fresh() { export HOME="$T/h$((++H))"; mkdir -p "$HOME"; local d; for d in "$@"; do mkdir -p "$HOME/$d"; done; }
H=0

fresh .codex
"$HERE/install.sh" >/dev/null 2>&1
check "default = detected agents: codex only" "yes no no" \
  "$(has .codex/skills/papercuts) $(has .claude/rules/papercuts.md) $(has .grok/AGENTS.md)"
check "CLI installed for any selection" yes "$(has .local/bin/papercut)"

fresh
"$HERE/install.sh" >/dev/null 2>&1; check "no agent dirs and no --agents: exit 2" 2 "$?"
"$HERE/install.sh" --agents claude,bogus >/dev/null 2>&1; check "unknown agent: exit 2" 2 "$?"
"$HERE/install.sh" --agents >/dev/null 2>&1; check "--agents without a list: exit 2" 2 "$?"

fresh .claude .codex .grok
"$HERE/install.sh" --agents codex >/dev/null
check "--agents codex skips claude and grok" "yes no no" \
  "$(has .codex/AGENTS.md) $(has .claude/rules/papercuts.md) $(has .grok/AGENTS.md)"

fresh .claude .codex .grok
"$HERE/install.sh" --agents=grok >/dev/null
check "grok alone gets its own copies" "yes yes no" \
  "$(grep -c '<!-- papercut:begin' "$HOME/.grok/AGENTS.md" | sed 's/1/yes/') $(has .grok/skills/papercuts) $(has .claude/rules/papercuts.md)"
check "grok's skill symlink points here" "$HERE/skills/papercuts" "$(readlink "$HOME/.grok/skills/papercuts")"
out=$("$HERE/install.sh" --agents claude,grok)
check "adding claude drops grok's duplicate block" 0 "$(blocks "$HOME/.grok/AGENTS.md")"
check "adding claude drops grok's duplicate skill" no "$(has .grok/skills/papercuts)"
check "grok reported as covered via compat" 2 "$(grep -c 'via ~/.claude' <<<"$out")"
out=$("$HERE/install.sh" --agents claude,grok --check)
check "claude+grok --check: nothing missing" 0 "$(grep -cE '^  (MISSING|STALE) ' <<<"$out")"
check "claude+grok --check: grok covered via compat" 2 "$(grep -cE '^  ok +(instructions|skill) via ~/.claude' <<<"$out")"

fresh .claude .grok
printf '[compat.claude]\nrules = false\n' > "$HOME/.grok/config.toml"
"$HERE/install.sh" --agents claude,grok >/dev/null
check "compat rules off: grok gets its own block" 1 "$(blocks "$HOME/.grok/AGENTS.md")"
check "compat skills still on: no grok skill copy" no "$(has .grok/skills/papercuts)"

fresh .claude .grok
printf '[compat.claude]\nskills = false\n' > "$HOME/.grok/config.toml"
"$HERE/install.sh" --agents claude,grok >/dev/null
check "compat skills off: grok gets its own skill" yes "$(has .grok/skills/papercuts)"
check "compat skills off: no grok block (rules still on)" 0 "$(cat "$HOME/.grok/AGENTS.md" 2>/dev/null | grep -c 'papercut:begin')"

fresh .claude .grok
"$HERE/install.sh" --agents grok >/dev/null
mkdir -p "$HOME/.claude/rules"; ln -s "$HERE/AGENT-INSTRUCTIONS.md" "$HOME/.claude/rules/papercuts.md"
check "--check flags grok's copy as a duplicate" 1 "$("$HERE/install.sh" --agents grok --check | grep -c 'STALE .*AGENTS.md (duplicate')"
check "only the rules link exists: grok keeps its skill" yes "$("$HERE/install.sh" --agents grok >/dev/null; has .grok/skills/papercuts)"
check "...and its duplicate block is dropped" 0 "$(blocks "$HOME/.grok/AGENTS.md")"

fresh .claude .grok
mkdir -p "$HOME/.claude/rules"; ln -s /nonexistent "$HOME/.claude/rules/papercuts.md"
"$HERE/install.sh" --agents grok >/dev/null 2>&1
check "dangling claude link: grok gets its own block" 1 "$(blocks "$HOME/.grok/AGENTS.md")"

fresh .grok
printf 'not [valid\n' > "$HOME/.grok/config.toml"
mkdir -p "$HOME/.claude"
out=$("$HERE/install.sh" --agents claude,grok 2>&1)
check "unparseable grok config: grok gets its own copies" "1 yes" \
  "$(blocks "$HOME/.grok/AGENTS.md") $(has .grok/skills/papercuts)"
check "unparseable grok config: one note per cell" 2 "$(grep -c "can't parse" <<<"$out")"

fresh .claude
"$HERE/install.sh" --agents , >/dev/null 2>&1; check "--agents , : exit 2" 2 "$?"
"$HERE/install.sh" --agents= --uninstall >/dev/null 2>&1; check "--agents= (empty) --uninstall: exit 2" 2 "$?"

fresh .claude .grok
"$HERE/install.sh" --agents claude,grok >/dev/null
out=$("$HERE/install.sh" --uninstall --agents claude)
check "uninstalling claude alone says how to keep grok" 1 "$(grep -c 'install.sh --agents grok' <<<"$out")"
"$HERE/install.sh" --agents grok >/dev/null
check "...and that command gives grok its own copies" "1 yes" \
  "$(blocks "$HOME/.grok/AGENTS.md") $(has .grok/skills/papercuts)"
"$HERE/install.sh" --agents claude >/dev/null; "$HERE/install.sh" --uninstall --agents claude,codex,grok >/dev/null
check "uninstall naming all three agents removes the CLI" no "$(has .local/bin/papercut)"

fresh .claude .grok
out=$("$HERE/install.sh" --agents claude)
check "claude without grok: note about compat" 1 "$(grep -c 'Grok reads ~/.claude/rules' <<<"$out")"
check "claude without grok: grok config untouched" no "$(has .grok/config.toml)"

fresh .claude .codex .grok
"$HERE/install.sh" >/dev/null
"$HERE/install.sh" --uninstall --agents codex >/dev/null
check "partial uninstall says it keeps the CLI" 1 "$("$HERE/install.sh" --uninstall --agents codex | grep -c 'kept .*other agents still use it')"
check "partial uninstall removes only that agent" "no yes yes" \
  "$(has .codex/skills/papercuts) $(has .claude/rules/papercuts.md) $(has .local/bin/papercut)"
printf '[compat.claude]\nrules = false\n' > "$HOME/.grok/config.toml"
"$HERE/install.sh" --agents grok >/dev/null
check "grok with compat rules off has its own block" 1 "$(blocks "$HOME/.grok/AGENTS.md")"
"$HERE/install.sh" --uninstall >/dev/null
check "full uninstall removes every symlink" 0 "$(find "$HOME" -type l | wc -l | tr -d ' ')"
check "full uninstall removes grok's block" no "$(has .grok/AGENTS.md)"
fresh .codex
"$HERE/install.sh" >/dev/null
check "a codex-only install creates no ~/.claude" no "$([[ -e "$HOME/.claude" ]] && echo yes || echo no)"
check "...so a re-run still selects codex only" 1 "$("$HERE/install.sh" | grep -c 'apply: codex)')"

fresh .codex .grok
printf '[compat.claude]\nrules = false\nskills = false\n' > "$HOME/.grok/config.toml"
cp "$HOME/.grok/config.toml" "$T/g"
"$HERE/install.sh" --agents claude,codex,grok >/dev/null
"$HERE/install.sh" --uninstall >/dev/null
check "install + uninstall leaves only the log dir and the user's file" ".grok/config.toml" \
  "$(cd "$HOME" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ' | sed 's/ $//')"
check "...and no empty directories outside the log dir" "" \
  "$(cd "$HOME" && find . -mindepth 1 -type d -empty | grep -v '^\./\.local' | grep -v '^\./\.\(claude\|codex\|grok\)$' | tr '\n' ' ')"
check "...user's grok config untouched" same "$(cmp -s "$T/g" "$HOME/.grok/config.toml" && echo same)"

fresh .claude .codex .grok
printf '[sandbox_workspace_write]\nwritable_roots = [\n  "/a",\n]\n' > "$HOME/.codex/config.toml"
printf '[compat.claude]\nrules = false\n' > "$HOME/.grok/config.toml"
cp "$HOME/.codex/config.toml" "$T/c"
out=$("$HERE/install.sh" 2>&1); rc=$?
check "an uneditable config.toml: install exits 1" 1 "$rc"
check "...says to add the root by hand" 1 "$(grep -c 'by hand' <<<"$out")"
check "...leaves the config alone" same "$(cmp -s "$T/c" "$HOME/.codex/config.toml" && echo same)"
check "...and still installs the agents after it" 1 "$(blocks "$HOME/.grok/AGENTS.md")"
"$HERE/install.sh" --uninstall >/dev/null 2>&1
check "uninstall with that config still removes grok's block" no "$(has .grok/AGENTS.md)"

fresh .claude .local/bin
"$HERE/install.sh" --agents claude >/dev/null; "$HERE/install.sh" --uninstall --agents claude >/dev/null
check "uninstall with the agents you installed removes the CLI" no "$(has .local/bin/papercut)"
check "...and keeps folders that existed before" "yes yes" \
  "$([[ -d "$HOME/.claude" ]] && echo yes) $([[ -d "$HOME/.local/bin" ]] && echo yes)"

fresh .claude
"$HERE/install.sh" --check >/dev/null; check "--check before install: exit 1" 1 "$?"
"$HERE/install.sh" >/dev/null; "$HERE/install.sh" --check >/dev/null; check "--check after install: exit 0" 0 "$?"

export HOME="$T"

# Unparseable TOML is reported, not mangled.
printf 'not = [valid\n' > "$HOME/.codex/config.toml"; cp "$HOME/.codex/config.toml" "$T/c"
"$HERE/install.sh" >/dev/null 2>&1; check "invalid TOML: install fails" 1 "$?"
check "invalid TOML: file untouched" same "$(cmp -s "$T/c" "$HOME/.codex/config.toml" && echo same)"

echo; echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
