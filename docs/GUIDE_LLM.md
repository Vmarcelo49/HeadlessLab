# Ultimate Guide: Running Windows DirectX 9 Applications Headless Without Sudo

> **For readers**: This is an operational guide for an LLM agent to execute Windows programs (specifically DirectX 9) in headless mode inside a Linux sandbox **without sudo**, **without Docker**, and **without physical GPU**.
>
> The guide has been empirically validated on Debian 13 (trixie) and should work on any recent Debian/Ubuntu system with kernel ≥ 5.10.

---

## 📋 Executive Summary

You will build an environment that:
1. Downloads `.deb` packages locally via `apt-get download` (no sudo needed)
2. Extracts them with `dpkg-deb -x` into a local prefix
3. Uses **Bubblewrap** to map paths without root privileges
4. Runs **Wine 10.0** inside the sandbox
5. Renders to **Xvfb** (virtual headless display)
6. Uses **Mesa llvmpipe** (software Vulkan/OpenGL) as the virtual GPU
7. Captures screenshots via **Python Xlib**

Result: A DirectX 9 `.exe` runs, renders a colored triangle to the virtual screen, and you can capture a screenshot of it.

---

## 🔍 Pre-flight Check: Verify the Sandbox Before Starting

Before doing anything, run this block and **paste the output into your response**. This tells you exactly what is already available and what needs to be downloaded.

```bash
echo "=== OS info ==="
uname -a
cat /etc/os-release 2>/dev/null | head -5

echo "=== User ==="
whoami
id
sudo -n true 2>&1 | head -1

echo "=== Basic Tools ==="
for cmd in apt-get dpkg-deb curl wget bash python3 Xvfb bwrap gcc g++; do
    if which $cmd > /dev/null 2>&1; then
        echo "  OK  $cmd -> $(which $cmd)"
    else
        echo "  MISSING $cmd"
    fi
done

echo "=== Host Libraries (LLVM, X11, Vulkan) ==="
for lib in libLLVM-19.so libX11.so.6 libvulkan.so.1; do
    if ls /usr/lib/x86_64-linux-gnu/$lib* > /dev/null 2>&1; then
        echo "  OK  $lib"
    else
        echo "  MISSING $lib"
    fi
done

echo "=== Python packages ==="
python3 -c "import Xlib; print('  OK  python-xlib')" 2>/dev/null || echo "  MISSING python-xlib"
python3 -c "from PIL import Image; print('  OK  Pillow')" 2>/dev/null || echo "  MISSING Pillow"

echo "=== Disk space ==="
df -h /home/z 2>/dev/null | head -2
```

### Interpreting the Results

- **If `bwrap` is MISSING**: You need to download `bubblewrap` via `apt-get download`. Proceed to Step 1.
- **If `Xvfb` is MISSING**: Download `xvfb`. Proceed to Step 1.
- **If `libLLVM-19.so` is MISSING**: Download `libllvm19` and its dependencies. **Or** use the GitHub bundle which already includes LLVM (see "Plan B" section).
- **If `python-xlib` or `Pillow` is MISSING**: Install via `pip install --user --break-system-packages python-xlib Pillow`.
- **If `apt-get` is MISSING**: You are on a non-Debian system. Use the precompiled GitHub bundle (Plan B).

---

## 📐 Architecture (Understand Before Executing)

```
┌────────────────────────────────────────────────────────────────────┐
│ Linux Sandbox (regular user, no sudo, /home/z/my-project/)         │
│                                                                    │
│  Program.exe (PE32+ x86-64)  ←─── you want to run this             │
│       │                                                            │
│       ▼                                                            │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Wine 10.0 (wine64)                                       │     │
│  │   • Loads PE .dlls from system32/                        │     │
│  │   • Loads unix-side .so files from x86_64-unix/          │     │
│  │   • d3d9.dll → wined3d.dll → OpenGL                      │     │
│  │   • winex11.drv → X11 protocol                          │     │
│  └──────────────────────────────────────────────────────────┘     │
│       │ (wrap with Bubblewrap for path remapping)                 │
│       ▼                                                            │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Bubblewrap container                                     │     │
│  │   • --bind rootfs/usr /usr  (symlinks to host)           │     │
│  │   • --ro-bind prefix/...wine /usr/lib/wine               │     │
│  │   • --proc /proc  (CRITICAL: wine needs /proc/self)      │     │
│  │   • --bind /tmp /tmp  (X11 socket)                       │     │
│  └──────────────────────────────────────────────────────────┘     │
│       │                                                            │
│       ▼                                                            │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Xvfb :99  (virtual display 1024x768x24, -ac no auth)     │     │
│  └──────────────────────────────────────────────────────────┘     │
│       │                                                            │
│       ▼                                                            │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Mesa llvmpipe (software rasterizer)                      │     │
│  │   • OpenGL via libGL + LLVM JIT                          │     │
│  │   • Vulkan via libvulkan_lvp.so (ICD = lvp_icd.json)     │     │
│  └──────────────────────────────────────────────────────────┘     │
│                                                                    │
│  Screenshot: Python + Xlib reads pixels from Xvfb root window      │
└────────────────────────────────────────────────────────────────────┘
```

