#!/bin/bash
# rebuild-rootfs.sh — creates rootfs/ containing symlinks to the host.
# Required when the bundle changes host machines (symlinks point to host paths).
#
# Bubblewrap mounts this rootfs at /usr inside the sandbox. The symlinks in
# rootfs/usr/lib/* point to /host-usr/lib/* (mapped via bwrap's --ro-bind /usr /host-usr).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")"
ROOTFS="$BUNDLE_DIR/rootfs"

echo "Rebuilding rootfs at $ROOTFS ..."
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS/usr/lib" "$ROOTFS/usr/lib/x86_64-linux-gnu" \
         "$ROOTFS/usr/share" "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin"

# Symlinks for /usr/lib/* (skipping wine and x86_64-linux-gnu which contains wine)
for item in /usr/lib/*; do
    name=$(basename "$item")
    [ "$name" = "wine" ] && continue
    [ "$name" = "x86_64-linux-gnu" ] && continue
    ln -sf "/host-usr/lib/$name" "$ROOTFS/usr/lib/$name"
done

# Symlinks for /usr/lib/x86_64-linux-gnu/* (skipping wine)
for item in /usr/lib/x86_64-linux-gnu/*; do
    name=$(basename "$item")
    [ "$name" = "wine" ] && continue
    ln -sf "/host-usr/lib/x86_64-linux-gnu/$name" "$ROOTFS/usr/lib/x86_64-linux-gnu/$name"
done

# Symlinks for /usr/share/* (skipping wine and vulkan)
for item in /usr/share/*; do
    name=$(basename "$item")
    [ "$name" = "wine" ] && continue
    [ "$name" = "vulkan" ] && continue
    ln -sf "/host-usr/share/$name" "$ROOTFS/usr/share/$name"
done

# Symlinks for /usr/bin/* and /usr/sbin/*
for item in /usr/bin/*; do
    ln -sf "/host-usr/bin/$(basename "$item")" "$ROOTFS/usr/bin/$(basename "$item")"
done
for item in /usr/sbin/*; do
    ln -sf "/host-usr/sbin/$(basename "$item")" "$ROOTFS/usr/sbin/$(basename "$item")"
done

# Base directories of rootfs (symlinks to host)
for d in bin sbin lib lib64 etc; do
    rm -rf "$ROOTFS/$d"
    ln -sf "/host-$d" "$ROOTFS/$d"
done

# Create empty directories to be bind-mounted (bwrap populates them)
mkdir -p "$ROOTFS/usr/lib/wine" "$ROOTFS/usr/lib/x86_64-linux-gnu/wine" "$ROOTFS/usr/lib/i386-linux-gnu/wine" "$ROOTFS/usr/share/wine"
mkdir -p "$ROOTFS/usr/share/vulkan"

echo "OK: rootfs created at $ROOTFS"
echo "Total symlinks: $(find "$ROOTFS" -type l | wc -l)"
