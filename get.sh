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
# keep working. To remove papercut:
#
#   ~/.local/share/papercut/install.sh --uninstall && rm -rf ~/.local/share/papercut
#
# It refuses to replace a ~/.local/share/papercut that it didn't create (one
# without its .papercut-get marker), such as a git checkout.
#
# Test hook: PAPERCUT_TARBALL=<file.tar.gz> installs from that file instead
# of downloading.

set -euo pipefail

REPO="nkrebs13/papercut"
DEST="$HOME/.local/share/papercut"
MARKER=".papercut-get"

fail() { echo "get.sh: $*" >&2; exit 1; }

for dep in curl tar jq python3; do
  command -v "$dep" >/dev/null || fail "$dep is required"
done

if [[ -e "$DEST" && ! -f "$DEST/$MARKER" ]]; then
  fail "$DEST exists and wasn't created by get.sh; move it aside, or run install.sh from it"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/papercut-get.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ -n "${PAPERCUT_TARBALL:-}" ]]; then
  cp "$PAPERCUT_TARBALL" "$work/papercut.tar.gz"
  version="local"
else
  version="${PAPERCUT_VERSION:-}"
  if [[ -z "$version" ]]; then
    # The releases/latest page redirects to .../tag/<version>. Unlike the API,
    # it isn't limited to 60 requests an hour.
    latest="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" \
      || fail "couldn't look up the latest release"
    version="${latest##*/tag/}"
    [[ "$version" != "$latest" && -n "$version" ]] || fail "no release found for $REPO"
  fi
  echo "papercut $version"
  curl -fsSL "https://github.com/$REPO/archive/refs/tags/$version.tar.gz" -o "$work/papercut.tar.gz" \
    || fail "couldn't download $version"
fi

mkdir "$work/src"
tar -xzf "$work/papercut.tar.gz" -C "$work/src" --strip-components 1 || fail "couldn't unpack the download"
[[ -f "$work/src/install.sh" && -f "$work/src/bin/papercut" ]] || fail "the download doesn't look like papercut"
echo "$version" > "$work/src/$MARKER"

# Swap the new copy into place with renames, so a failed download never
# leaves a half-written install behind. Ownership is checked again here, in
# case something else created the folder while this was downloading.
mkdir -p "$(dirname "$DEST")"
staged="$DEST.new.$$"
rm -rf "$staged"
mv "$work/src" "$staged"
if [[ -e "$DEST" && ! -f "$DEST/$MARKER" ]]; then
  rm -rf "$staged"
  fail "$DEST appeared while downloading and wasn't created by get.sh; leaving it alone"
fi
if [[ -e "$DEST" ]]; then
  mv "$DEST" "$DEST.old.$$"
  if ! mv "$staged" "$DEST"; then
    mv "$DEST.old.$$" "$DEST"
    fail "couldn't move the new copy into place; kept the previous one"
  fi
  rm -rf "$DEST.old.$$"
else
  mv "$staged" "$DEST"
fi

# Not exec: the EXIT trap has to run to clean up the download.
"$DEST/install.sh" "$@"
