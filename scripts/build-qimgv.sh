#!/bin/bash
# Builds the Windows release archive (qimgv-x64.7z) from an MSYS2 UCRT64 shell.
#
# Qt 6 comes from MSYS2's mingw-w64-ucrt-x86_64-qt6-* packages and the C++ compiler is
# MSYS2's gcc; zig only drives the build graph (see build.zig). The third-party
# image-format plugins the Qt5-era script compiled (JXL/AVIF/APNG/HEIF/RAW) are not
# built any more -- glyh/qimgv#23 tracks restoring them.
set -euo pipefail

if [[ "${MSYSTEM:-}" != "UCRT64" && "${MSYSTEM:-}" != "MINGW64" && "${MSYSTEM:-}" != "CLANG64" ]]; then
    echo "run this from an MSYS2 MinGW shell (MSYSTEM=UCRT64)" >&2
    exit 1
fi
command -v zig >/dev/null || { echo "zig 0.17 must be on PATH" >&2; exit 1; }

SRC_DIR=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
cd "$SRC_DIR"

# ------------------------------------------------------------------------------
echo "BUILDING"
BUILD_DIR="$SRC_DIR/build"
INSTALL_DIR="$BUILD_DIR/install"
rm -rf "$BUILD_DIR"
mkdir -p "$INSTALL_DIR"

# opencv=false: MSYS2 ships OpenCV 5.0, which no longer installs opencv4.pc and whose
# API the 3rdparty QtOpenCV shim predates. Linux still builds with opencv=true.
zig build -Doptimize=ReleaseFast -Dexiv2=true -Dvideo=true -Dopencv=false \
    --prefix "$INSTALL_DIR"

# ------------------------------------------------------------------------------
echo "ASSEMBLING PACKAGE"
# Users download an archive whose root holds qimgv.exe, so bin/ is flattened here:
# the install tree is bin/qimgv.exe, bin/plugins/, bin/translations/ and share/.
# The fork's remote carries no tags, so describe has nothing to name; --always falls
# back to the abbreviated commit rather than exiting 128 under set -e.
BUILD_NAME="qimgv-x64_$(git describe --tags --always)"
PACKAGE_DIR="$SRC_DIR/$BUILD_NAME"
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

cp "$INSTALL_DIR/bin/qimgv.exe" "$PACKAGE_DIR/"
cp -r "$INSTALL_DIR/bin/plugins" "$PACKAGE_DIR/"
cp -r "$INSTALL_DIR/bin/translations" "$PACKAGE_DIR/"
cp -r "$INSTALL_DIR/share" "$PACKAGE_DIR/"
cp -r "$SRC_DIR/qimgv/distrib/mimedata/data" "$PACKAGE_DIR/"
mkdir -p "$PACKAGE_DIR/cache" "$PACKAGE_DIR/conf" "$PACKAGE_DIR/thumbnails"

# Qt runtime and its plugins (platforms/, imageformats/, styles/, iconengines/, tls/).
windeployqt --release --no-translations --no-compiler-runtime \
    --no-system-d3d-compiler --no-opengl-sw \
    --dir "$PACKAGE_DIR" "$PACKAGE_DIR/qimgv.exe"

# Everything else the exe and the plugin pull in from MSYS2: mpv, exiv2, ffmpeg and the
# MinGW runtime. ntldd walks the dependency tree; only DLLs under the MSYS2 prefix are
# shipped. It prints Windows paths ("D:\...\ucrt64\bin\libmpv-2.dll"), so the prefix
# match accepts either separator -- matching only '/' silently shipped a package with no
# mpv and no MinGW runtime in it at all.
collect_dlls() {
    for exe in "$@"; do
        ntldd -R "$exe" 2>/dev/null || true
    done | awk '{print $3}' | grep -iE '[/\\](mingw64|ucrt64|clang64)[/\\]' | while read -r p; do
        cygpath -u "$p"
    done | sort -u
}

collected=$(collect_dlls "$PACKAGE_DIR/qimgv.exe" "$PACKAGE_DIR/plugins/player_mpv.dll" || true)
if [ -z "$collected" ]; then
    echo "ntldd resolved no MSYS2 DLLs to ship; is ntldd installed and on PATH?" >&2
    exit 1
fi

while IFS= read -r dll; do
    [ -f "$dll" ] || continue
    cp -n "$dll" "$PACKAGE_DIR/" 2>/dev/null || true
done <<< "$collected"

# A missing runtime DLL here is an archive that cannot start on a clean machine, so say
# so loudly rather than shipping it.
missing=""
while IFS= read -r dll; do
    [ -n "$dll" ] || continue
    [ -f "$PACKAGE_DIR/$(basename "$dll")" ] || missing="$missing $(basename "$dll")"
done <<< "$collected"
if [ -n "$missing" ]; then
    echo "PACKAGE INCOMPLETE, missing:$missing" >&2
    exit 1
fi
echo "  shipped $(printf '%s\n' "$collected" | wc -l) MSYS2 runtime DLLs"

# ------------------------------------------------------------------------------
echo "PACKAGING"
cd "$SRC_DIR"
rm -f qimgv-x64.7z
7z a qimgv-x64.7z "./$BUILD_NAME"
echo "PACKAGING DONE: $SRC_DIR/qimgv-x64.7z"
