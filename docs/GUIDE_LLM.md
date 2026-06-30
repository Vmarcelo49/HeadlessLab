# HeadlessLab — Operational Guide for LLM Agents

> **For LLM agents**: This guide teaches you how to run Windows applications (DirectX 9, console, GUI) headless on Linux using the `headless` CLI. You will learn how to install the runtime, execute Windows `.exe` files, capture screenshots, simulate input, and debug common problems — all **without sudo**, **without Docker**, and **without a physical GPU**.
>
> Validated on Debian 13 (trixie). Should work on any recent Debian/Ubuntu system with kernel ≥ 5.10.

---

## 📋 Executive Summary

HeadlessLab provides a single CLI tool (`headless`) that:

1. Starts a **virtual X11 display** (Xvfb + Openbox) — no monitor needed
2. Executes **Windows `.exe` files** via **Wine 10.0** inside a **Bubblewrap** sandbox (no root)
3. Renders **DirectX 9** graphics via **Mesa llvmpipe** (software rasterizer, CPU-only — no GPU)
4. Captures **screenshots** and simulates **mouse/keyboard input**
5. Returns **JSON output** for every command — trivially parseable by LLM agents

Supports both **64-bit** (PE32+ x86-64) and **32-bit** (PE32 i386) Windows binaries via Wine's WoW64 mode.

---

## 🚀 Getting Started

### Option A — AppImage (recommended, no compilation)

Download the pre-built AppImage (~454MB, includes Wine 10 + Mesa + 32-bit support + the `headless` CLI):

```bash
# 1. Clone the repo and install host tools (one-time, ~10MB)
git clone https://github.com/Vmarcelo49/HeadlessLab.git
cd HeadlessLab
bash bin/install-host-deps.sh
source ~/.local/share/headlesslab/env.sh

# 2. Install Xvfb (requires sudo — it's the only host dep that needs kernel access)
sudo apt-get install -y xvfb

# 3. Download the AppImage
curl -sSL -o HeadlessLab.AppImage \
  https://github.com/Vmarcelo49/HeadlessLab/releases/latest/download/HeadlessLab.AppImage
chmod +x HeadlessLab.AppImage

# 4. Verify everything works
./HeadlessLab.AppImage --verify
```

**Environments without FUSE** (Docker, LLM sandboxes, CI):

```bash
# Pre-extract once (~870MB on disk)
./HeadlessLab.AppImage --appimage-extract
cd squashfs-root
export APPDIR="$PWD"

# Use ./AppRun instead of ./HeadlessLab.AppImage
./AppRun --verify
./AppRun init
./AppRun exec /path/to/app.exe
```

### Option B — Build from source

```bash
git clone https://github.com/Vmarcelo49/HeadlessLab.git
cd HeadlessLab
bash bin/install-host-deps.sh
source ~/.local/share/headlesslab/env.sh
sudo apt-get install -y xvfb  # only host dep requiring sudo
bash bin/build-from-scratch.sh
bash bin/setup-32bit.sh  # optional: adds 32-bit support
./bin/headless --verify
```

---

## 🔍 Pre-flight Check

Before starting, run this diagnostic block to see what's available on the host:

```bash
echo "=== OS info ==="
uname -a
cat /etc/os-release 2>/dev/null | head -3

echo "=== User ==="
whoami
sudo -n true 2>&1 | head -1

echo "=== Required tools ==="
for cmd in bash python3 Xvfb openbox xdotool wmctrl xprop xclip; do
    if which $cmd > /dev/null 2>&1; then
        echo "  OK  $cmd -> $(which $cmd)"
    else
        echo "  MISSING $cmd"
    fi
done

echo "=== Screenshot tools ==="
which import 2>/dev/null && echo "  OK  ImageMagick import" || echo "  MISSING import (will fall back to python-xlib)"
python3 -c "import Xlib; print('  OK  python-xlib')" 2>/dev/null || echo "  MISSING python-xlib"
python3 -c "from PIL import Image; print('  OK  Pillow')" 2>/dev/null || echo "  MISSING Pillow"

echo "=== Host libraries ==="
for lib in libX11.so.6 libvulkan.so.1; do
    ls /usr/lib/x86_64-linux-gnu/$lib* > /dev/null 2>&1 && echo "  OK  $lib" || echo "  MISSING $lib"
done

echo "=== Disk space ==="
df -h /home/z 2>/dev/null | head -2
```

