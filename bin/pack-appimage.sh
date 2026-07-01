#!/bin/bash
# pack-appimage.sh — packages prefix/ + scripts + examples into a 100% standalone AppImage.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"
PREFIX="$BUNDLE_DIR/prefix"
APPDIR="$BUNDLE_DIR/AppDir"
OUT_FILE="$BUNDLE_DIR/HeadlessLab.AppImage"

# Colors
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
ok()   { echo "${G}[OK]${N} $*"; }
warn() { echo "${Y}[WARN]${N} $*"; }
fail() { echo "${R}[FAIL]${N} $*" >&2; }

echo "=== Packaging HeadlessLab as Standalone AppImage ==="
echo "Source prefix: $PREFIX"
echo "Output file:   $OUT_FILE"
echo ""

if [ ! -d "$PREFIX" ]; then
    fail "Directory $PREFIX does not exist. Please run './bin/setup.sh' first."
    exit 1
fi

# Clean up old build structures
rm -rf "$APPDIR"
rm -f "$OUT_FILE"

# 1. Create AppDir and copy prefix contents
# Wine 11 (WineHQ) uses /opt/wine-devel/ layout — copy the entire prefix
echo ">> Copying prefix to AppDir..."
mkdir -p "$APPDIR"
cp -rp "$PREFIX/"* "$APPDIR/"

# 2. Copy examples and required binaries into the AppImage
echo ">> Copying control scripts and examples to AppDir..."
mkdir -p "$APPDIR/examples"
cp -rp "$BUNDLE_DIR/examples/"* "$APPDIR/examples/"
mkdir -p "$APPDIR/bin"
[ -f "$BUNDLE_DIR/bin/screenshot.py" ] && cp -p "$BUNDLE_DIR/bin/screenshot.py" "$APPDIR/bin/" || true

# 3. Copy the headless CLI as the AppImage AppRun entrypoint
echo ">> Installing headless CLI as AppRun..."
cp "$BUNDLE_DIR/bin/headless" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"

# 4. Create desktop file and icon metadata
echo ">> Creating AppImage metadata (.desktop and icon)..."
cat > "$APPDIR/headlesslab.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=HeadlessLab
Exec=AppRun
Icon=headlesslab
Categories=Utility;
EOF

# Copy placeholder icon (uses the repository example screenshot if available)
if [ -f "$BUNDLE_DIR/examples/example_screenshot.png" ]; then
    cp "$BUNDLE_DIR/examples/example_screenshot.png" "$APPDIR/headlesslab.png"
else
    touch "$APPDIR/headlesslab.png"
fi

# 5. Fetch appimagetool if not present
APPIMAGETOOL="$BUNDLE_DIR/bin/appimagetool"
if [ ! -f "$APPIMAGETOOL" ]; then
    echo ">> Downloading appimagetool..."
    curl -L -sS "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage" -o "$APPIMAGETOOL"
    chmod +x "$APPIMAGETOOL"
fi

# 6. Compile the AppImage
echo ">> Compiling AppImage..."
export ARCH=x86_64

if ! "$APPIMAGETOOL" "$APPDIR" "$OUT_FILE"; then
    warn "Failed to run appimagetool directly (possibly missing FUSE). Trying via extraction..."
    cd "$BUNDLE_DIR/bin"
    ./appimagetool --appimage-extract > /dev/null
    ./squashfs-root/AppRun "$APPDIR" "$OUT_FILE"
    rm -rf squashfs-root
    cd "$BUNDLE_DIR"
fi

# 7. Clean up
echo ">> Cleaning up temporary files..."
rm -rf "$APPDIR"

echo ""
ok "100% standalone AppImage created successfully!"
ls -lh "$OUT_FILE"
echo ""
echo "You can run it directly as: ./HeadlessLab.AppImage /path/to/app.exe"
echo "Or run integrated verification checks with: ./HeadlessLab.AppImage --verify"
