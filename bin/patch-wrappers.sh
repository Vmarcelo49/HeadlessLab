#!/bin/bash
# patch-wrappers.sh — patches wine wrappers (wine64, wineserver) to use
# relative paths (auto-locate), allowing the bundle to work in any directory.
#
# Usage: patch-wrappers.sh [PREFIX_DIR]
#   PREFIX_DIR default: <bundle>/prefix
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"
PREFIX="${1:-$BUNDLE_DIR/prefix}"

if [ ! -d "$PREFIX/usr/lib/wine" ]; then
    echo "FAIL: $PREFIX/usr/lib/wine does not exist" >&2
    exit 1
fi

# Wrapper wineserver - auto-locate
cat > "$PREFIX/usr/lib/wine/wineserver" <<'EOF'
#!/bin/sh -e
# Auto-locate: this script is in <bundle>/prefix/usr/lib/wine/
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SELF_DIR/wineserver64" -p0 "$@"
EOF
chmod +x "$PREFIX/usr/lib/wine/wineserver"

# Wrapper wine64 (preserves the real binary)
if [ ! -f "$PREFIX/usr/lib/wine/wine64.real" ]; then
    mv "$PREFIX/usr/lib/wine/wine64" "$PREFIX/usr/lib/wine/wine64.real"
fi
cat > "$PREFIX/usr/lib/wine/wine64" <<'EOF'
#!/bin/sh -e
# Auto-locate: this script is in <bundle>/prefix/usr/lib/wine/
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
export WINELOADER="$SELF_DIR/wine64.real"
exec "$SELF_DIR/wine64.real" "$@"
EOF
chmod +x "$PREFIX/usr/lib/wine/wine64"

echo "OK: wrappers patched (auto-locate)"
