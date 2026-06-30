#!/bin/bash
# setup-32bit.sh — adds 32-bit (i386) Windows binary support to the prefix.
#
# This script downloads the i386 Wine packages from the Debian pool (no sudo,
# no dpkg --add-architecture needed) and patches the 32-bit wine binary to use
# /usr/lib/ld-linux.so.2 as its interpreter (so it can run inside the bwrap
# sandbox without /lib/ld-linux.so.2 on the host).
#
# After running this script, the headless CLI can run 32-bit (PE32 i386) Windows
# binaries via Wine's WoW64 mode, alongside the existing 64-bit (PE32+ x86-64)
# support.
#
# Prerequisites:
#   - The 64-bit prefix must already be built (run build-from-scratch.sh first)
#   - patchelf must be available (apt-get download patchelf, or install-host-deps.sh)
#   - curl must be available
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"
PREFIX="$BUNDLE_DIR/prefix"

# Colors
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
ok()   { echo "${G}[OK]${N} $*"; }
warn() { echo "${Y}[WARN]${N} $*"; }
fail() { echo "${R}[FAIL]${N} $*" >&2; }

echo "=== HeadlessLab — 32-bit (i386) Support Setup ==="
echo "Prefix: $PREFIX"
echo ""

if [ ! -d "$PREFIX/usr/lib/wine" ]; then
    fail "Prefix not found at $PREFIX. Run build-from-scratch.sh first."
    exit 1
fi

# Check for patchelf
if ! which patchelf > /dev/null 2>&1; then
    fail "patchelf not found. Install it: apt-get download patchelf && dpkg-deb -x patchelf*.deb ~/.local/"
    exit 1
fi

# Check for curl
if ! which curl > /dev/null 2>&1; then
    fail "curl not found. Install: apt-get install curl (requires sudo)"
    exit 1
fi

# 1. Download i386 packages from Debian pool
WORK_DIR="$BUNDLE_DIR/_build/i386"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo "=== 1. Downloading i386 packages ==="

# wine32:i386 — contains the 32-bit wine ELF binary + wineserver32
if [ ! -f wine32_i386.deb ]; then
    echo "  Downloading wine32:i386..."
    # Find the correct version by scraping the pool directory
    WINE32_URL=$(curl -sSL "http://deb.debian.org/debian/pool/main/w/wine/" 2>&1 \
        | grep -oE 'href="wine32_[^"]*_i386\.deb"' \
        | sort -V | tail -1 \
        | sed 's/href="//;s/"//')
    if [ -z "$WINE32_URL" ]; then
        fail "Could not find wine32:i386 URL in Debian pool"
        exit 1
    fi
    curl -sSL --max-time 60 -o wine32_i386.deb "http://deb.debian.org/debian/pool/main/w/wine/$WINE32_URL"
fi
ok "wine32:i386 downloaded ($(ls -lh wine32_i386.deb | awk '{print $5}'))"

# libwine:i386 — contains the i386-windows DLLs (~104MB)
if [ ! -f libwine_i386.deb ]; then
    echo "  Downloading libwine:i386 (104MB)..."
    LIBWINE_URL=$(curl -sSL "http://deb.debian.org/debian/pool/main/w/wine/" 2>&1 \
        | grep -oE 'href="libwine_[^"]*_i386\.deb"' \
        | sort -V | tail -1 \
        | sed 's/href="//;s/"//')
    if [ -z "$LIBWINE_URL" ]; then
        fail "Could not find libwine:i386 URL in Debian pool"
        exit 1
    fi
    curl -sSL --max-time 120 -o libwine_i386.deb "http://deb.debian.org/debian/pool/main/w/wine/$LIBWINE_URL"
fi
ok "libwine:i386 downloaded ($(ls -lh libwine_i386.deb | awk '{print $5}'))"

# libc6:i386 — contains ld-linux.so.2 (the 32-bit ELF interpreter)
if [ ! -f libc6_i386.deb ]; then
    echo "  Downloading libc6:i386..."
    LIBC6_URL=$(curl -sSL "http://deb.debian.org/debian/pool/main/g/glibc/" 2>&1 \
        | grep -oE 'href="libc6_2\.[0-9]+-[0-9]+[^"]*_i386\.deb"' \
        | sort -V | tail -1 \
        | sed 's/href="//;s/"//')
    if [ -z "$LIBC6_URL" ]; then
        fail "Could not find libc6:i386 URL in Debian pool"
        exit 1
    fi
    curl -sSL --max-time 60 -o libc6_i386.deb "http://deb.debian.org/debian/pool/main/g/glibc/$LIBC6_URL"
