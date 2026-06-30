#!/bin/bash
# init-wineprefix.sh — initializes WINEPREFIX using bwrap + wine64.
# Runs wineboot.exe -u, copies zlib1.dll to system32, sets X11 graphic driver.
# Converts duplicate DLLs to symlinks to save disk space.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"
PREFIX="$BUNDLE_DIR/prefix"
ROOTFS="$BUNDLE_DIR/rootfs"
WINEPREFIX_DEFAULT="$BUNDLE_DIR/wineprefix"
export WINEPREFIX="${WINEPREFIX:-$WINEPREFIX_DEFAULT}"

BWRAP="$PREFIX/usr/bin/bwrap"
WINE64="$PREFIX/usr/lib/wine/wine64"

if [ ! -x "$BWRAP" ]; then echo "FAIL: bwrap not found at $BWRAP" >&2; exit 1; fi
if [ ! -x "$WINE64" ]; then echo "FAIL: wine64 not found at $WINE64" >&2; exit 1; fi

# Guarantee Xvfb is running
if ! pgrep -f "Xvfb :99" > /dev/null; then
    echo ">> Xvfb is not running. Starting..."
    rm -rf /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null
    setsid Xvfb :99 -screen 0 1024x768x24 -ac -nolisten tcp </dev/null >/tmp/xvfb.log 2>&1 &
    disown
    sleep 2
    if ! pgrep -f "Xvfb :99" > /dev/null; then
        echo "FAIL: Xvfb did not start. Log:" >&2
        cat /tmp/xvfb.log >&2
        exit 1
    fi
fi

# Helper function to run wine inside bwrap
run_wine() {
    "$BWRAP" \
        --ro-bind /usr /host-usr \
        --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
        --ro-bind /bin /bin --ro-bind /sbin /sbin --ro-bind /etc /etc \
        --bind /tmp /tmp \
        --bind "$BUNDLE_DIR" "$BUNDLE_DIR" \
        --bind "$ROOTFS/usr" /usr \
        --ro-bind "$PREFIX/usr/lib/wine" /usr/lib/wine \
        --ro-bind "$PREFIX/usr/lib/x86_64-linux-gnu/wine" /usr/lib/x86_64-linux-gnu/wine \
        --ro-bind "$PREFIX/usr/lib/i386-linux-gnu/wine" /usr/lib/i386-linux-gnu/wine \
        --ro-bind "$PREFIX/usr/share/wine" /usr/share/wine \
        --ro-bind "$PREFIX/usr/share/vulkan" /usr/share/vulkan \
        --proc /proc \
        --dev /dev \
        --setenv DISPLAY :99 \
        --setenv WINEPREFIX "$WINEPREFIX" \
        --setenv LD_LIBRARY_PATH /usr/lib/x86_64-linux-gnu/wine/x86_64-unix:/usr/lib/x86_64-linux-gnu:/usr/lib \
        --setenv VK_ICD_FILENAMES /usr/share/vulkan/icd.d/lvp_icd.json \
        --setenv WINEDEBUG -all \
        "$WINE64" "$@"
}

echo ">> Initializing WINEPREFIX at $WINEPREFIX ..."
mkdir -p "$WINEPREFIX"
run_wine wineboot.exe -u 2>&1 | tail -10

echo ">> Copying zlib1.dll to system32..."
cp "$PREFIX/usr/lib/x86_64-linux-gnu/wine/x86_64-windows/zlib1.dll" \
   "$WINEPREFIX/drive_c/windows/system32/" 2>/dev/null
ls -la "$WINEPREFIX/drive_c/windows/system32/zlib1.dll" 2>&1 | head -1

echo ">> Setting X11 graphics driver..."
run_wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /d x11 /f 2>&1 | tail -2

echo ">> Converting duplicate DLLs to symlinks (saves ~600MB)..."
bash "$SCRIPT_DIR/symlink-wineprefix.sh"

echo ""
echo "OK: WINEPREFIX ready at $WINEPREFIX"
echo ""
echo "=== Verification ==="
ls "$WINEPREFIX/drive_c/windows/system32/user32.dll" 2>&1 && echo "  OK: user32.dll"
ls "$WINEPREFIX/drive_c/windows/system32/zlib1.dll" 2>&1 && echo "  OK: zlib1.dll"
ls "$WINEPREFIX/drive_c/windows/system32/d3d9.dll" 2>&1 && echo "  OK: d3d9.dll"
grep -i "Graphics" "$WINEPREFIX/user.reg" 2>/dev/null | head -1
