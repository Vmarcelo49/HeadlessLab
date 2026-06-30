#!/bin/bash
# build-from-scratch.sh — rebuilds the bundle from scratch (Option B of GUIDE_LLM.md).
# Use this when the precompiled bundle doesn't work or to update versions.
#
# REQUIRES: working apt-get download on host (Debian/Ubuntu), curl, gcc, Xvfb.
# Does NOT require sudo (everything is done via apt-get download + dpkg-deb -x).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"

DOWNLOAD="$BUNDLE_DIR/_build/download"
NEW_PREFIX="$BUNDLE_DIR/_build/prefix"
ZLIB_BUILD="$BUNDLE_DIR/_build/zlib-build"

echo "=== Build from scratch ==="
echo "Bundle dir: $BUNDLE_DIR"
echo ""

mkdir -p "$DOWNLOAD" "$NEW_PREFIX" "$ZLIB_BUILD"

# === Step 1: Download .deb packages ===
echo "=== Step 1: Downloading .deb packages ==="
cd "$DOWNLOAD"

PACKAGES=(
    wine wine64 libwine fonts-wine
    binutils-mingw-w64-x86-64
    gcc-mingw-w64-x86-64-win32
    g++-mingw-w64-x86-64-win32
    gcc-mingw-w64-x86-64-win32-runtime
    gcc-mingw-w64-base
    mingw-w64-x86-64-dev mingw-w64-common
    bubblewrap
    mesa-vulkan-drivers
    libllvm19 libdrm-amdgpu1 libdrm2 libdrm-intel1 libdrm-nouveau2 libdrm-radeon1
    libelf1t64 libexpat1 libwayland-client0 libx11-xcb1 libxcb-dri3-0
    libxcb-present0 libxcb-randr0 libxcb-sync1 libxcb-xfixes0 libxshmfence1
    libzstd1
    proot libtalloc2
)

for pkg in "${PACKAGES[@]}"; do
    echo "  Downloading $pkg..."
    apt-get download "$pkg" 2>&1 | tail -1
done

echo "Total downloaded: $(ls -1 "$DOWNLOAD"/*.deb | wc -l) packages"

# === Step 2: Extract .debs into prefix ===
echo ""
echo "=== Step 2: Extracting .deb packages ==="
for deb in "$DOWNLOAD"/*.deb; do
    if [[ "$deb" == *%* ]]; then
        cp "$deb" "${deb}.renamed"
        deb="${deb}.renamed"
    fi
    dpkg-deb -x "$deb" "$NEW_PREFIX" 2>/dev/null
done

# Verify extraction
ls "$NEW_PREFIX/usr/lib/wine/wine64" > /dev/null && echo "  OK: wine64 extracted"
ls "$NEW_PREFIX/usr/bin/bwrap" > /dev/null && echo "  OK: bwrap extracted"
ls "$NEW_PREFIX/usr/lib/x86_64-linux-gnu/libvulkan_lvp.so" > /dev/null && echo "  OK: llvmpipe extracted"
ls "$NEW_PREFIX/usr/bin/x86_64-w64-mingw32-gcc-win32" > /dev/null && echo "  OK: mingw extracted"

# === Step 3: Patch Wine wrappers ===
echo ""
echo "=== Step 3: Patching Wine wrappers ==="
bash "$SCRIPT_DIR/patch-wrappers.sh" "$NEW_PREFIX"

# === Step 4: Compile zlib1.dll ===
echo ""
echo "=== Step 4: Compiling zlib1.dll ==="
cd "$ZLIB_BUILD"

if [ ! -f zlib-1.3.1.tar.gz ]; then
    curl -sSL https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz -o zlib.tar.gz
fi
tar xzf zlib.tar.gz
cd zlib-1.3.1

export PATH="$NEW_PREFIX/usr/bin:$PATH"
MINGW_CC="x86_64-w64-mingw32-gcc-win32"

for src in adler32.c crc32.c deflate.c inflate.c inftrees.c inffast.c zutil.c \
           trees.c gzclose.c gzlib.c gzread.c gzwrite.c compress.c uncompr.c; do
    [ -f "$src" ] && "$MINGW_CC" -O2 -DZLIB_DLL -DWINDOWS -c "$src" -o "${src%.c}.o"
done

"$MINGW_CC" -shared -o zlib1.dll \
    -Wl,--out-implib,libz.dll.a \
    adler32.o crc32.o deflate.o inflate.o inftrees.o inffast.o zutil.o trees.o \
    gzclose.o gzlib.o gzread.o gzwrite.o compress.o uncompr.o

cp zlib1.dll "$NEW_PREFIX/usr/lib/x86_64-linux-gnu/wine/x86_64-windows/"
echo "  OK: zlib1.dll compiled"

# === Step 5: Compile DX9 example (BEFORE clean-prefix removes MinGW) ===
# Previously this step ran AFTER clean-prefix.sh, which removed MinGW,
# causing dx9_triangle.exe compilation to always fail with "command not found".
# Now we compile while MinGW is still present, then strip it.
echo ""
echo "=== Step 5: Compiling DX9 example ==="
export PATH="$NEW_PREFIX/usr/bin:$PATH"
MINGW_CXX="x86_64-w64-mingw32-g++-win32"
"$MINGW_CXX" -O2 -o "$BUNDLE_DIR/examples/dx9_triangle.exe" \
    "$BUNDLE_DIR/examples/dx9_triangle.cpp" \
    -ld3d9 -ld3dcompiler -lgdi32 -luser32 -static-libgcc -static-libstdc++ \
    -Wl,--subsystem,windows
echo "  OK: dx9_triangle.exe compiled"

# === Step 6: Replace old prefix ===
echo ""
echo "=== Step 6: Replacing old prefix ==="
if [ -d "$BUNDLE_DIR/prefix.old" ]; then rm -rf "$BUNDLE_DIR/prefix.old"; fi
mv "$BUNDLE_DIR/prefix" "$BUNDLE_DIR/prefix.old" 2>/dev/null || true
mv "$NEW_PREFIX" "$BUNDLE_DIR/prefix"
rm -rf "$BUNDLE_DIR/prefix.old"

# === Step 7: Clean prefix (removes MinGW, docs, etc.) ===
echo ""
echo "=== Step 7: Cleaning prefix ==="
bash "$SCRIPT_DIR/clean-prefix.sh"

# === Step 8: Rebuild rootfs + wineprefix ===
echo ""
echo "=== Step 8: Rebuilding rootfs + wineprefix ==="
rm -rf "$BUNDLE_DIR/wineprefix"
bash "$SCRIPT_DIR/rebuild-rootfs.sh"
bash "$SCRIPT_DIR/init-wineprefix.sh"

# === Step 9: Final cleanup ===
echo ""
echo "=== Step 9: Final cleanup ==="
rm -rf "$BUNDLE_DIR/_build"

echo ""
echo "=== BUILD COMPLETE ==="
echo "Bundle ready at: $BUNDLE_DIR"
du -sh "$BUNDLE_DIR"
echo ""
echo "Next steps:"
echo "  1. Run: $SCRIPT_DIR/headless --verify"
echo "  2. Pack: $SCRIPT_DIR/pack-appimage.sh"
