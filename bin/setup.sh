#!/bin/bash
# setup.sh — prepares the environment when the bundle is first used.
#
# What it does:
#   1. Verifies host dependencies (libX11, libvulkan, python-xlib)
#   2. Downloads and extracts the AppImage bundle from the release (or uses local if present)
#   3. Rebuilds rootfs/ with symlinks to the host
#   4. Initializes WINEPREFIX if it doesn't exist (runs wineboot)
#   5. Copies zlib1.dll to system32 (if missing)
#   6. Performs final sanity check
#
# Usage:
#   ./bin/setup.sh              # full setup (downloads/extracts bundle if missing)
#   ./bin/setup.sh --check      # check only, does not modify anything
#   ./bin/setup.sh --rebuild    # force rebuild of rootfs + wineprefix
#   ./bin/setup.sh --download   # force download and extraction of the release bundle
#

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"
PREFIX="$BUNDLE_DIR/prefix"
ROOTFS="$BUNDLE_DIR/rootfs"
WINEPREFIX_DEFAULT="$BUNDLE_DIR/wineprefix"
export WINEPREFIX="${WINEPREFIX:-$WINEPREFIX_DEFAULT}"

# AppImage URL on GitHub Release (update USER/repo after publishing the first release)
BUNDLE_URL="${HEADLESSLAB_BUNDLE_URL:-https://github.com/Vmarcelo49/HeadlessLab/releases/latest/download/HeadlessLab.AppImage}"

MODE="setup"
if [ "$1" = "--check" ]; then MODE="check"; fi
if [ "$1" = "--rebuild" ]; then MODE="rebuild"; fi
if [ "$1" = "--download" ]; then MODE="download"; fi

# === Colors ===
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
ok()   { echo "${G}[OK]${N} $*"; }
warn() { echo "${Y}[WARN]${N} $*"; }
fail() { echo "${R}[FAIL]${N} $*" >&2; }

echo "=== HeadlessLab — Setup ==="
echo "Bundle dir: $BUNDLE_DIR"
echo "Mode: $MODE"
echo ""

# === 1. Verify host dependencies ===
echo "=== 1. Checking host ==="
ALL_OK=1

# Tools — full list (was missing xprop, xclip, imagemagick in the original)
for cmd in bash python3 tar Xvfb openbox xdotool wmctrl xprop xclip import; do
    if which $cmd > /dev/null 2>&1; then
        ok "$cmd -> $(which $cmd)"
    else
        case "$cmd" in
            import)
                warn "$cmd not found on host — headless will fall back to python-xlib for screenshots"
                ;;
            xprop|xclip)
                fail "$cmd not found on host — install with: apt install x11-utils xclip (requires sudo)"
                ALL_OK=0
                ;;
            *)
                fail "$cmd not found on host — install with: apt install openbox xdotool wmctrl (requires sudo)"
                ALL_OK=0
                ;;
        esac
    fi
done

# Critical host libraries (the bundle does NOT include these)
for lib in libX11.so.6 libvulkan.so.1; do
    if ls /usr/lib/x86_64-linux-gnu/$lib* > /dev/null 2>&1; then
        ok "host lib $lib"
    else
        fail "host lib $lib MISSING — install on host: apt install libx11-6 libvulkan1 (requires sudo)"
        ALL_OK=0
    fi
done

# Python deps (installable without sudo)
if python3 -c "import Xlib" 2>/dev/null; then
    ok "python-xlib"
else
    warn "python-xlib MISSING — attempting to install..."
    pip install --user --break-system-packages python-xlib 2>/dev/null || \
    python3 -m pip install python-xlib 2>/dev/null || true
    if python3 -c "import Xlib" 2>/dev/null; then ok "python-xlib (installed)"; else
        warn "python-xlib — required for screenshot fallback when 'import' is unavailable"
        ALL_OK=0
    fi
fi

if python3 -c "from PIL import Image" 2>/dev/null; then
    ok "Pillow"
else
    warn "Pillow MISSING — attempting to install..."
    pip install --user --break-system-packages Pillow 2>/dev/null || \
    python3 -m pip install Pillow 2>/dev/null || true
    if python3 -c "from PIL import Image" 2>/dev/null; then ok "Pillow (installed)"; else fail "Pillow"; ALL_OK=0; fi
fi

if [ "$MODE" = "check" ] && [ $ALL_OK = 0 ]; then
    fail "Host prerequisites not met."
    exit 1
fi