### Why Bubblewrap Instead of PRoot?

- `proot` intercepts syscalls via `ptrace`, which interferes with wine (wine uses `ptrace` internally).
- `bwrap` uses user namespaces (cleaner and faster).
- **CRITICAL**: `bwrap` needs an explicit `--proc /proc`, otherwise `/proc/self/exe` is empty and wine fails to locate `ntdll.so`.

### Why Mesa LLVMpipe Instead of DXVK?

- DXVK requires a physical Vulkan-capable GPU (ICD).
- LLVMpipe is pure software rendering (CPU-bound) and works in any headless sandbox.
- Performance is low (~5-10 fps), but **sufficient for screenshots and functional validation**.

---

## 🚀 Execution — Two Options

You have two options. **Start with Option A (Plan B: GitHub bundle)** if you just want to run an application and the bundle already exists. Use **Option B (build from scratch)** if the bundle is not available or if you want to understand/debug the system.

### OPTION A — Plan B: Download Precompiled GitHub Bundle

> **Use this option if the GitHub repository already exists and you only need to run a `.exe`.**

```bash
# 1. Download the bundle (replace USER/REPO with the actual repo)
mkdir -p /home/z/my-project/headlesslab
cd /home/z/my-project/headlesslab

BUNDLE_URL="https://github.com/Vmarcelo49/HeadlessLab/releases/latest/download/HeadlessLab.AppImage"
curl -sSL "$BUNDLE_URL" -o bundle.tar.gz
tar xzf bundle.tar.gz
rm bundle.tar.gz

# 2. Expected structure inside the bundle:
#    headlesslab/
#    ├── bin/run.sh          (main entrypoint)
#    ├── bin/screenshot.py   (screen capture)
#    ├── prefix/             (wine + libs + mesa, ~190MB)
#    ├── rootfs/             (symlinks to host)
#    └── wineprefix-template/ (clean copy of WINEPREFIX)

# 3. Run an EXE
./bin/run.sh /path/to/your.exe

# 4. Screenshot (in another terminal while the EXE is running)
DISPLAY=:99 python3 bin/screenshot.py :99 /home/z/my-project/download/out.png
```

**Pros:**
- Complete setup takes ~30 seconds.
- Does not depend on `apt-get download` working.
- Size: ~80MB compressed.

**Cons:**
- Requires internet access to download.
- Will fail if the host lacks `libLLVM-19`, `libX11.so.6`, or `libvulkan.so.1` (requires installing via apt or using Option B).

---

### OPTION B — Build From Scratch (Fallback / Debugging)

> **Use this option if GitHub is inaccessible, or if you need to debug a prefix issue.**

Follow the **10 steps** below. Each step is a self-contained script block.

#### Step 1: Define Environment Variables

```bash
export SANDBOX_DIR="/home/z/my-project/sandbox"
export PREFIX="$SANDBOX_DIR/prefix"
export DOWNLOAD="$SANDBOX_DIR/download"
export ROOTFS="$SANDBOX_DIR/rootfs"
export WINEPREFIX="$SANDBOX_DIR/wineprefix"
export ZLIB_BUILD="$SANDBOX_DIR/zlib-build"
export DISPLAY=":99"

mkdir -p "$SANDBOX_DIR" "$PREFIX" "$DOWNLOAD" "$ROOTFS" "$ZLIB_BUILD" "$WINEPREFIX"
cd "$SANDBOX_DIR"
```

#### Step 2: Download All `.deb` Packages (No Sudo)

