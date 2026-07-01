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

## 🚨 Troubleshooting Silent Failures

The most dangerous bugs are those where the CLI returns `{"status": "ok"}`
but something is actually wrong. This section covers the silent failure
modes that agents are most likely to encounter, with decision trees.

### Decision Tree: "exec returned ok but the app is not visible"

```
headless exec app.exe → {"status": "ok", "session_id": "sess_xxx", ...}
headless wait-window sess_xxx → ???
```

1. **If wait-window returns `{"status": "ok"}`**: The app opened a window.
   Proceed to screenshot.

2. **If wait-window returns `{"status": "timeout"}`**: The app is either
   still loading OR it crashed. Check:
   ```bash
   headless list
   ```
   - If `state: "running"` → app may still be loading. Wait longer or
     increase `--timeout`.
   - If `state: "crashed"` → app crashed. Get the log:
     ```bash
     headless logs sess_xxx
     ```
   - If `state: "dead"` → process is gone. Check logs for crash markers.

3. **If wait-window returns `{"status": "error", "code": "PROCESS_DIED"}`**:
   The app crashed during startup. The `message` field contains the log
   tail. Common causes:
   - `Unhandled page fault` → the EXE itself crashed. Could be a missing
     DLL, a COM class not registered, or a genuine game bug.
   - `Application could not be started` → bwrap can't access the EXE, or
     Wine can't load a required DLL. Check the EXE path and DLL overrides.
   - `CoCreateInstance ... REGDB_E_CLASSNOTREG` → a COM class is missing
     from the 32-bit registry view (Wow6432Node). See BUG-004 in ISSUES.md.

### Decision Tree: "screenshot is all black / blank"

```
headless screenshot --session sess_xxx --out /tmp/x.png
→ {"status": "ok", "path": "/tmp/x.png", "unique_colors": 1, "warning": "Screenshot appears blank..."}
```

1. **Check if the process is still alive**:
   ```bash
   headless list
   ```
   If `state: "dead"` or `state: "crashed"` → the app died before you
   took the screenshot. Check `headless logs sess_xxx`.

2. **If the process is alive but screenshot is blank**: The app may still
   be rendering. Wait and retry:
   ```bash
   sleep 5
   headless screenshot --session sess_xxx --out /tmp/x2.png
   ```
   If still blank after 10s, the app may be rendering to an offscreen
   buffer or the display is wrong. Try `headless wait-window` first to
   ensure pixel stability.

3. **If `unique_colors` is between 2 and 10**: Could be a dialog (white
   background + black text). OCR the screenshot to check for error
   messages. The app may have shown a modal that's blocking rendering.

### Decision Tree: "headless logs returns empty string"

```
headless logs sess_xxx → {"status": "ok", "logs": ""}
```

1. **Check the default WINEDEBUG**: As of v1.1.0, the default is
   `warn+heap,err+all`. If logs are empty, the app produced no warnings
   or errors — it may be running fine, or the crash happened in a code
   path that doesn't log.

2. **Enable verbose tracing**:
   ```bash
   headless kill sess_xxx
   HEADLESS_WINEDEBUG="+relay,+seh" headless exec app.exe
   ```
   Warning: `+relay` produces gigabytes of output. Use targeted channels:
   - `+d3d9,+d3d` for DirectX 9 issues
   - `+ole` for COM/CoCreateInstance issues
   - `+seh` for exception/crash analysis
   - `+loaddll` for DLL loading failures

3. **Check the raw log file directly**:
   ```bash
   cat /tmp/wine_debug_sess_xxx.log | tail -50
   ```
   The CLI's `logs` command decodes UTF-16 and applies line limits. The
   raw file may contain content that was truncated.

### Decision Tree: "CoCreateInstance returned REGDB_E_CLASSNOTREG"

This means a COM class (CLSID) is not registered in the registry view
that the app is querying. Common for 32-bit apps on Wine 11 PE-only WoW64.

1. **Identify the missing CLSID**: The log will show something like:
   ```
   err:ole:com_get_class_object class {a65b8071-3bfe-4213-9a5b-491da4461ca7} not registered
   ```

2. **Check if the CLSID exists in the 64-bit view but not 32-bit**:
   ```bash
   grep -i "a65b8071" ~/.cache/headlesslab/wineprefix_template/system.reg
   ```
   If you see `Software\\Classes\\CLSID\\{...}` but not
   `Software\\Classes\\Wow6432Node\\CLSID\\{...}`, the CLSID needs to be
   mirrored to the 32-bit view.

3. **The fix is automatic in v1.1.0+**: The `mirror_clsids_to_wow64()`
   function runs during template creation and mirrors all 616+ CLSIDs.
   If you're on an older version, delete the template to force recreation:
   ```bash
   rm -rf ~/.cache/headlesslab/wineprefix_template
   headless exec app.exe  # will recreate template with mirrored CLSIDs
   ```

### Decision Tree: "Wine Mono Installer dialog appears and hangs"

The AppImage doesn't bundle Wine Mono. When wineboot runs, it tries to
install Mono and shows a dialog that never completes.

1. **The fix is automatic in v1.1.0+**: Template creation sets
   `WINEDLLOVERRIDES=mscoree=d;mshtml=d` to disable Mono, and creates
   a `.update-timestamp` marker so sessions skip wineboot.

