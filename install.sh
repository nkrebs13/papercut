#!/usr/bin/env bash
#
# install.sh — wire the papercut CLI into your coding agents
#
# USAGE
#   ./install.sh [--agents LIST]              install or update
#   ./install.sh [--agents LIST] --check      report only; exit 1 if anything is
#                                             missing or out of date
#   ./install.sh [--agents LIST] --uninstall  undo what install did
#
#   Exit codes: 0 done, 1 error, 2 usage, 3 done but a step was skipped (it
#   says which, and what to do by hand). --check exits 1 if anything is
#   missing or out of date.
#
#   LIST is a comma-separated subset of claude, codex and grok. By default it is
#   every agent whose home directory exists (~/.claude, ~/.codex, ~/.grok);
#   --uninstall defaults to all three. Installing never removes an agent you
#   left out: use --uninstall --agents <those> for that.
#
# WHAT IT DOES
#   always   ~/.local/bin/papercut         -> symlink to bin/papercut
#            the log directory             created (see `papercut --where`)
#   claude   ~/.claude/rules/papercuts.md  -> symlink to AGENT-INSTRUCTIONS.md
#            ~/.claude/skills/papercuts    -> symlink to skills/papercuts
#   codex    ~/.codex/AGENTS.md            gets a copy of AGENT-INSTRUCTIONS.md
#            ~/.codex/skills/papercuts     -> symlink to skills/papercuts
#            ~/.codex/config.toml          the log directory joins the sandbox's
#                                          writable_roots, so sandboxed sessions
#                                          can write the log
#   grok     Grok reads ~/.claude/rules and ~/.claude/skills too, unless
#            [compat.claude] in ~/.grok/config.toml turns that off. If the
#            claude copy is there and Grok reads it, Grok needs nothing of its
#            own (a second copy would load twice). Otherwise:
#            ~/.grok/AGENTS.md             gets a copy of AGENT-INSTRUCTIONS.md
#            ~/.grok/skills/papercuts      -> symlink to skills/papercuts
#
#   An AGENTS.md can't include another file, so the copy sits between
#   <!-- papercut:begin --> and <!-- papercut:end --> markers. Re-run the
#   installer after editing AGENT-INSTRUCTIONS.md; never edit the copy.
#
# SAFETY
#   A file is backed up to <file>.bak-papercut-<time> before it is changed, and
#   every change is written to a temp file first and then moved into place.
#   A real file where a symlink should go is left alone. Existing
#   writable_roots entries are kept; uninstall removes only what install added,
#   deletes files install created, and never touches the log.
#
# DEPENDENCIES
#   jq (papercut itself) and python3. The Codex config.toml edit needs
#   python3 >= 3.11 (tomllib); without it that one step is skipped with a note.
#

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$HERE/AGENT-INSTRUCTIONS.md"
SKILL="$HERE/skills/papercuts"
TS="$(date +%Y%m%d-%H%M%S)-$$"

MODE=apply
AGENTS=""
AGENTS_GIVEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --uninstall) MODE=uninstall; shift ;;
    --agents)
      [[ $# -ge 2 && -n "$2" ]] || { echo "install.sh: --agents needs a list, e.g. --agents claude,codex" >&2; exit 2; }
      AGENTS="$2"; AGENTS_GIVEN=1; shift 2 ;;
    --agents=*) AGENTS="${1#--agents=}"; AGENTS_GIVEN=1; shift ;;
    -h|--help) awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "install.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

ALL_AGENTS="claude codex grok"
if [[ "$AGENTS_GIVEN" -eq 1 ]]; then
  AGENTS="${AGENTS//,/ }"
  [[ -n "${AGENTS// /}" ]] || { echo "install.sh: --agents needs at least one of claude, codex, grok" >&2; exit 2; }
  for a in $AGENTS; do
    case " $ALL_AGENTS " in
      *" $a "*) ;;
      *) echo "install.sh: unknown agent '$a' (valid: claude codex grok)" >&2; exit 2 ;;
    esac
  done
elif [[ "$MODE" == uninstall ]]; then
  AGENTS="$ALL_AGENTS"
else
  for a in $ALL_AGENTS; do [[ -d "$HOME/.$a" ]] && AGENTS="$AGENTS $a"; done
  if [[ -z "$AGENTS" ]]; then
    echo "install.sh: found none of ~/.claude, ~/.codex, ~/.grok; pass --agents claude,codex,grok (any subset)" >&2
    exit 2
  fi
