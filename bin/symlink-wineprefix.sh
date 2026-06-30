#!/bin/bash
# symlink-wineprefix.sh — converts duplicate DLLs/exes in wineprefix/system32
# to symlinks pointing to /usr/lib/x86_64-linux-gnu/wine/x86_64-windows/.
# Drastically reduces wineprefix size without losing functionality.
#
# NOTE: This script no longer deletes syswow64/. The syswow64/ directory is
# populated by wineboot with the PE32 (i386) DLLs needed to run 32-bit Windows
# binaries via Wine's WoW64 mode. Deleting them would break 32-bit support.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"
PREFIX="$BUNDLE_DIR/prefix"
WINEPREFIX_DEFAULT="$BUNDLE_DIR/wineprefix"
WINEPREFIX="${WINEPREFIX:-$WINEPREFIX_DEFAULT}"

SYS32="$WINEPREFIX/drive_c/windows/system32"
SRC_DIR="$PREFIX/usr/lib/x86_64-linux-gnu/wine/x86_64-windows"

if [ ! -d "$SYS32" ]; then
    echo "FAIL: $SYS32 does not exist. Run init-wineprefix.sh first." >&2
    exit 1
fi

echo "Before:"
du -sh "$WINEPREFIX"
count_converted=0
count_kept=0

for f in "$SYS32"/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    # Do not convert zlib1.dll (it is custom compiled)
    if [ "$name" = "zlib1.dll" ]; then
        count_kept=$((count_kept + 1))
        continue
    fi
    if [ -f "$SRC_DIR/$name" ]; then
        size_sys32=$(stat -c%s "$f")
        size_src=$(stat -c%s "$SRC_DIR/$name")
        if [ "$size_sys32" = "$size_src" ]; then
            rm "$f"
            ln -sf "/usr/lib/x86_64-linux-gnu/wine/x86_64-windows/$name" "$f"
            count_converted=$((count_converted + 1))
        else
            count_kept=$((count_kept + 1))
        fi
    else
        count_kept=$((count_kept + 1))
    fi
done

# PRESERVE syswow64/ — required for 32-bit (PE32 i386) support via Wine WoW64.
# (Previously this block deleted all DLLs in syswow64, which broke 32-bit support.)

echo "After:"
du -sh "$WINEPREFIX"
echo "Converted to symlink: $count_converted"
echo "Kept as file: $count_kept"