2. **If you're on an older version or the dialog still appears**:
   ```bash
   headless kill sess_xxx
   rm -rf ~/.cache/headlesslab/wineprefix_template
   headless exec app.exe
   ```
   The new template will have Mono disabled.

3. **If an app genuinely needs .NET/HTML rendering**: You'll need to
   install Wine Mono manually by downloading the MSI from WineHQ and
   placing it in `opt/wine-devel/share/wine/mono/`.

### Decision Tree: "App shows 'Failed to load data files' error"

The app uses relative paths to load data files (e.g. `0000.p`), but the
current working directory inside the sandbox is wrong.

1. **The fix is automatic in v1.1.0+**: `headless exec` adds `--chdir
   <exe_dir>` to bwrap, setting the cwd to the EXE's folder.

2. **If you're running bwrap manually**: Add `--chdir /path/to/exe_dir`
   to your bwrap command.

3. **If the app needs a different cwd**: Set it in the app's
   configuration file (e.g. `_App.ini` for MBAA.exe) or use a wrapper
   script.

### General debugging checklist

When something goes wrong, follow this order:

1. `headless list` — check session state (`running` / `crashed` / `dead`)
2. `headless logs <sess>` — get the Wine log (now non-empty by default)
3. If logs are insufficient: `HEADLESS_WINEDEBUG="+seh,+loaddll" headless exec app.exe`
4. `headless screenshot --session <sess>` — check `unique_colors` and `warning`
5. If screenshot is blank: `headless windows --session <sess>` — check for modal dialogs
6. Check `~/.cache/headlesslab/debug.log` — the CLI's own debug log
7. Check `/tmp/wine_debug_<sess>.log` — the raw Wine log (may have more than `headless logs` shows)

---

## 🔧 Environment Variables

The `headless` CLI honors the following environment variables. Set them before
invoking `headless exec` (or any other command) to customize behavior.

### `HEADLESS_WINEDEBUG`
**Default**: `warn+heap,err+all`
**Purpose**: Override Wine's debug channel configuration. The default captures
warnings, errors, and heap diagnostics without producing gigabytes of trace
output. Use this to enable verbose tracing for debugging.

**Examples**:
```bash
# Full relay trace (huge output, use only for deep debugging)
HEADLESS_WINEDEBUG="+relay" headless exec app.exe

# Focus on DirectX 9 and COM (OLE)
HEADLESS_WINEDEBUG="+d3d9,+ole" headless exec app.exe

# Disable all Wine debug output (fastest, but hides errors)
HEADLESS_WINEDEBUG="-all" headless exec app.exe
```

### `HEADLESS_EXEC_WAIT`
**Default**: `5` (seconds)
**Purpose**: How long `headless exec` polls for the Wine process to stabilize
before returning. If the process crashes within this window, `exec` returns
`PROCESS_DIED` with the log tail instead of a false `ok`.

**Example**:
```bash
# Wait up to 10s for slow-loading apps
HEADLESS_EXEC_WAIT=10 headless exec slow_app.exe
```

### `HEADLESS_EXEC_GRACE`
**Default**: `1.5` (seconds)
**Purpose**: Grace period after first detecting a live user PID. Wine keeps
crashed EXE processes alive briefly while `winedbg --auto` attaches, so a
live PID doesn't immediately mean "running". The CLI polls the log for crash
markers during this grace period before declaring success.

**Example**:
```bash
# Longer grace for apps that crash late
HEADLESS_EXEC_GRACE=3 headless exec app.exe
```

### `HEADLESS_DLL_OVERRIDES`
**Default**: *(unset)*
**Purpose**: Set Wine DLL overrides (equivalent to `WINEDLLOVERRIDES`).
Semicolon-separated list of `dll=mode` entries. Useful when the game ships
native DLLs that should override Wine's builtin versions.

**Example**:
```bash
# Use native d3dx9 DLLs from the game directory
HEADLESS_DLL_OVERRIDES="d3dx9_36=native,builtin;d3dx9_43=native,builtin" \
    headless exec app.exe
```

### `HEADLESS_USE_WINECONSOLE`
**Default**: *(unset)*
**Purpose**: Force `wineconsole --backend=user` for console-subsystem apps.
By default, console apps are launched with plain `wine` (their stdout/stderr
is captured to the log file). Set to `1` to get a visible Wine console window
(useful for interactive console apps).

**Example**:
```bash
HEADLESS_USE_WINECONSOLE=1 headless exec console_app.exe
```

### `HEADLESS_NO_WAIT_WARNING`
**Default**: *(unset)*
**Purpose**: Suppress the one-time-per-session stderr warning that
`headless screenshot` emits reminding that processes may take time to render.

**Example**:
```bash
HEADLESS_NO_WAIT_WARNING=1 headless screenshot --session sess_xxx --out /tmp/x.png
```

### `APPDIR`
**Default**: *(auto-detected)*
**Purpose**: Required when running from an extracted AppImage (FUSE-less
environments like Docker/CI). Set to the path of the `squashfs-root/`
directory created by `./HeadlessLab.AppImage --appimage-extract`.

**Example**:
```bash
./HeadlessLab.AppImage --appimage-extract
cd squashfs-root
export APPDIR="$PWD"
./AppRun exec /path/to/app.exe
```

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