```bash
cd "$DOWNLOAD"

# List of required packages
PACKAGES=(
    # Wine core
    wine wine64 libwine fonts-wine
    # MinGW cross-compiler (only needed to compile the test .exe)
    binutils-mingw-w64-x86-64
    gcc-mingw-w64-x86-64-win32
    g++-mingw-w64-x86-64-win32
    gcc-mingw-w64-x86-64-win32-runtime
    gcc-mingw-w64-base
    mingw-w64-x86-64-dev mingw-w64-common
    # Bubblewrap (isolation without sudo)
    bubblewrap
    # Mesa Vulkan with llvmpipe (software rasterizer)
    mesa-vulkan-drivers
    # Mesa deps
    libllvm19 libdrm-amdgpu1 libdrm2 libdrm-intel1 libdrm-nouveau2 libdrm-radeon1
    libelf1t64 libexpat1 libwayland-client0 libx11-xcb1 libxcb-dri3-0
    libxcb-present0 libxcb-randr0 libxcb-sync1 libxcb-xfixes0 libxshmfence1
    libzstd1
    # proot and libtalloc2 (fallback)
    proot libtalloc2
)

for pkg in "${PACKAGES[@]}"; do
    echo "Downloading $pkg..."
    apt-get download "$pkg" 2>&1 | tail -1
done

ls -1 | wc -l  # Should show ~25 packages
```

#### Step 3: Extract All `.deb` Packages Into Prefix

```bash
cd "$SANDBOX_DIR"

for deb in "$DOWNLOAD"/*.deb; do
    # Some debs have ":" in the name (escaped as %3a). Rename them.
    if [[ "$deb" == *%* ]]; then
        cp "$deb" "${deb}.renamed"
        deb="${deb}.renamed"
    fi
    dpkg-deb -x "$deb" "$PREFIX" 2>/dev/null
done

# Verify extraction
ls "$PREFIX/usr/lib/wine/wine64" && echo "OK: wine64 extracted"
ls "$PREFIX/usr/bin/bwrap" && echo "OK: bwrap extracted"
ls "$PREFIX/usr/lib/x86_64-linux-gnu/libvulkan_lvp.so" && echo "OK: llvmpipe extracted"
```

#### Step 4: Patch Wine Wrappers (Hardcoded Paths)

The `wine` and `wineserver` scripts inside `prefix/usr/lib/wine/` point to `/usr/lib/wine/...` which does not exist. Replace them with custom wrappers:

```bash
# wineserver wrapper
cat > "$PREFIX/usr/lib/wine/wineserver" <<EOF
#!/bin/sh -e
exec $PREFIX/usr/lib/wine/wineserver64 -p0 "\$@"
EOF
chmod +x "$PREFIX/usr/lib/wine/wineserver"

# wine64 wrapper (preserves the real binary)
if [ ! -f "$PREFIX/usr/lib/wine/wine64.real" ]; then
    mv "$PREFIX/usr/lib/wine/wine64" "$PREFIX/usr/lib/wine/wine64.real"
fi
cat > "$PREFIX/usr/lib/wine/wine64" <<EOF
#!/bin/sh -e
export WINELOADER=$PREFIX/usr/lib/wine/wine64.real
exec $PREFIX/usr/lib/wine/wine64.real "\$@"
EOF
chmod +x "$PREFIX/usr/lib/wine/wine64"

echo "OK: wrappers patched"
```

#### Step 5: Create rootfs With Host Symlinks

Bubblewrap needs a rootfs. Since we cannot install system libraries globally, we create a rootfs containing symlinks to host directories, **except** where we override them (Wine directories).

```bash
mkdir -p "$ROOTFS/usr/lib" "$ROOTFS/usr/lib/x86_64-linux-gnu" \
         "$ROOTFS/usr/share" "$ROOTFS/usr/bin" "$ROOTFS/usr/sbin"

# Symlinks for /usr/lib/* (skipping wine)
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
mkdir -p "$ROOTFS/usr/lib/wine" "$ROOTFS/usr/lib/x86_64-linux-gnu/wine" "$ROOTFS/usr/share/wine"
mkdir -p "$ROOTFS/usr/share/vulkan"

echo "OK: rootfs created at $ROOTFS"
```

#### Step 6: Compile `zlib1.dll` (Required Since Debian Omits It)

Wine's `user32.dll` imports `zlib1.dll`, but Debian's `libwine` package does not bundle this DLL. We compile it from source:

```bash
cd "$ZLIB_BUILD"

# Download zlib 1.3.1 (GitHub release)
if [ ! -f zlib-1.3.1.tar.gz ]; then
    curl -sSL https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz -o zlib.tar.gz
fi
tar xzf zlib.tar.gz
cd zlib-1.3.1

# Compile with MinGW
export PATH="$PREFIX/usr/bin:$PATH"
for src in adler32.c crc32.c deflate.c inflate.c inftrees.c inffast.c zutil.c \
           trees.c gzclose.c gzlib.c gzread.c gzwrite.c compress.c uncompr.c; do
    [ -f "$src" ] && x86_64-w64-mingw32-gcc -O2 -DZLIB_DLL -DWINDOWS -c "$src" -o "${src%.c}.o"
done

x86_64-w64-mingw32-gcc -shared -o zlib1.dll \
    -Wl,--out-implib,libz.dll.a \
    adler32.o crc32.o deflate.o inflate.o inftrees.o inffast.o zutil.o trees.o \
    gzclose.o gzlib.o gzread.o gzwrite.o compress.o uncompr.o

# Copy to the Wine PE path
cp zlib1.dll "$PREFIX/usr/lib/x86_64-linux-gnu/wine/x86_64-windows/"

echo "OK: zlib1.dll compiled at $PREFIX/usr/lib/x86_64-linux-gnu/wine/x86_64-windows/zlib1.dll"
```

#### Step 7: Start Xvfb (Headless Virtual Display)

```bash
# Kill any stale Xvfb process
pkill -9 Xvfb 2>/dev/null || true
sleep 1
rm -rf /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null

# Start as a persistent daemon (setsid + disown)
setsid Xvfb :99 -screen 0 1024x768x24 -ac -nolisten tcp </dev/null >/tmp/xvfb.log 2>&1 &
disown
sleep 2

# Verify
if pgrep -f "Xvfb :99" > /dev/null; then
    echo "OK: Xvfb running (PID: $(pgrep -f 'Xvfb :99'))"
else
    echo "FAIL: Xvfb did not start. Log:"
    cat /tmp/xvfb.log
fi
```

**⚠️ IMPORTANT:** The `-ac` flag is mandatory. Without it, Xvfb enforces host access authentication, blocking Wine connections.

#### Step 8: Initialize WINEPREFIX

```bash
export BWRAP="$PREFIX/usr/bin/bwrap"
export WINE64="$PREFIX/usr/lib/wine/wine64"

# Helper function to run Wine inside bwrap
run_wine() {
    "$BWRAP" \
        --ro-bind /usr /host-usr \
        --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
        --ro-bind /bin /bin --ro-bind /sbin /sbin --ro-bind /etc /etc \
        --bind /tmp /tmp \
        --bind /home/z/my-project /home/z/my-project \
        --bind "$ROOTFS/usr" /usr \
        --ro-bind "$PREFIX/usr/lib/wine" /usr/lib/wine \
        --ro-bind "$PREFIX/usr/lib/x86_64-linux-gnu/wine" /usr/lib/x86_64-linux-gnu/wine \
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

# Initialize WINEPREFIX
run_wine wineboot.exe -u 2>&1 | tail -10

# Copy zlib1.dll to system32 (not done automatically by Wine)
cp "$PREFIX/usr/lib/x86_64-linux-gnu/wine/x86_64-windows/zlib1.dll" \
   "$WINEPREFIX/drive_c/windows/system32/" 2>/dev/null

# Force X11 graphics driver
run_wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /d x11 /f 2>&1 | tail -2

echo "OK: WINEPREFIX ready at $WINEPREFIX"
```

#### Step 9: Run the DX9 Program