# === 1.5. Download and extract the bundle (AppImage) if necessary ===
if [ "$MODE" = "download" ] || [ ! -d "$PREFIX/opt/wine-devel" ]; then
    echo ""
    echo "=== 1.5. Downloading/Extracting AppImage bundle ==="
    
    # Try to download the AppImage. If no URL is configured but we have a local
    # AppImage, use that instead.
    if [ -z "$HEADLESSLAB_BUNDLE_URL" ]; then
        # If no URL is configured but we have local AppImage, use it!
        if [ -f "$BUNDLE_DIR/HeadlessLab.AppImage" ]; then
            ok "HeadlessLab.AppImage found locally at $BUNDLE_DIR"
            TMP_APPIMAGE="$BUNDLE_DIR/HeadlessLab.AppImage"
            LOCAL_MODE=1
        elif [ -f "$(dirname "$BUNDLE_DIR")/HeadlessLab.AppImage" ]; then
            ok "HeadlessLab.AppImage found at $(dirname "$BUNDLE_DIR")"
            TMP_APPIMAGE="$(dirname "$BUNDLE_DIR")/HeadlessLab.AppImage"
            LOCAL_MODE=1
        else
            fail "No bundle URL configured and no local HeadlessLab.AppImage found."
            fail "To fix this, do ONE of the following:"
            fail "  1. Set HEADLESSLAB_BUNDLE_URL env var: export HEADLESSLAB_BUNDLE_URL=https://github.com/Vmarcelo49/HeadlessLab/releases/download/v1.0.0/HeadlessLab.AppImage"
            fail "  2. Place HeadlessLab.AppImage in the bundle directory"
            fail "  3. Run bin/build-from-scratch.sh to build the prefix locally"
            exit 1
        fi
    else
        echo ">> Downloading from $BUNDLE_URL..."
        TMP_APPIMAGE="/tmp/headlesslab-$$.AppImage"
        if ! curl -fSL "$BUNDLE_URL" -o "$TMP_APPIMAGE"; then
            fail "Download failed. Check URL or download manually."
            rm -f "$TMP_APPIMAGE"
            exit 1
        fi
        LOCAL_MODE=0
    fi

    chmod +x "$TMP_APPIMAGE"
    echo ">> Extracting AppImage..."
    cd "$BUNDLE_DIR"
    
    # Remove old prefix to avoid clutter
    rm -rf prefix
    
    # Perform extraction
    if ! "$TMP_APPIMAGE" --appimage-extract > /dev/null; then
        fail "AppImage extraction failed."
        [ "$LOCAL_MODE" = "0" ] && rm -f "$TMP_APPIMAGE"
        exit 1
    fi
    
    mv squashfs-root prefix
    [ "$LOCAL_MODE" = "0" ] && rm -f "$TMP_APPIMAGE"
    ok "AppImage bundle extracted successfully!"
fi

# === 1.8. Verify internal prefix structure ===
echo ""
echo "=== 1.8. Checking prefix structure ==="
BUNDLE_OK=1
for d in prefix/usr/bin/bwrap prefix/opt/wine-devel/bin/wine prefix/opt/wine-devel/lib/wine/x86_64-windows/zlib1.dll; do
    if [ -e "$BUNDLE_DIR/$d" ]; then
        ok "bundle: $d"
    else
        fail "bundle: $d MISSING"
        BUNDLE_OK=0
    fi
done

if [ "$MODE" = "check" ]; then
    echo ""
    if [ $ALL_OK = 1 ] && [ $BUNDLE_OK = 1 ]; then ok "Everything OK"; exit 0; else exit 1; fi
fi

if [ $ALL_OK = 0 ] || [ $BUNDLE_OK = 0 ]; then
    fail "Prerequisites or bundle integrity check failed."
    exit 1
fi

# === 2. Rebuild rootfs if needed ===
if [ "$MODE" = "rebuild" ] || [ ! -d "$ROOTFS/usr/lib" ] || [ -z "$(ls -A "$ROOTFS/usr/lib" 2>/dev/null)" ]; then
    echo ""
    echo "=== 2. Rebuilding rootfs ==="
    bash "$SCRIPT_DIR/rebuild-rootfs.sh"
else
    ok "rootfs already exists (use --rebuild to force)"
fi

# === 3. Initialize WINEPREFIX if needed ===
if [ "$MODE" = "rebuild" ] || [ ! -d "$WINEPREFIX/drive_c/windows/system32" ]; then
    echo ""
    echo "=== 3. Initializing WINEPREFIX ==="
    bash "$SCRIPT_DIR/init-wineprefix.sh"
else
    ok "WINEPREFIX already exists at $WINEPREFIX (use --rebuild to force)"
fi

# === 4. Final verification ===
echo ""
echo "=== 4. Final verification ==="
CRIT_OK=1
pgrep -f "Xvfb" > /dev/null && ok "Xvfb running" || warn "Xvfb is not running (will start on first run)"
[ -f "$WINEPREFIX/drive_c/windows/system32/zlib1.dll" ] && ok "zlib1.dll in system32" || (fail "zlib1.dll MISSING"; CRIT_OK=0)
[ -f "$WINEPREFIX/drive_c/windows/system32/d3d9.dll" ] && ok "d3d9.dll in system32" || (fail "d3d9.dll MISSING"; CRIT_OK=0)
[ -f "$WINEPREFIX/drive_c/windows/system32/user32.dll" ] && ok "user32.dll in system32" || (fail "user32.dll MISSING"; CRIT_OK=0)
grep -q '"Graphics"="x11"' "$WINEPREFIX/user.reg" 2>/dev/null && ok "Graphics driver = x11" || warn "Graphics driver not set to x11"

echo ""
if [ $CRIT_OK = 1 ]; then
    ok "Setup complete! Ready to run DX9 .exe."
    echo ""
    echo "To test:"
    echo "  $BUNDLE_DIR/bin/headless --verify"
    echo ""
    echo "To run your own exe:"
    echo "  $BUNDLE_DIR/bin/headless init"
    echo "  $BUNDLE_DIR/bin/headless exec /path/to/program.exe"
    echo "  $BUNDLE_DIR/bin/headless wait-window <session_id>"
    echo "  $BUNDLE_DIR/bin/headless screenshot --session <session_id> --out /tmp/capture.png"
    echo "  $BUNDLE_DIR/bin/headless kill <session_id>"
else
    fail "Setup incomplete. See error messages above."
    exit 1
fi