fi
ok "libc6:i386 downloaded ($(ls -lh libc6_i386.deb | awk '{print $5}'))"

# 2. Extract into the prefix
echo ""
echo "=== 2. Extracting i386 packages into prefix ==="
dpkg-deb -x wine32_i386.deb "$PREFIX/" 2>&1 | head -1
dpkg-deb -x libwine_i386.deb "$PREFIX/" 2>&1 | head -1

# Extract libc6:i386 to a temp dir (we only need ld-linux.so.2 and libc.so.6)
mkdir -p libc6_extract
dpkg-deb -x libc6_i386.deb libc6_extract/

# Copy ld-linux.so.2 and libc.so.6 to the prefix
mkdir -p "$PREFIX/lib"
cp libc6_extract/usr/lib/ld-linux.so.2 "$PREFIX/lib/"
mkdir -p "$PREFIX/usr/lib/i386-linux-gnu"
cp libc6_extract/usr/lib/i386-linux-gnu/libc.so.6 "$PREFIX/usr/lib/i386-linux-gnu/" 2>/dev/null || true

ok "ld-linux.so.2 -> $PREFIX/lib/"
ok "libc.so.6 -> $PREFIX/usr/lib/i386-linux-gnu/"

# 3. Patch the 32-bit wine binary to use /usr/lib/ld-linux.so.2 as interpreter
echo ""
echo "=== 3. Patching 32-bit wine binary interpreter ==="
WINE32_BIN="$PREFIX/usr/lib/wine/wine"
if [ ! -f "$WINE32_BIN" ]; then
    fail "32-bit wine binary not found at $WINE32_BIN"
    exit 1
fi

# Backup the original
if [ ! -f "$WINE32_BIN.orig" ]; then
    cp "$WINE32_BIN" "$WINE32_BIN.orig"
fi

# Patch the interpreter
patchelf --set-interpreter /usr/lib/ld-linux.so.2 "$WINE32_BIN"
ok "Patched wine32 interpreter -> /usr/lib/ld-linux.so.2"

# Also copy ld-linux.so.2 to prefix/usr/lib/ (where the bwrap bind mount expects it)
cp "$PREFIX/lib/ld-linux.so.2" "$PREFIX/usr/lib/ld-linux.so.2"
ok "ld-linux.so.2 -> $PREFIX/usr/lib/ld-linux.so.2 (for bwrap mount)"

# 4. Verify
echo ""
echo "=== 4. Verification ==="
ls -la "$PREFIX/usr/lib/wine/wine" && ok "wine (32-bit) binary present"
ls -la "$PREFIX/usr/lib/wine/wineserver32" && ok "wineserver32 present"
ls "$PREFIX/usr/lib/i386-linux-gnu/wine/i386-windows/" | wc -l | xargs echo "  i386-windows DLLs:"
ls "$PREFIX/usr/lib/i386-linux-gnu/wine/i386-unix/" 2>/dev/null | wc -l | xargs echo "  i386-unix .so files:"
ls -la "$PREFIX/lib/ld-linux.so.2" && ok "ld-linux.so.2 present"
ls -la "$PREFIX/usr/lib/ld-linux.so.2" && ok "ld-linux.so.2 (for bwrap) present"

# 5. Cleanup
echo ""
echo "=== 5. Cleanup ==="
rm -rf "$WORK_DIR/libc6_extract"
rm -f "$WORK_DIR/wine32_i386.deb" "$WORK_DIR/libwine_i386.deb" "$WORK_DIR/libc6_i386.deb"
rmdir "$WORK_DIR" 2>/dev/null || true
rmdir "$BUNDLE_DIR/_build" 2>/dev/null || true

echo ""
ok "32-bit support installed!"
echo ""
echo "The headless CLI will now automatically:"
echo "  - Detect 32-bit (PE32 i386) Windows binaries by reading the PE Machine field"
echo "  - Mount the i386 DLLs and ld-linux.so.2 in the bwrap sandbox"
echo "  - Populate syswow64/ with i386 DLL symlinks on first wineboot"
echo "  - Report 'arch: i386' or 'arch: x86_64' in the exec JSON response"
echo ""
echo "Test with: ./bin/headless exec examples/hello_win_32.exe"
