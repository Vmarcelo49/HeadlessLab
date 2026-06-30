#!/bin/bash
# clean-prefix.sh — removes non-essential components from prefix to reduce size.
# Removes: MinGW (only needed at build time), docs, locales, unused large PE DLLs.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"
PREFIX="${1:-$BUNDLE_DIR/prefix}"

if [ ! -d "$PREFIX/usr/lib/wine" ]; then
    echo "FAIL: $PREFIX/usr/lib/wine does not exist" >&2
    exit 1
fi

echo "=== Before ==="
du -sh "$PREFIX"

# Remove MinGW
echo ">> Removing MinGW..."
rm -rf "$PREFIX/usr/lib/gcc"
rm -rf "$PREFIX/usr/x86_64-w64-mingw32"
rm -rf "$PREFIX/usr/share/mingw-w64"
rm -rf "$PREFIX/usr/include"
for f in "$PREFIX/usr/bin"/x86_64-w64-mingw32-*; do
    [ -f "$f" ] && rm -f "$f"
done

# Remove docs/man/locales
echo ">> Removing docs/man/locale..."
rm -rf "$PREFIX/usr/share/doc" "$PREFIX/usr/share/man" "$PREFIX/usr/share/info"
rm -rf "$PREFIX/usr/share/locale" "$PREFIX/usr/share/bug" "$PREFIX/usr/share/lintian"
rm -rf "$PREFIX/usr/share/base-files" "$PREFIX/usr/share/common-licenses" "$PREFIX/usr/share/pixmaps"

# Remove non-essential PE DLLs
WINE_PE="$PREFIX/usr/lib/x86_64-linux-gnu/wine/x86_64-windows"
echo ">> Removing non-essential PE DLLs..."

declare -a REMOVE_LIST=(
    mshtml.dll jscript.dll dispex.dll
    msxml3.dll msxml6.dll
    winedbg.exe
    odbc32.dll odbccp32.dll odbcji32.dll
    qcap.dll
    mscoree.dll
    wpcap.dll
    wineps*.drv
)

for f in "${REMOVE_LIST[@]}"; do
    rm -f "$WINE_PE/$f"
done

# Strip
if which strip > /dev/null 2>&1; then
    echo ">> Stripping .so files..."
    find "$PREFIX/usr/lib/wine" -name "*.so" -exec strip --strip-unneeded {} \; 2>/dev/null || true
    find "$PREFIX/usr/lib/x86_64-linux-gnu" -maxdepth 1 -name "*.so*" -exec strip --strip-unneeded {} \; 2>/dev/null || true
fi

echo ""
echo "=== After ==="
du -sh "$PREFIX"