**Interpreting results:**
- If `Xvfb` is MISSING: install with `sudo apt-get install -y xvfb` (requires sudo)
- If `openbox`/`xdotool`/`wmctrl`/`xprop`/`xclip` are MISSING: run `bash bin/install-host-deps.sh` (no sudo)
- If `import` is MISSING: `headless screenshot` will fall back to python-xlib automatically
- If `python-xlib` or `Pillow` is MISSING: install via `pip install --user python-xlib Pillow`

---

## 📐 Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│ Linux user space (no sudo, no Docker)                              │
│                                                                    │
│  app.exe (PE32/PE32+)  ←─── you want to run this                  │
│       │                                                            │
│       ▼                                                            │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Wine 10.0 (wine64 / wine via WoW64)                      │     │
│  │   • Loads PE .dlls from system32/ (64-bit) or syswow64/  │     │
│  │   • d3d9.dll → wined3d.dll → OpenGL                      │     │
│  │   • winex11.drv → X11 protocol                          │     │
│  └──────────────────────────────────────────────────────────┘     │
│       │ (Bubblewrap sandbox for path remapping)                    │
│       ▼                                                            │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Bubblewrap container (user namespaces, no root)          │     │
│  │   • --bind rootfs/usr /usr  (symlinks to host)           │     │
│  │   • --ro-bind prefix/...wine /usr/lib/wine               │     │
│  │   • --proc /proc  (CRITICAL: wine needs /proc/self)      │     │
│  └──────────────────────────────────────────────────────────┘     │
│       │                                                            │
│       ▼                                                            │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Xvfb :99  (virtual display 1920x1080x24, -ac no auth)    │     │
│  └──────────────────────────────────────────────────────────┘     │
│       │                                                            │
│       ▼                                                            │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │ Mesa llvmpipe (software rasterizer, CPU-only)            │     │
│  │   • OpenGL via libGL + LLVM JIT                          │     │
│  │   • Vulkan via libvulkan_lvp.so                          │     │
│  └──────────────────────────────────────────────────────────┘     │
│                                                                    │
│  Screenshot: 'import' (ImageMagick) or python-xlib + Pillow        │
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

### How 32-bit WoW64 Works (Without sudo)

Debian's `wine64` package alone does NOT populate `syswow64/` (the 32-bit DLL directory). The traditional approach requires `dpkg --add-architecture i386` (root). HeadlessLab works around this by:

1. Downloading `wine32:i386`, `libwine:i386`, and `libc6:i386` directly from the Debian pool (no `dpkg --add-architecture` needed)
2. Patching the 32-bit `wine` binary's ELF interpreter to `/usr/lib/ld-linux.so.2` (using `patchelf`) so it can run inside the bwrap sandbox without needing `/lib/ld-linux.so.2` on the host
3. Manually populating `syswow64/` with symlinks to the `i386-windows/` DLLs after `wineboot`
4. Adding `--ro-bind` entries for `ld-linux.so.2` and `i386-linux-gnu/` in the bwrap command

The `headless` CLI auto-detects the PE architecture (by reading the COFF `Machine` field) and reports it as `"arch": "i386"` or `"arch": "x86_64"` in the `exec` JSON response.

---

## 🎯 CLI Reference for LLM Agents

Run `headless --help` for the full reference. Here are the key workflows:

### Workflow 1: Run a Windows .exe and capture a screenshot (the 80% case)

```bash
# 1. Start the virtual display
headless init
# → {"status": "ok", "display": ":99", "geometry": "1920x1080x24"}

# 2. Execute the .exe (returns session_id)
headless exec /path/to/app.exe
# → {"status": "ok", "session_id": "sess_123", "pid": 987, "arch": "x86_64"}

# 3. Wait for the window to appear and pixels to stabilize
headless wait-window sess_123
# → {"status": "ok", "elapsed_ms": 480}

# 4. Capture a screenshot
headless screenshot --session sess_123 --out /tmp/capture.png
# → {"status": "ok", "path": "/tmp/capture.png"}

# 5. Clean up
headless kill sess_123
# → {"status": "ok", "killed_pids": [987, 988, 989, ...]}
```

### Workflow 2: Interact with the running app

```bash
# Mouse click at (400, 300)
headless click 400 300 --session sess_123
# → {"status": "ok"}

# Type ASCII text
headless type "Hello World" --session sess_123
# → {"status": "ok"}

# Press a key (Return, Escape, Tab, ctrl+v, etc.)
headless key Return --session sess_123
# → {"status": "ok"}

# For non-ASCII (Unicode) text: use clipboard + Ctrl+V
headless clipboard --write "Tëxt wíth ünïcödé" --session sess_123
headless key ctrl+v --session sess_123
```

