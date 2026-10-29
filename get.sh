#!/usr/bin/env bash
#
# get.sh — download a papercut release and install it
#
#   curl -fsSL https://raw.githubusercontent.com/nkrebs13/papercut/main/get.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/nkrebs13/papercut/main/get.sh | bash -s -- --agents claude,codex
#
# Downloads the latest release (or $PAPERCUT_VERSION, e.g. v0.2.0) into
# ~/.local/share/papercut and runs its install.sh with the arguments given.
# Run it again to update; the installed links point at that folder, so they
# keep working. If the new release's install.sh fails, the previous release
# is put back. To remove papercut:
#
#   ~/.local/share/papercut/install.sh --uninstall && rm -rf ~/.local/share/papercut
#
# It refuses to replace a ~/.local/share/papercut that it didn't create (one
# without its .papercut-get marker), such as a git checkout.
#
# Test hook: PAPERCUT_TARBALL=<file.tar.gz> installs from that file instead
# of downloading.

# Everything is inside main, called on the last line, so a download cut off
# partway through `curl | bash` defines a function and runs nothing.
main() {
  set -euo pipefail

  local repo="nkrebs13/papercut"
  local dest="$HOME/.local/share/papercut"
  local marker=".papercut-get"
  local version latest staged old dep rc apply=1

  for dep in curl tar jq python3; do
    command -v "$dep" >/dev/null || fail "$dep is required"
  done

  if [[ -e "$dest" && ! -f "$dest/$marker" ]]; then
    fail "$dest exists and wasn't created by get.sh; move it aside, or run install.sh from it"
  fi

  # mktemp needs a template to honour TMPDIR on macOS. work is global so the
  # EXIT trap, which runs after main returns, can still see it.
  work="$(mktemp -d "${TMPDIR:-/tmp}/papercut-get.XXXXXX")"
  trap 'rm -rf "$work"' EXIT

  if [[ -n "${PAPERCUT_TARBALL:-}" ]]; then
    cp "$PAPERCUT_TARBALL" "$work/papercut.tar.gz"
    version="local"
  else
    version="${PAPERCUT_VERSION:-}"
    if [[ -z "$version" ]]; then
      # The releases/latest page redirects to .../tag/<version>. Unlike the
      # API, it isn't limited to 60 requests an hour.
      latest="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")" \
        || fail "couldn't look up the latest release"
      version="${latest##*/tag/}"
      [[ "$version" != "$latest" && -n "$version" ]] || fail "no release found for $repo"
    fi
    echo "papercut $version"
    curl -fsSL "https://github.com/$repo/archive/refs/tags/$version.tar.gz" -o "$work/papercut.tar.gz" \
      || fail "couldn't download $version"
  fi

  mkdir "$work/src"
  tar -xzf "$work/papercut.tar.gz" -C "$work/src" --strip-components 1 || fail "couldn't unpack the download"
  [[ -f "$work/src/install.sh" && -f "$work/src/bin/papercut" ]] || fail "the download doesn't look like papercut"
  echo "$version" > "$work/src/$marker"

  # Swap the new copy into place with renames, keeping the previous one until
  # its install.sh has succeeded. Ownership is checked again in case something
  # else created the folder while this was downloading.
  mkdir -p "$(dirname "$dest")"
  staged="$dest.new.$$"
  old="$dest.old.$$"
  rm -rf "$staged"
  mv "$work/src" "$staged"
  if [[ -e "$dest" && ! -f "$dest/$marker" ]]; then
    rm -rf "$staged"
    fail "$dest appeared while downloading and wasn't created by get.sh; leaving it alone"
  fi
  if [[ -e "$dest" ]]; then
    mv "$dest" "$old"
    if ! mv "$staged" "$dest"; then
      mv "$old" "$dest"
      fail "couldn't move the new copy into place; kept the previous one"
    fi
  else
    mv "$staged" "$dest"
  fi

  # Exit 3 means install.sh finished but skipped a step: that's still an install.
  # --check and --uninstall aren't installs, so they never roll back.
  case " $* " in *" --check "* | *" --uninstall "*) apply=0 ;; esac
  rc=0
  "$dest/install.sh" "$@" || rc=$?
  if [[ -e "$old" ]]; then
    if [[ "$apply" -eq 1 && "$rc" -ne 0 && "$rc" -ne 3 ]]; then
      rm -rf "$dest"
      mv "$old" "$dest"
      echo "get.sh: install.sh failed (exit $rc); put the previous release back" >&2
    else
      rm -rf "$old"
    fi
  fi
  return "$rc"
}

fail() { echo "get.sh: $*" >&2; exit 1; }

main "$@"