```bash
# Replace with your EXE path
YOUR_EXE="/home/z/my-project/sandbox/dx9_test.exe"

# Run in background (to allow taking screenshots during execution)
nohup bash -c '
BWRAP="'"$PREFIX"'/usr/bin/bwrap"
WINE64="'"$PREFIX"'/usr/lib/wine/wine64"
"$BWRAP" \
    --ro-bind /usr /host-usr \
    --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
    --ro-bind /bin /bin --ro-bind /sbin /sbin --ro-bind /etc /etc \
    --bind /tmp /tmp \
    --bind /home/z/my-project /home/z/my-project \
    --bind "'"$ROOTFS"'"/usr /usr \
    --ro-bind "'"$PREFIX"'"/usr/lib/wine /usr/lib/wine \
    --ro-bind "'"$PREFIX"'"/usr/lib/x86_64-linux-gnu/wine /usr/lib/x86_64-linux-gnu/wine \
    --ro-bind "'"$PREFIX"'"/usr/share/wine /usr/share/wine \
    --ro-bind "'"$PREFIX"'"/usr/share/vulkan /usr/share/vulkan \
    --proc /proc \
    --dev /dev \
    --setenv DISPLAY :99 \
    --setenv WINEPREFIX "'"$WINEPREFIX"'" \
    --setenv LD_LIBRARY_PATH /usr/lib/x86_64-linux-gnu/wine/x86_64-unix:/usr/lib/x86_64-linux-gnu:/usr/lib \
    --setenv VK_ICD_FILENAMES /usr/share/vulkan/icd.d/lvp_icd.json \
    --setenv WINEDEBUG -all \
    "$WINE64" "'"$YOUR_EXE"'"
' > /tmp/wine_run.log 2>&1 &
disown
WINE_PID=$!

# Wait a few seconds for the program to initialize
sleep 4

echo "Wine PID: $WINE_PID"
ps -p $WINE_PID > /dev/null && echo "OK: running" || echo "FAIL: stopped"
```

#### Step 10: Capture Screenshot

```bash
# Create screenshot script
cat > /home/z/my-project/scripts/screenshot.py <<'PYEOF'
#!/usr/bin/env python3
"""Captures a screenshot of an X11 display using Xlib + Pillow."""
import sys, os

# Add common Python virtualenv paths
for p in ['/home/z/.venv/lib/python3.12/site-packages',
          '/home/z/.local/lib/python3.13/site-packages',
          os.path.expanduser('~/.local/lib/python3') + '.12/site-packages']:
    if os.path.isdir(p):
        sys.path.insert(0, p)

import ctypes
from Xlib import X, display
from PIL import Image

display_str = sys.argv[1] if len(sys.argv) > 1 else ':99'
out_path = sys.argv[2] if len(sys.argv) > 2 else '/tmp/screenshot.png'

d = display.Display(display_str)
root = d.screen().root
geom = root.get_geometry()
print(f'Root geometry: {geom.width}x{geom.height} depth={geom.depth}')

plane_mask = 0xFFFFFFFF
image = root.get_image(0, 0, geom.width, geom.height, X.ZPixmap, plane_mask)
print(f'Image data: {len(image.data)} bytes, depth={image.depth}')

if image.depth == 24:
    img = Image.frombytes('RGB', (geom.width, geom.height), image.data, 'raw', 'BGRX')
elif image.depth == 32:
    img = Image.frombytes('RGBA', (geom.width, geom.height), image.data, 'raw', 'BGRA')
elif image.depth == 16:
    img = Image.frombytes('RGB', (geom.width, geom.height), image.data, 'raw', 'BGR;16')
else:
    print(f'Unsupported depth: {image.depth}')
    sys.exit(1)

img.save(out_path)
print(f'Screenshot saved to {out_path}')
PYEOF

# Run screenshot
mkdir -p /home/z/my-project/download
python3 /home/z/my-project/scripts/screenshot.py :99 /home/z/my-project/download/screenshot.png

# Kill wine afterwards
pkill -9 -f 'wine64.*\.exe' 2>/dev/null
```

---

## 🐛 DEBUGGING — Common Problems and Solutions

### Issue: `wine: could not load ntdll.so: (null)`

**Cause:** Bubblewrap run without `--proc /proc`. Wine relies on `/proc/self/exe` to locate its shared object binaries.

**Solution:** Ensure the bwrap command includes `--proc /proc`:
```bash
... --proc /proc --dev /dev ...
```

### Issue: `Library zlib1.dll not found`

**Cause:** `zlib1.dll` is missing from the wineprefix system32 directory.

**Solution:** Copy it manually:
```bash
cp "$PREFIX/usr/lib/x86_64-linux-gnu/wine/x86_64-windows/zlib1.dll" \
   "$WINEPREFIX/drive_c/windows/system32/"
```

### Issue: `Application tried to create a window, but no driver could be loaded`

**Cause 1:** Xvfb is not running.
```bash
pgrep -f "Xvfb :99"  # Must return a PID
```

