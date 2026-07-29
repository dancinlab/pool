#!/bin/sh
# pool installer — links bin/pool onto PATH and prepares the state dir.
#
#   ./install.sh                 # -> ~/.local/bin/pool (symlink)
#   PREFIX=/usr/local ./install.sh
#   POOL_COPY=1 ./install.sh     # copy instead of symlink
#
# Zero dependencies beyond python3 (3.8+, stdlib only).
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)/bin/pool
PREFIX=${PREFIX:-$HOME/.local}
DEST_DIR=$PREFIX/bin
DEST=$DEST_DIR/pool

if [ ! -f "$SRC" ]; then
    echo "install: $SRC not found" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "install: python3 not found on PATH — pool needs python3 (3.8+, stdlib only)" >&2
    exit 1
fi

mkdir -p "$DEST_DIR" "$HOME/.pool"
chmod +x "$SRC"

if [ "${POOL_COPY:-0}" = 1 ]; then
    cp "$SRC" "$DEST"
    echo "installed  $DEST  (copy)"
else
    ln -sf "$SRC" "$DEST"
    echo "installed  $DEST -> $SRC"
fi
chmod +x "$DEST"

# A stale `pool` earlier on PATH silently shadows the one we just installed —
# the exact failure that retired the previous build (a shim pointing at a CLI
# that no longer existed). Say so loudly rather than leave a broken `pool`.
FOUND=$(command -v pool 2>/dev/null || true)
case "$FOUND" in
    "$DEST") ;;
    "")
        echo
        echo "note: $DEST_DIR is not on your PATH. Add it:"
        echo "      export PATH=\"$DEST_DIR:\$PATH\""
        ;;
    *)
        echo
        echo "WARNING: another 'pool' shadows this install on PATH:"
        echo "         $FOUND"
        echo "         Remove it, or put $DEST_DIR earlier on PATH."
        ;;
esac

echo "state dir  $HOME/.pool"
echo "try        pool list --fast"
