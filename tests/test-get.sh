#!/usr/bin/env bash
# get.sh in a temp HOME, installing from a tarball of this working tree.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'command rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.claude"
unset PAPERCUT_LOG PAPERCUT_TRIAGE XDG_STATE_HOME PAPERCUT_VERSION
DEST="$HOME/.local/share/papercut"

pass=0; fail=0
check() { if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi; }

# A release-shaped tarball: one top-level folder, like GitHub's archives.
mkdir -p "$T/pkg/papercut-test"
(cd "$HERE" && tar -cf - --exclude .git .) | tar -xf - -C "$T/pkg/papercut-test"
tar -czf "$T/papercut.tar.gz" -C "$T/pkg" papercut-test
export PAPERCUT_TARBALL="$T/papercut.tar.gz"

out=$(bash "$HERE/get.sh" --agents claude 2>&1); check "fresh install exits 0" 0 "$?"
check "installs into ~/.local/share/papercut" yes "$([[ -x "$DEST/bin/papercut" && -f "$DEST/.papercut-get" ]] && echo yes)"
check "the CLI link points there" "$DEST/bin/papercut" "$(readlink "$HOME/.local/bin/papercut")"
check "the installed CLI runs" 1 "$("$HOME/.local/bin/papercut" --version | grep -c '^papercut ')"
check "installer arguments pass through" "yes no" \
  "$([[ -L "$HOME/.claude/rules/papercuts.md" ]] && echo yes || echo no) $([[ -e "$HOME/.codex" ]] && echo yes || echo no)"

echo stale > "$DEST/stale-file"
bash "$HERE/get.sh" --agents claude >/dev/null 2>&1; check "re-running updates in place" 0 "$?"
check "...replacing the old copy" no "$([[ -e "$DEST/stale-file" ]] && echo yes || echo no)"
check "...and the links still resolve" yes "$([[ -e "$HOME/.local/bin/papercut" && -e "$HOME/.claude/rules/papercuts.md" ]] && echo yes)"
check "...with nothing left over" 0 "$(find "$HOME/.local/share" -maxdepth 1 -name 'papercut.*' | wc -l | tr -d ' ')"

bash "$HERE/get.sh" --agents claude --check >/dev/null 2>&1; check "--check passes through (exit 0)" 0 "$?"

printf 'not a tarball' > "$T/bad.tar.gz"
PAPERCUT_TARBALL="$T/bad.tar.gz" bash "$HERE/get.sh" >/dev/null 2>&1; check "a bad download exits 1" 1 "$?"
check "...and leaves the install intact" yes "$([[ -x "$DEST/bin/papercut" && -e "$HOME/.local/bin/papercut" ]] && echo yes)"

mkdir -p "$T/notpc/x"; tar -czf "$T/notpc.tar.gz" -C "$T/notpc" x
PAPERCUT_TARBALL="$T/notpc.tar.gz" bash "$HERE/get.sh" >/dev/null 2>&1; check "a tarball that isn't papercut exits 1" 1 "$?"

"$DEST/install.sh" --uninstall >/dev/null && command rm -rf "$DEST"
check "uninstall + rm leaves no links" 0 "$(find "$HOME" -type l | wc -l | tr -d ' ')"

mkdir -p "$DEST"; echo mine > "$DEST/file"
out=$(bash "$HERE/get.sh" 2>&1); check "a folder it didn't create is refused" 1 "$?"
check "...untouched" mine "$(cat "$DEST/file")"
check "...with a reason" 1 "$(grep -c "wasn't created by get.sh" <<<"$out")"
command rm -rf "$DEST"

nojq="$T/nojq"; mkdir -p "$nojq"
for b in bash env curl tar python3 mktemp dirname; do p=$(command -v "$b") && ln -sf "$p" "$nojq/$b"; done
out=$(PATH="$nojq" "$nojq/bash" "$HERE/get.sh" 2>&1); check "a missing dependency exits 1" 1 "$?"
check "...naming it" 1 "$(grep -c 'jq is required' <<<"$out")"

echo; echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