### Workflow 3: Accept blocking dialogs (EULA, license agreements)

Some Windows apps show a modal dialog on first run that blocks execution:

```bash
# After exec, if wait-window times out, check for modals:
headless windows --session sess_123
# → {"status": "ok", "windows": [{"id": "0x...", "title": "License Agreement", "type": "modal"}]}

# Accept the dialog (presses Enter on the default button)
headless accept-dialog sess_123
# → {"status": "ok", "pressed_enter_count": 1, "window_title": "License Agreement"}

# For multi-step wizards (Next → Next → Finish):
headless accept-dialog sess_123 --clicks 3
```

### Workflow 4: Debug a failing app

```bash
# List all sessions (dead ones are preserved for log inspection)
headless list
# → {"status": "ok", "sessions": [{"session_id": "sess_123", "state": "dead", ...}]}

# Get the logs (includes Wine debug + EXE's own printf output, auto UTF-16 decode)
headless logs sess_123 --lines 50
# → {"status": "ok", "logs": "=== DX9 Test Program ===\n[OK] Window created...\n..."}

# Check what windows are open
headless windows --session sess_123

# If the app crashed immediately after exec, the exec response includes
# the log tail in the error message:
# → {"status": "error", "code": "WINE_DIED", "message": "Wine process exited immediately. Log tail: ..."}
```

### Important Notes for Agents

1. **ALL output is JSON on stdout.** Parse with `json.loads()`. Warnings go to stderr.
2. **`--session` is required** for input commands (click, key, type, clipboard) when multiple sessions are active. Returns `AMBIGUOUS_SESSION` error otherwise.
3. **`exe_path` accepts both formats**: Unix (`/home/z/app.exe`) and Windows (`C:\windows\system32\notepad.exe`).
4. **The `arch` field** in the exec response tells you if the EXE ran as 32-bit or 64-bit.
5. **Session cache** lives at `~/.cache/headlesslab/` (registry.json, debug.log, per-session dirs).
6. **Dead sessions are preserved** — `headless list` shows them with `state: "dead"` so you can still read their logs.
7. **EXE write paths** are limited to the Wine prefix (`C:\users\...`). Writing to `Z:\home\...` is not supported by the bwrap sandbox.
8. **Console app output** (e.g., `cmd.exe /c echo Hello`, `sigcheck`, `ipconfig`) is captured in `headless logs`. UTF-16 output is auto-decoded.

---

## 🐛 Debugging — Common Problems

### Problem: `headless --verify` fails with "Xvfb did not create socket"

**Cause**: Xvfb is not installed or not running.

**Solution**:
```bash
# Install Xvfb (requires sudo — it's the one host dep that needs kernel access)
sudo apt-get install -y xvfb

# Verify it's on PATH
which Xvfb
```

### Problem: `wait-window` always times out

**Cause 1**: Openbox can't find its themes (common when host tools are installed in `~/.local/`).

**Diagnosis**: Check `~/.cache/headlesslab/debug.log` and `/tmp/openbox.log` for "Unable to load the theme".

**Solution**: The `headless init` command auto-sets `XDG_DATA_DIRS` to include `~/.local/usr/share`. If you're running Openbox manually, set it yourself:
```bash
export XDG_DATA_DIRS="$HOME/.local/usr/share:/usr/share:/usr/local/share"
```

**Cause 2**: The app crashed immediately after launch.

**Diagnosis**: Run `headless logs <session_id>` — if it shows `WINE_DIED`, the EXE crashed. Check the log tail for the specific error.

### Problem: `wine: failed to load L"\\??\\C:\\windows\\syswow64\\ntdll.dll" error c0000135`

**Cause**: You're trying to run a 32-bit (PE32 i386) EXE, but 32-bit support is not installed.

**Solution**: Run `bash bin/setup-32bit.sh` (build-from-source) or use the AppImage (which includes 32-bit support).

### Problem: `wine: could not load ntdll.so: (null)`

**Cause**: Bubblewrap was run without `--proc /proc`. Wine relies on `/proc/self/exe` to locate its shared object binaries.

**Solution**: This is handled automatically by the `headless` CLI. If you're running bwrap manually, ensure `--proc /proc` is included.

### Problem: `Application tried to create a window, but no driver could be loaded`

**Cause 1**: Xvfb is not running. Check with `pgrep -f "Xvfb"`.

**Cause 2**: Wrong DISPLAY variable. Check that the DISPLAY matches the Xvfb instance.

**Cause 3**: X11 Unix socket is inaccessible. Ensure `--bind /tmp /tmp` is included in the bwrap command.