**Cause 2:** Wrong DISPLAY variable configured inside the bwrap.
```bash
# Check if the DISPLAY matches the Xvfb instance (e.g., :99)
echo $DISPLAY
```

**Cause 3:** X11 Unix socket is inaccessible. Ensure `--bind /tmp /tmp` is included in the bwrap command.

### Issue: `Initialization of winex11.drv failed`

**Cause:** Xvfb was started without the `-ac` flag (restricting access).

**Solution:** Restart Xvfb with the `-ac` flag:
```bash
pkill -9 Xvfb; sleep 1
setsid Xvfb :99 -screen 0 1024x768x24 -ac -nolisten tcp </dev/null >/tmp/xvfb.log 2>&1 &
disown
sleep 2
```

### Issue: DX9 `CreateDevice` returns S_OK but screenshot is blank

**Cause:** Culling, lighting, or z-buffer is hiding the rendered geometry.

**Solution:** In your DX9 program, set the following render states:
```cpp
g_device->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
g_device->SetRenderState(D3DRS_LIGHTING, FALSE);
g_device->SetRenderState(D3DRS_ALPHABLENDENABLE, FALSE);
g_device->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);
```

### Issue: Triangle renders with incorrect colors or pixelation

**Cause:** Mesa llvmpipe is failing to load, falling back to a dummy driver. Check the renderer log:
```bash
# The log should output "llvmpipe" as the active renderer
WINEDEBUG=+d3d ./bin/headless exec examples/dx9_triangle.exe 2>&1 | grep -i renderer
```

### Issue: Wine runs but `WINEDLLOVERRIDES=d3d9=native` breaks graphics

**Cause:** DXVK does not ship a PE version of `d3d9.dll`, only the unix-side `.so` library.

**Solution:** **DO NOT use DXVK**. Use Wine's built-in `d3d9.dll` + Mesa llvmpipe, which works perfectly for DX9 software rendering.

---

## 📊 POST-EXECUTION ANALYSIS

### Checking if Rendering Occurred

```python
from PIL import Image
img = Image.open('/home/z/my-project/download/screenshot.png')
colors = img.getcolors(maxcolors=1024*1024)
if colors:
    print(f'Unique colors: {len(colors)}')
    # If > 100 colors, rendering succeeded (gradient on the triangle)
    # If 1 or 2 colors, it rendered background/blank screen
    print(f'Top 5: {sorted(colors, reverse=True)[:5]}')
```

### Expected Clean Logs

```
=== DX9 Test Program ===
[OK] Window created HWND=... (800x600 client area)
[OK] Direct3DCreate9 succeeded. D3D pointer=...
[INFO] Adapter count: 1
  Adapter 0: NVIDIA GeForce GTX 470 (driver nvd3dum.dll, ...)
[OK] Direct3D device created. Device=..., hr=0x00000000
[OK] Vertex buffer created.
[OK] Setup complete. Entering message loop.
[INFO] First Clear hr=0x00000000
[INFO] BeginScene hr=0x00000000
[INFO] DrawPrimitive hr=0x00000000
[INFO] EndScene hr=0x00000000
[INFO] First Present hr=0x00000000
```

---

## ⚠️ KNOWN LIMITATIONS

1. **No 32-bit (x86)**: Standard Win32 (32-bit) programs will not run. Support requires adding i386 host architecture (`dpkg --add-architecture i386`), which requires root.
2. **Performance**: ~5-10 fps on llvmpipe software rendering. Unsuitable for real-time play, but perfect for headless test suites and screenshooting.
3. **No Audio**: Wine ALSA configuration is omitted.
4. **No DX10/DX11/DX12**: Limited strictly to DX9. Higher versions require DXVK and a physical Vulkan-capable GPU.

---

## 🎯 FINAL CHECKLIST

Verify these items before declaring completion:
- [ ] Xvfb is running: `pgrep -f "Xvfb :99"` returns a PID
- [ ] WINEPREFIX initialized: `ls $WINEPREFIX/drive_c/windows/system32/user32.dll` exists
- [ ] zlib1.dll present: `ls $WINEPREFIX/drive_c/windows/system32/zlib1.dll` exists
- [ ] Graphics driver set to x11: check `user.reg` contains `"Graphics"="x11"`
- [ ] Screenshot shows > 100 unique colors (rendering occurred)