fi
selected() { case " $AGENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

command -v jq >/dev/null || { echo "install.sh: jq is required (papercut needs it)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "install.sh: python3 is required" >&2; exit 1; }
HAVE_TOML=0; python3 -c 'import tomllib' 2>/dev/null && HAVE_TOML=1

# The CLI decides where the log lives; ask it rather than repeat the rule.
LOG_DIR="$(dirname "$("$HERE/bin/papercut" --where | sed -n 's/^log: //p')")"

DRIFT=0    # --check found something missing or out of date
FAILED=0   # a step couldn't be done safely and was skipped

say() {
  printf '  %-8s %s\n' "$1" "$2"
  case "$1" in MISSING | STALE) DRIFT=1 ;; esac
}

# py <op> <args...>: run one step of the helper below. It exits 10 when --check
# finds drift and 11 when it skipped a change it couldn't make safely.
py() {
  local rc=0
  python3 - "$MODE" "$TS" "$@" <<'PY' || rc=$?
import json, os, re, shutil, sys
mode, ts, op, *args = sys.argv[1:]
DRIFT, SKIPPED = 10, 11

def read(p):
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8", newline="") as f:
        return f.read()

def save(path, old, new):
    """Back up, then replace atomically. A file that uninstall leaves empty held
    only what install wrote, so it goes (with no backup)."""
    if mode == "uninstall" and not new.strip():
        os.remove(path)
        return
    if old:
        shutil.copy2(path, f"{path}.bak-papercut-{ts}")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.papercut-tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(new)
    if old is not None:
        shutil.copymode(path, tmp)
    os.replace(tmp, path)

def say(label, text):
    print(f"  {label:<8} {text}")

def block(path, doc, here):
    old = read(path)
    text = old or ""
    begin = f"<!-- papercut:begin (managed by {here}/install.sh; edit AGENT-INSTRUCTIONS.md there, not here) -->"
    block_re = r"<!-- papercut:begin.*?<!-- papercut:end -->\n?"
    if mode == "uninstall":
        # Remove exactly what install added: the block and the blank line before it.
        m = re.search(r"(?:(?<=\n)\n)?" + block_re, text, re.S)
        if not m:
            say("skip", f"{path} (no papercut block)")
            return 0
        new = text[:m.start()] + text[m.end():]
    else:
        body = read(doc).strip()
        new_block = f"{begin}\n{body}\n<!-- papercut:end -->\n"
        if re.search(block_re, text, re.S):
            new = re.sub(block_re, lambda _: new_block, text, count=1, flags=re.S)
        else:
            sep = ("\n" if not text.endswith("\n") else "") + "\n" if text else ""
            new = text + sep + new_block
    if new == text and old is not None:
        say("ok", path)
        return 0
    if mode == "check":
        say("STALE", f"{path} (papercut block missing or out of date)")
        return DRIFT
    save(path, old, new)
    say("removed" if mode == "uninstall" else "updated", path)
    return 0

def roots(path, root):
    import tomllib
    old = read(path)
    text = old or ""
    by_hand = (f"skipped  {path}: couldn't edit it safely; "
               f"{'remove' if mode == 'uninstall' else 'add'} \"{root}\" in "
               f"[sandbox_workspace_write] writable_roots by hand")
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        print(f"  skipped  {path}: not valid TOML ({e})")
        return SKIPPED
    current = data.get("sandbox_workspace_write", {}).get("writable_roots", [])
    q = json.dumps(root)  # a TOML basic string is JSON-compatible for a path
    # Markers let uninstall remove only what install added: MARK on a key or
    # table install created, ROOT_MARK after "]" when it extended the user's array.
    MARK = " # added by papercut install.sh"
    ROOT_MARK = " # papercut writable root added by install.sh"
    # Only a one-line array is edited; anything else is left for a human.
    array = re.search(r"(?ms)^\[sandbox_workspace_write\][^\n]*\n(?:(?!^\[).)*?"
                      r"^writable_roots\s*=\s*\[([^\]\n]*)\]", text)

    def commit(new, verb):
        try:
            ok = (root in tomllib.loads(new).get("sandbox_workspace_write", {})
                  .get("writable_roots", [])) != (mode == "uninstall")
        except tomllib.TOMLDecodeError:
            ok = False
        if not ok:
            print("  " + by_hand)
            return SKIPPED
        save(path, old, new)
        say(verb, f"{path} writable_roots {'-=' if verb == 'removed' else '+='} {root}")
        return 0

    if mode == "uninstall":
        line = ""
        if array:
            end = text.find("\n", array.end())
            line = text[array.start():end if end >= 0 else len(text)]
        if root not in current or (MARK not in line and ROOT_MARK not in line):
            say("skip", f"{path} (no writable root added by install.sh)")
            return 0
        inner = array.group(1)
        for added in (", " + q, q + ", ", q):
            if added in inner:
                kept = inner.replace(added, "", 1)
                break
        else:
            print("  " + by_hand)
            return SKIPPED
        new = text[:array.start(1)] + kept + text[array.end(1):].replace(ROOT_MARK, "", 1)
        # A key or table install created goes away entirely.
        new = new.replace("writable_roots = []" + MARK + "\n", "", 1)
        table = re.search(r"\n*^\[sandbox_workspace_write\]" + re.escape(MARK) + r"\n(?=\[|\Z)", new, re.M)
        if table:
            rest = new[table.end():]
            new = new[:table.start()] + ("\n" if table.start() and not rest else "") + rest
        return commit(new, "removed")

    if root in current:
        say("ok", f"{path} writable_roots has {root}")
        return 0
    if mode == "check":
        say("MISSING", f"{path} writable_roots lacks {root}")
        return DRIFT
    if "sandbox_workspace_write" not in data:
        new = (text.rstrip("\n") + ("\n\n" if text.strip() else "")
               + f"[sandbox_workspace_write]{MARK}\nwritable_roots = [{q}]{MARK}\n")
    elif "writable_roots" not in data["sandbox_workspace_write"]:
        new = re.sub(r"(?m)^\[sandbox_workspace_write\][^\n]*\n",
                     lambda m: m.group(0) + f"writable_roots = [{q}]{MARK}\n", text, count=1)
    elif array:
        inner = array.group(1)
        body = inner.rstrip()
        # Insert after the last element, keeping the user's padding.
        joined = f"{body}, {q}{inner[len(body):]}" if body.strip() else inner + q
        new = text[:array.start(1)] + joined + "]" + ROOT_MARK + text[array.end(1) + 1:]
    else:
        print("  " + by_hand)
        return SKIPPED
    return commit(new, "updated")

def compat(path, cell):
    """Does Grok read ~/.claude/<cell>? Grok's default is yes."""
    text = read(path) or ""
    try:
        import tomllib
        on = tomllib.loads(text).get("compat", {}).get("claude", {}).get(cell, True)
    except ImportError:
        print(f"note: python3 < 3.11 can't read {path}; giving Grok its own {cell} copy", file=sys.stderr)
        on = False
    except Exception:
        print(f"note: can't parse {path}; giving Grok its own {cell} copy", file=sys.stderr)
        on = False
    print("yes" if on else "no")
    return 0

sys.exit({"block": block, "roots": roots, "compat": compat}[op](*args))
PY
  case "$rc" in
    0) ;;
    10) DRIFT=1 ;;
    11) FAILED=1 ;;
    *) return "$rc" ;;
  esac
}