### Problem: `Initialization of winex11.drv failed`

**Cause**: Xvfb was started without the `-ac` flag (restricting access).

**Solution**: The `headless init` command starts Xvfb with `-ac` automatically. If running Xvfb manually:
```bash
Xvfb :99 -screen 0 1920x1080x24 -ac -nolisten tcp
```

### Problem: DX9 `CreateDevice` returns S_OK but screenshot is blank

**Cause**: Culling, lighting, or z-buffer is hiding the rendered geometry.

**Solution**: In your DX9 program, set the following render states:
```cpp
g_device->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
g_device->SetRenderState(D3DRS_LIGHTING, FALSE);
g_device->SetRenderState(D3DRS_ALPHABLENDENABLE, FALSE);
g_device->SetRenderState(D3DRS_ZENABLE, D3DZB_FALSE);
```

### Problem: Screenshot shows 0 or 1 unique colors (blank screen)

**Diagnosis**: Analyze the screenshot programmatically:
```python
from PIL import Image
img = Image.open('/tmp/capture.png')
colors = img.getcolors(maxcolors=1024*1024)
n = len(colors) if colors else 0
# n > 100: rendering succeeded
# n <= 100: blank/failed render
```

**Cause**: The app didn't render anything, or the window hasn't stabilized yet. Increase `wait-window --timeout` or check if the app showed an error dialog.

### Problem: `bwrap: execvp .../wine64: No such file or directory` but the file exists

**Cause**: The wine64 wrapper is a `#!/bin/sh` script, but `/bin/sh` or its libraries are not accessible inside the bwrap sandbox.

**Solution**: This is handled by the `headless` CLI's bwrap configuration. If running bwrap manually, ensure `--ro-bind /bin /bin` and `--ro-bind /lib /lib` are included.

---

## 📊 Post-Execution Analysis

### Checking if rendering occurred

```python
from PIL import Image
img = Image.open('/tmp/capture.png')
colors = img.getcolors(maxcolors=1024*1024)
if colors:
    n = len(colors)
    print(f'Unique colors: {n}')
    # n > 100: rendering succeeded
    # n <= 100: blank screen / failed render
    print(f'Top 5: {sorted(colors, reverse=True)[:5]}')
```

### Verifying animation (two screenshots should differ)

```python
import hashlib
with open('/tmp/shot1.png', 'rb') as f: h1 = hashlib.md5(f.read()).hexdigest()
with open('/tmp/shot2.png', 'rb') as f: h2 = hashlib.md5(f.read()).hexdigest()
print(f'Shots are {"DIFFERENT (animating)" if h1 != h2 else "IDENTICAL (static)"}')
```

---

## ⚠️ Known Limitations

1. **No 16-bit Windows**: Wine 9.0+ removed 16-bit support. Only PE32 (i386) and PE32+ (x86-64) are supported.
2. **Performance**: ~5-10 fps on llvmpipe software rendering. Suitable for screenshots and functional validation, not real-time gaming.
3. **No audio**: Wine ALSA configuration is omitted (silent operation). Apps that require audio may fail or hang.
4. **No DX10/DX11/DX12**: Limited to DX9. Higher versions require DXVK and a physical Vulkan-capable GPU.
5. **Xvfb requires sudo**: Xvfb is the one host dependency that cannot be bundled (needs kernel DRM/KMS access).
6. **EXE write paths**: Windows apps can only write to paths inside the Wine prefix (`C:\users\...`). Writing to `Z:\home\...` is not supported by the bwrap sandbox.
7. **OpenGL performance for 32-bit apps**: Wine's WoW64 mode has reduced OpenGL performance for 32-bit apps. Since WineD3D translates Direct3D 9 → OpenGL, 32-bit DX9 apps may see lower FPS than 64-bit equivalents.
8. **AppImage size**: The AppImage is ~454MB (includes Wine 10 + Mesa + LLVM + 32-bit support). This is the tradeoff for zero compilation.

---

## 🎯 Final Checklist

Before declaring a task complete, verify:

- [ ] `headless init` returned `{"status": "ok", ...}` with a display number
- [ ] `headless exec` returned `{"status": "ok", "session_id": "sess_...", "arch": "..."}`
- [ ] `headless wait-window` returned `{"status": "ok", "elapsed_ms": ...}` (not `timeout`)
- [ ] `headless screenshot` produced a PNG file with > 100 unique colors
- [ ] `headless kill` returned `{"status": "ok", "killed_pids": [...]}` (non-empty list)
- [ ] `headless list` shows no leftover running sessions
