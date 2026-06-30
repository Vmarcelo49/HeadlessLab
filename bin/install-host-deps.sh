#!/bin/bash
# install-host-deps.sh — extracts the bundled .deb packages in host-debs/ into
# ~/.local/ without requiring sudo. Useful for LLM sandboxes, CI runners, and
# any environment where you cannot apt-install system-wide.
#
# After running, you MUST source the env file to make the tools discoverable:
#     source ~/.local/share/headlesslab/env.sh
#
# Or add these lines to your ~/.bashrc:
#     export PATH="$HOME/.local/usr/bin:$PATH"
#     export LD_LIBRARY_PATH="$HOME/.local/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
#     export XDG_DATA_DIRS="$HOME/.local/usr/share:/usr/share:/usr/local/share"
#     export PYTHONPATH="$HOME/.local/usr/lib/python3/dist-packages:$PYTHONPATH"
#
# Idempotent: re-running is safe; existing files are overwritten.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"
DEB_DIR="$BUNDLE_DIR/host-debs"
TARGET="$HOME/.local"
ENV_FILE="$HOME/.local/share/headlesslab/env.sh"

# Colors
G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
ok()   { echo "${G}[OK]${N} $*"; }
warn() { echo "${Y}[WARN]${N} $*"; }
fail() { echo "${R}[FAIL]${N} $*" >&2; }

if [ ! -d "$DEB_DIR" ]; then
    fail "host-debs/ not found at $DEB_DIR"
    fail "This script must be run from a clone of the HeadlessLab repository."
    exit 1
fi

DEB_COUNT=$(ls -1 "$DEB_DIR"/*.deb 2>/dev/null | wc -l)
if [ "$DEB_COUNT" -eq 0 ]; then
    fail "No .deb files in $DEB_DIR"
    exit 1
fi

echo "=== HeadlessLab — Host Dependencies Installer ==="
echo "Source:  $DEB_DIR ($DEB_COUNT packages)"
echo "Target:  $TARGET"
echo ""

mkdir -p "$TARGET"

# Extract all .deb packages
echo ">> Extracting packages..."
EXTRACTED=0
SKIPPED=0
for deb in "$DEB_DIR"/*.deb; do
    name=$(basename "$deb" .deb)
    if dpkg-deb -x "$deb" "$TARGET" 2>/dev/null; then
        EXTRACTED=$((EXTRACTED + 1))
    else
        warn "  failed to extract $name"
        SKIPPED=$((SKIPPED + 1))
    fi
done
ok "Extracted $EXTRACTED packages ($SKIPPED skipped)"

# Create symlinks for ImageMagick's 'magick' binary so 'import' and 'convert' work
# (imagemagick-7.q16 ships only 'magick-im7.q16'; the wrappers below provide
#  the legacy 'import', 'convert', 'identify' command names that the headless
#  CLI and many tutorials expect.)
echo ""
echo ">> Creating ImageMagick command symlinks..."
MAGICK_BIN="$TARGET/usr/bin/magick-im7.q16"
if [ -x "$MAGICK_BIN" ]; then
    for cmd in magick import convert identify animate compare composite conjure display montage stream; do
        ln -sf magick-im7.q16 "$TARGET/usr/bin/$cmd"
    done
    ok "ImageMagick wrappers created (import, convert, identify, ...)"
else
    warn "magick-im7.q16 not found — ImageMagick wrappers skipped"
fi

# Install python-xlib and Pillow into the user's site-packages if not already there
# (python3-xlib .deb installs into /usr/lib/python3/dist-packages which we just
# extracted to ~/.local/usr/lib/python3/dist-packages — but Python won't find it
# there unless we add it to PYTHONPATH. The env file below handles that.)
echo ""
echo ">> Verifying Python modules are reachable..."
if PYTHONPATH="$TARGET/usr/lib/python3/dist-packages:$PYTHONPATH" \
   python3 -c "import Xlib; print('  python-xlib OK')" 2>/dev/null; then
    ok "python-xlib reachable"
else
    warn "python-xlib not reachable — check PYTHONPATH after sourcing env.sh"
fi

if PYTHONPATH="$TARGET/usr/lib/python3/dist-packages:$PYTHONPATH" \
   python3 -c "from PIL import Image; print('  Pillow OK')" 2>/dev/null; then
    ok "Pillow reachable (already installed system-wide)"
else
    warn "Pillow not reachable — install it via: pip install --user --break-system-packages Pillow"
fi

# Write the env file
echo ""
echo ">> Writing env file to $ENV_FILE ..."
mkdir -p "$(dirname "$ENV_FILE")"
cat > "$ENV_FILE" << 'EOF'
# HeadlessLab — host dependencies environment
# Source this file (or add to ~/.bashrc) to make the bundled host tools
# (openbox, xdotool, wmctrl, xprop, xclip, import, ...) discoverable.
export PATH="$HOME/.local/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/usr/lib/x86_64-linux-gnu:$HOME/.local/usr/lib:${LD_LIBRARY_PATH:-}"
export XDG_DATA_DIRS="$HOME/.local/usr/share:/usr/share:/usr/local/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
export PYTHONPATH="$HOME/.local/usr/lib/python3/dist-packages${PYTHONPATH:+:$PYTHONPATH}"
EOF
ok "Env file written"
echo ""
echo "  To activate now:        source $ENV_FILE"
echo "  To activate permanently: cat $ENV_FILE >> ~/.bashrc"

# Verify a few key binaries are now on PATH (after sourcing the env file)
echo ""
echo ">> Verifying binaries..."
source "$ENV_FILE"
for cmd in Xvfb openbox xdotool wmctrl xprop xclip import; do
    if which $cmd > /dev/null 2>&1; then
        ok "$cmd -> $(which $cmd)"
    else
        # Xvfb is a host dep we DON'T bundle (it requires kernel DRM/KMS)
        # — for the others, this is a real failure
        if [ "$cmd" = "Xvfb" ]; then
            warn "$cmd not bundled — install via: apt-get install xvfb (requires sudo)"
        else
            fail "$cmd still not found on PATH after install"
        fi
    fi
done

echo ""
ok "Done! Host deps installed to $TARGET"
echo ""
echo "NOTE: Xvfb is NOT bundled (it needs kernel access). Install it via:"
echo "    sudo apt-get install -y xvfb"
echo "  Or, if you cannot use sudo, contact your admin to enable Xvfb on the host."