# link <target> <link-path>: create, repoint, check or remove a symlink, never
# clobbering a real file or directory.
link() {
  local target="$1" dest="$2"
  if [[ "$MODE" == uninstall ]]; then
    if [[ -L "$dest" && "$(readlink "$dest")" == "$target" ]]; then
      command rm -f "$dest"
      # Only the rules/ or skills/ folder the link sat in, and only if empty.
      case "$dest" in */rules/* | */skills/*) rmdir "$(dirname "$dest")" 2>/dev/null || true ;; esac
      say removed "$dest"
    else
      say skip "$dest (not a symlink to this checkout)"
    fi
    return
  fi
  if [[ -L "$dest" && "$(readlink "$dest")" == "$target" ]]; then
    say ok "$dest"
    return
  fi
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    echo "install.sh: $dest exists and is not a symlink; move it aside and re-run" >&2
    exit 1
  fi
  local old=""
  [[ -L "$dest" ]] && old="$(readlink "$dest")"
  if [[ "$MODE" == check ]]; then
    say MISSING "$dest -> $target${old:+ (now points to $old)}"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$target" "$dest"
  say linked "$dest -> $target${old:+ (was $old)}"
}

# claude_has <rules|skills>: is (or, being installed now, will) the claude copy
# of that piece point here?
claude_has() {
  local dest target
  if [[ "$1" == rules ]]; then dest="$HOME/.claude/rules/papercuts.md"; target="$DOC"
  else dest="$HOME/.claude/skills/papercuts"; target="$SKILL"; fi
  if [[ "$MODE" != uninstall ]] && selected claude; then echo yes; return; fi
  [[ -L "$dest" && -e "$dest" && "$(readlink "$dest")" == "$target" ]] && echo yes || echo no
}
# Grok's [compat.claude] settings, read once (only when Grok is in play).
GROK_RULES=no; GROK_SKILLS=no
if [[ -d "$HOME/.grok" ]] || selected grok; then
  GROK_RULES="$(py compat "$HOME/.grok/config.toml" rules)"
  GROK_SKILLS="$(py compat "$HOME/.grok/config.toml" skills)"
fi
grok_reads_claude() {
  local on="$GROK_RULES"; [[ "$1" == skills ]] && on="$GROK_SKILLS"
  [[ "$on" == yes && "$(claude_has "$1")" == yes ]]
}

# drop_duplicate <path> <step...>: Grok's own copy at <path> is redundant once
# Grok reads the claude one, and would load twice. Install removes it with
# <step> run as an uninstall; --check reports it.
drop_duplicate() {
  local dest="$1"; shift
  if [[ "$1" == py ]]; then
    grep -q '<!-- papercut:begin' "$dest" 2>/dev/null || return 0
  else
    [[ -L "$dest" && "$(readlink "$dest")" == "$SKILL" ]] || return 0
  fi
  if [[ "$MODE" == check ]]; then
    say STALE "$dest (duplicate of the claude copy; install removes it)"
    return 0
  fi
  local MODE=uninstall
  "$@"
}

# Decided before anything is removed: does Grok read papercut through ~/.claude?
GROK_VIA_CLAUDE=no
if [[ -d "$HOME/.grok" ]] && grok_reads_claude rules; then GROK_VIA_CLAUDE=yes; fi

echo "papercut install ($MODE: ${AGENTS# })"
[[ "$MODE" == apply ]] && mkdir -p "$LOG_DIR"

if [[ "$MODE" != uninstall ]]; then
  echo "CLI"
  link "$HERE/bin/papercut" "$HOME/.local/bin/papercut"
fi

if selected claude; then
  echo "Claude Code"
  link "$DOC" "$HOME/.claude/rules/papercuts.md"
  link "$SKILL" "$HOME/.claude/skills/papercuts"
fi

if selected codex; then
  echo "Codex"
  py block "$HOME/.codex/AGENTS.md" "$DOC" "$HERE"
  link "$SKILL" "$HOME/.codex/skills/papercuts"
  if [[ "$HAVE_TOML" -eq 1 ]]; then
    py roots "$HOME/.codex/config.toml" "$LOG_DIR"
  else
    echo "  skipped  ~/.codex/config.toml: the writable_roots edit needs python3 >= 3.11"
    FAILED=1
  fi
fi

if selected grok; then
  echo "Grok"
  if [[ "$MODE" == uninstall ]]; then
    py block "$HOME/.grok/AGENTS.md" "$DOC" "$HERE"
    link "$SKILL" "$HOME/.grok/skills/papercuts"
  else
    if grok_reads_claude rules; then
      say ok "instructions via ~/.claude/rules ([compat.claude] rules)"
      drop_duplicate "$HOME/.grok/AGENTS.md" py block "$HOME/.grok/AGENTS.md" "$DOC" "$HERE"
    else
      py block "$HOME/.grok/AGENTS.md" "$DOC" "$HERE"
    fi
    if grok_reads_claude skills; then
      say ok "skill via ~/.claude/skills ([compat.claude] skills)"
      drop_duplicate "$HOME/.grok/skills/papercuts" link "$SKILL" "$HOME/.grok/skills/papercuts"
    else
      link "$SKILL" "$HOME/.grok/skills/papercuts"
    fi
  fi
elif selected claude && [[ "$GROK_VIA_CLAUDE" == yes ]]; then
  if [[ "$MODE" == uninstall ]]; then
    echo "note: Grok was reading papercut through ~/.claude, which is gone now."
    echo "      To keep it for Grok, run: ./install.sh --agents grok"
  else
    echo "note: Grok reads ~/.claude/rules and ~/.claude/skills too, so it will see papercut."
    echo "      To keep it out, set rules/skills = false under [compat.claude] in ~/.grok/config.toml"
    echo "      (that hides all of your Claude rules and skills from Grok, not just papercut)."
  fi
fi

# any_copy_left: is papercut still installed for some agent?
any_copy_left() {
  local f
  for f in "$HOME/.claude/rules/papercuts.md" "$HOME/.claude/skills/papercuts" \
           "$HOME/.codex/skills/papercuts" "$HOME/.grok/skills/papercuts"; do
    [[ -L "$f" && "$(readlink "$f")" == "$HERE"/* ]] && return 0
  done
  grep -qs '<!-- papercut:begin' "$HOME/.codex/AGENTS.md" "$HOME/.grok/AGENTS.md"
}

# The CLI is shared, so uninstall removes it only once no agent uses it.
if [[ "$MODE" == uninstall ]]; then
  echo "CLI"
  if any_copy_left; then
    say kept "$HOME/.local/bin/papercut (other agents still use it)"
  else
    link "$HERE/bin/papercut" "$HOME/.local/bin/papercut"
  fi
fi

if [[ "$MODE" == uninstall ]]; then
  echo "kept: $LOG_DIR (your log and triage ledger; delete it yourself if you want it gone)"
elif [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo "note: ~/.local/bin is not on PATH in this shell; agents fall back to ~/.local/bin/papercut"
fi

if [[ "$FAILED" -eq 1 ]]; then exit 3; fi
if [[ "$MODE" == check && "$DRIFT" -eq 1 ]]; then exit 1; fi
exit 0
