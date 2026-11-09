#!/bin/bash
# Checks that the Zig decode slice produces the same pixels as Qt's own decode.
#
#   scripts/zig-decode-check.sh <file-or-dir>...
#
# Builds the slice first (`zig build -Dzig-decode=true`), then compiles
# scripts/zig-decode-check.cpp against the archive it produced. Files the slice
# does not handle (PNG, WebP, ...) are reported as fallbacks, not failures.
set -euo pipefail

SRC_DIR=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
cd "$SRC_DIR"

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <file-or-dir>..." >&2
    exit 2
fi

zig build -Doptimize=ReleaseFast -Dzig-decode=true

ARCHIVE=$(ls -t .zig-cache/o/*/libqimgv_core.a 2>/dev/null | head -1)
if [ -z "$ARCHIVE" ]; then
    echo "no libqimgv_core.a: did the build above succeed?" >&2
    exit 1
fi

BIN=$(mktemp -d)/zig-decode-check
clang++ -std=c++17 -fPIC -O2 \
    -I zig/include \
    $(pkg-config --cflags Qt6Gui) \
    scripts/zig-decode-check.cpp "$ARCHIVE" \
    $(pkg-config --libs Qt6Gui) $(pkg-config --libs libturbojpeg) \
    -o "$BIN"

# Expand directories to the image files in them, so callers can pass a corpus
# folder directly.
FILES=()
for arg in "$@"; do
    if [ -d "$arg" ]; then
        while IFS= read -r -d '' f; do FILES+=("$f"); done \
            < <(find "$arg" -maxdepth 1 -type f \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' -o -name '*.webp' \) -print0)
    else
        FILES+=("$arg")
    fi
done

"$BIN" "${FILES[@]}"
