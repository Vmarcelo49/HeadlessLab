# HeadlessLab — Known Issues & Backlog

This file tracks bugs, limitations, and improvement opportunities discovered
during real-world usage. Each entry is formatted as a standalone issue ready
to be triaged and assigned to a release milestone.

**Convention**:
- `BUG`: Defect that produces incorrect behavior (silent failures, crashes, wrong output)
- `LIMITATION`: Missing capability that forces agents to work around the tool
- `ENHANCEMENT`: New feature that would significantly improve DX
- `DOCS`: Documentation gap

Priority: `P0` (critical) → `P3` (nice to have).

---

## BUG-001 — `headless exec` returns success when the process dies immediately

**Priority**: P0
**Component**: `bin/headless` → `cmd_exec`
**Affected versions**: v1.0.0
**Resolved in**: v1.1.0 (commit pending)

### Summary

`headless exec /path/to/app.exe` returns `{"status": "ok", "pid": 1234, "arch": "i386"}`
even when the spawned Wine process exits within 2 seconds. The CLI performs a
cursory check on `/proc/{root_pid}` after a 2-second sleep, but this check is
fragile: it succeeds if the `bwrap` parent is still alive (it briefly outlives
the wine child), and it does not detect processes that crash after the 2s
window but before `wait-window` is called.

### Steps to reproduce

1. Launch an EXE that crashes on startup (e.g. MBAA.exe before the Wow6432Node fix)
2. Observe the response:
   ```json
   {"status": "ok", "session_id": "sess_...", "pid": 2965, "arch": "i386"}
   ```
3. Call `headless logs <sess>` → returns empty string
4. Call `headless wait-window <sess>` → times out after 30s
5. Only by manually reading `/tmp/wine_debug_<sess>.log` does the crash become visible

### Expected behavior

If the process exits within ~5 seconds, `headless exec` should return:
```json
{
  "status": "error",
  "code": "PROCESS_DIED",
  "exit_code": -11,
  "log_tail": "<last 50 lines of wine debug log>"
}
```

### Suggested fix

In `cmd_exec`, after `subprocess.Popen`, poll the process for up to 5 seconds
using `proc.poll()`. If it returns non-None, read the log file and emit a
`PROCESS_DIED` error with the tail. Also consider a `--wait` flag that blocks
until either a window appears or the process dies.

### Status

**Fixed** in commit (pending push). The fix implements a polling loop with
three crash detection signals:

1. **bwrap exit**: `proc.poll()` returns non-None — the whole process tree is gone.
2. **Log crash markers**: the Wine log contains "Unhandled page fault",
   "access violation", "unhandled exception", or "wine: Unhandled". This
   catches crashes even when Wine's `winedbg --auto` keeps zombie processes
   alive.
3. **No wine processes**: after the timeout, no wine processes are registered
   under the prefix.

A key refinement is the **grace period** (default 1.5s, configurable via
`HEADLESS_EXEC_GRACE`): when a live user PID is first detected, the CLI does
not immediately declare success. Instead it keeps polling the log for the
grace period to catch crashes that take a moment to propagate. This is
necessary because Wine keeps crashed EXE processes alive briefly while
`winedbg --auto` attaches.

The total wait time is configurable via `HEADLESS_EXEC_WAIT` (default 5s).
The session is marked with `state: "crashed"` and `crash_reason` in the
registry so `headless list` shows crashed sessions distinctly.

Validated with a custom `crash_test.exe` (PE32 that dereferences NULL):
- Before fix: `{"status": "ok", "pid": ..., "arch": "i386"}`
- After fix: `{"status": "error", "code": "PROCESS_DIED", "message": "...log contains 'unhandled page fault'..."}`

Also validated that working apps (zzcaster.exe, MBAA.exe) still return
`{"status": "ok"}` correctly.

---

## BUG-002 — `headless wait-window` cannot distinguish "still loading" from "crashed"

**Priority**: P0
**Component**: `bin/headless` → `cmd_wait_window`
**Affected versions**: v1.0.0

### Summary

`wait-window` polls `wmctrl -l` in a loop until a window appears or 30 seconds
elapse. When the underlying process crashes, the command still waits the full
30 seconds and returns `{"status": "timeout"}` — identical to a slow-loading
app that simply hasn't opened a window yet.

### Steps to reproduce

1. `headless exec broken.exe` (returns session id)
2. `headless wait-window <sess>` → `{"status": "timeout"}` after 30s
3. Discover via `ps` that `broken.exe` died at t=2s

### Expected behavior

`wait-window` should check the liveness of the session's PIDs on each
iteration. If all PIDs are gone, return immediately with:
```json
{
  "status": "error",
  "code": "PROCESS_DIED",
  "log_tail": "..."
}
```

### Suggested fix

In `cmd_wait_window`, call `get_pids_for_prefix(wineprefix)` each iteration.
If the list is empty (or all PIDs fail `os.path.exists("/proc/{pid}")`),
return `PROCESS_DIED` instead of continuing to poll.

---

## BUG-003 — `headless logs` returns empty because WINEDEBUG is hardcoded to `-all`

**Priority**: P0
**Component**: `bin/headless` → `cmd_exec` (WINEDEBUG setting)
**Affected versions**: v1.0.0

### Summary

`cmd_exec` sets `env["WINEDEBUG"] = "-all,+debugstr"` unconditionally. The
`-all` flag suppresses all `err:`, `fixme:`, and `trace:` output from Wine's
DLLs, leaving the log file empty for most failures. Agents cannot debug
without first patching the CLI to honor a `HEADLESS_WINEDEBUG` override.

### Steps to reproduce

1. `headless exec app.exe` (app crashes on startup)
2. `headless logs <sess>` → `{"status": "ok", "logs": ""}`

### Expected behavior

A sensible default that captures errors without producing gigabytes of
trace output. Recommended default: `WINEDEBUG=warn+heap,err+all` (warnings,
errors, and heap diagnostics). Allow override via `HEADLESS_WINEDEBUG`
environment variable. Document the variable in `docs/GUIDE_LLM.md`.

### Suggested fix

```python
env["WINEDEBUG"] = os.environ.get(
    "HEADLESS_WINEDEBUG",
    "warn+heap,err+all"  # default: capture errors without trace spam
)
```

### Status

Partially fixed in commit `6be68fd` (override env var added). Default value
is still `-all,+debugstr` and should be changed.

---

## BUG-004 — Wow6432Node CLSIDs are not populated, breaking 32-bit COM apps

**Priority**: P0
**Component**: `bin/headless` → wineboot template creation
**Affected versions**: v1.0.0

### Summary

Wine 11's PE-only WoW64 mode does not reflect CLSID registry entries between
the 64-bit and 32-bit registry views. Consequently, any 32-bit application
that calls `CoCreateInstance` with `KEY_WOW64_32KEY` (the default for most
32-bit COM callers) will receive `REGDB_E_CLASSNOTREG` (0x80040154) for any
CLSIDs that are only registered in `HKLM\Software\Classes\CLSID\...` but not
in `HKLM\Software\Classes\Wow6432Node\CLSID\...`.

This affects a wide range of real-world 32-bit apps:
- Games using `DxDiagProvider` (CLSID `{A65B8071-...}`) — e.g. MBAACC
- Apps using `MMDeviceEnumerator` (Core Audio) — CLSID `{bcde0395-...}`
- Apps using `WBEM Locator` (WMI) — CLSID `{4590F811-...}`
- DirectShow, DirectInput, DirectSound, DirectDraw COM classes

The `--verify` smoke test does not exercise COM, so this defect is invisible
until a real app is launched.

### Steps to reproduce

1. Build a clean AppImage from `main` (before commit `6be68fd`)
2. `headless exec /path/to/MBAA.exe`
3. App crashes with `Unhandled page fault on read access to 00000000`
4. Root cause (visible only with `HEADLESS_WINEDEBUG=+ole,+relay`):
   `CoCreateInstance(DxDiagProvider)` returns `REGDB_E_CLASSNOTREG` because
   the CLSID exists only in the 64-bit view.

### Expected behavior

After `wineboot -u` completes during template creation, the CLI should
mirror all CLSID `InprocServer32` entries from the 64-bit view into
`Wow6432Node\CLSID\...`, with `system32` paths converted to `syswow64`.
Missing DLLs in syswow64 subdirectories (e.g. `wbem/`, `ADO/`, `OLE DB/`)
should be symlinked from Wine's `i386-windows` directory.

### Suggested fix

Implemented in commit `6be68fd` as `mirror_clsids_to_wow64()`. Long-term
fix: upstream this into Wine's `wineboot` or file a bug against Wine 11's
PE-only WoW64 reflection behavior.

### Status

Fixed in commit `6be68fd`. This issue remains open for tracking the upstream
Wine bug.

---

## BUG-005 — Wine Mono/Gecko installer hangs the template creation forever

**Priority**: P0
**Component**: `bin/headless` → wineboot template creation
**Affected versions**: v1.0.0

### Summary

During template creation, `wineboot.exe -u` attempts to install Wine Mono
and Wine Gecko by launching `control.exe appwiz.cpl install_mono`. The
AppImage does not bundle the `wine-mono-*.msi` or `wine-gecko-*.msi` files,
so the installer opens a modal dialog ("Wine Mono Installer") that never
completes. The dialog blocks the wineserver, preventing any subsequent
session from initializing.

Worse: `headless wait-window` detects the "Wine Mono Installer" window and
returns success, giving the false impression that the app has loaded.

### Steps to reproduce

1. Delete `~/.cache/headlesslab/wineprefix_template`
2. `headless exec /path/to/app.exe`
3. Wait for template creation (~45s)
4. `headless wait-window <sess>` → `{"status": "ok", "elapsed_ms": ...}` (false positive)
5. `headless screenshot --session <sess>` → shows the Mono installer dialog, not the app

### Expected behavior

Either bundle the Wine Mono/Gecko MSI files in the AppImage (adds ~100MB)
or disable the installer during template creation via
`WINEDLLOVERRIDES=mscoree=d;mshtml=d` and create a `.update-timestamp`
marker so subsequent sessions skip `wineboot -u`.

### Suggested fix

Implemented in commit `6be68fd`:
- Set `WINEDLLOVERRIDES=mscoree=d;mshtml=d` in `template_env`
- Create `drive_c/.update-timestamp` with `mtime(wine.inf) + 3600`
- Recreate the marker in each session prefix after `copytree`

### Status

Fixed in commit `6be68fd`. Open for tracking: consider bundling Mono/Gecko
in a future AppImage variant for apps that genuinely need .NET/HTML rendering.

---

## BUG-006 — `headless screenshot` returns success for blank/black captures

**Priority**: P1
**Component**: `bin/headless` → `cmd_screenshot`
**Affected versions**: v1.0.0

### Summary

`screenshot` always returns `{"status": "ok", "path": "..."}` regardless of
whether the captured image contains any visible content. When an app has
crashed or is still loading, the screenshot is a 390-byte all-black PNG that
is indistinguishable from a successful capture to an agent parsing JSON.

### Steps to reproduce

1. `headless exec broken.exe`
2. `headless screenshot --session <sess> --out /tmp/x.png` → `{"status": "ok"}`
3. `/tmp/x.png` is 390 bytes, all black, 0 unique colors beyond background

### Expected behavior

After capture, analyze the image with Pillow (already a dependency):
count unique colors. If fewer than 5, emit a `warning` field:
```json
{
  "status": "ok",
  "path": "/tmp/x.png",
  "unique_colors": 1,
  "warning": "Screenshot appears blank (1 unique color). Process may still be loading, may have crashed, or display may be incorrect."
}
```

### Suggested fix

```python
from PIL import Image
from collections import Counter
img = Image.open(out_path)
colors = len(Counter(list(img.convert("RGB").getdata())))
response = {"status": "ok", "path": out_path, "unique_colors": colors}
if colors < 5:
    response["warning"] = "Screenshot appears blank ..."
print_json(response)
```

---

## BUG-007 — `headless windows` does not list modal dialogs

**Priority**: P1
**Component**: `bin/headless` → `cmd_windows` / `get_windows_for_session`
**Affected versions**: v1.0.0

### Summary

`headless windows --session <sess>` filters the X11 window list by PIDs
associated with the session's wineprefix. Modal dialogs (e.g. Wine's
"Error" message box, file pickers, `MessageBox` calls) often have an
`_NET_WM_PID` that does not match the wineprefix's PID set, causing them
to be silently excluded from the response.

### Steps to reproduce

1. Launch an app that shows a `MessageBox` error on startup (e.g. MBAA.exe
   before the `--chdir` fix shows "Failed to load data Files")
2. `headless windows --session <sess>` → `{"status": "ok", "windows": []}`
3. `DISPLAY=:99 wmctrl -l` (run manually) → shows the "Error" window

### Expected behavior

`cmd_windows` should return all windows whose `_NET_WM_PID` matches any
process in the session **or** whose `WM_CLASS` matches the EXE's basename
(e.g. `mbaa.exe`). A fallback heuristic: include any window that appeared
after the session was created and is owned by a wine process.

### Suggested fix

In `get_windows_for_session`, after the PID filter, run a second pass:
```python
for win in all_windows:
    if win["pid"] in session_pids:
        continue  # already included
    # Check WM_CLASS against the EXE name
    if exe_basename.lower() in win.get("wm_class", "").lower():
        windows.append(win)
```

---

## BUG-008 — `headless kill` leaves orphaned debugger/crash-handler processes

**Priority**: P1
**Component**: `bin/headless` → `cmd_kill`
**Affected versions**: v1.0.0

### Summary

`headless kill <sess>` kills PIDs associated with the wineprefix (bwrap,
wineserver, wine, winedevice, the EXE). When the EXE crashes, Wine spawns
`winedbg --auto` and sometimes `crashdump.exe`. These processes are not
children of the wineprefix's PIDs in a way that `get_pids_for_prefix`
detects, so they survive the kill and consume CPU indefinitely.

### Steps to reproduce

1. `headless exec app.exe` (app crashes)
2. `headless kill <sess>` → `{"status": "ok", "killed_pids": [...]}`
3. `ps aux | grep winedbg` → still running at 20% CPU

### Expected behavior

`cmd_kill` should additionally kill any process whose command line contains
`winedbg`, `crashdump`, or the session's wineprefix path. Consider using
`pkill -f <wineprefix>` as a final sweep, or tracking the process group
(via `setsid`) and killing the entire group.

### Suggested fix

```python
# After killing session_pids, sweep for orphans
import signal
for p in range(1, 65536):
    try:
        with open(f"/proc/{p}/cmdline", "rb") as f:
            cmdline = f.read().decode("utf-8", errors="ignore")
        if wineprefix in cmdline or "winedbg" in cmdline:
            os.kill(p, signal.SIGKILL)
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        continue
```

---

## LIMITATION-001 — No text-based click; agents must compute coordinates manually

**Priority**: P1
**Component**: `bin/headless` → new command `click-text`
**Affected versions**: v1.0.0

### Summary

`headless click <x> <y>` requires the caller to already know the pixel
coordinates of the target. To obtain them, an agent must:
1. Take a screenshot
2. Run OCR (tesseract is not bundled; agent must invoke it externally)
3. If OCR fails (low-contrast buttons), perform color-based region detection
4. Crop each candidate region, upscale, and OCR individually
5. Compute the center of the matched bounding box
6. Call `headless click`

This 6-step pipeline was required to click the "Training" button in
ZZCaster. Reimplementing it per session is expensive and error-prone.

### Expected behavior

Provide `headless click-text "<text>" --session <sess>` that performs OCR
internally and clicks the center of the first match. Fallback strategy:
1. Full-screen OCR with TSV bounding boxes
2. Upscale 2x and retry (for small text)
3. Color-based button detection + per-button OCR (for low-contrast text)

### Proposed interface

```bash
headless click-text "Training" --session sess_xxx
headless click-text "OK" --session sess_xxx --index 2
headless click-text "Continue" --session sess_xxx --fuzzy
headless click-text "Cancel" --session sess_xxx --dry-run
```

Response:
```json
{
  "status": "ok",
  "text": "Training",
  "x": 1219,
  "y": 537,
  "width": 280,
  "height": 44,
  "confidence": 93.5,
  "method": "ocr",
  "clicked": true
}
```

### Dependencies

Requires `tesseract-ocr` to be bundled in `host-debs/` and installed by
`install-host-deps.sh`. Also add to the GitHub Actions `apt-get install` line.

---

## LIMITATION-002 — No `find-text` or `find-buttons` helpers

**Priority**: P2
**Component**: `bin/headless` → new commands
**Affected versions**: v1.0.0

### Summary

Even when the agent does not want to click, it has no way to ask the CLI
"where on screen is the text X?" or "where are the buttons?". This forces
every agent to reinvent OCR and color-segmentation pipelines.

### Expected behavior

Two companion commands to `click-text`:

```bash
headless find-text "Training" --session <sess>
```
```json
{
  "status": "ok",
  "matches": [
    {"text": "Training", "x": 1219, "y": 537, "width": 280, "height": 44, "confidence": 93.5}
  ],
  "count": 1
}
```

```bash
headless find-buttons --session <sess>
headless find-buttons --session <sess> --color "191,56,43"
```
```json
{
  "status": "ok",
  "buttons": [
    {"x": 1219, "y": 537, "width": 280, "height": 44, "color": [191,56,43], "text": "Training"},
    {"x": 1219, "y": 589, "width": 280, "height": 44, "color": [191,56,43], "text": ""}
  ],
  "count": 2
}
```

---

## LIMITATION-003 — Apps using relative paths for data files fail without `--chdir`

**Priority**: P1
**Component**: `bin/headless` → `cmd_exec` (bwrap invocation)
**Affected versions**: v1.0.0

### Summary

Many Windows apps load data files via relative paths (e.g. MBAA.exe opens
`0000.p` from the current working directory). The bwrap sandbox inherits
the caller's cwd, which is rarely the EXE's directory. The result: the app
launches, shows a "Failed to load data files" dialog, and exits — but
`headless exec` reports success because the process survived past the 2s
check.

### Steps to reproduce

1. `cd /tmp`
2. `headless exec /home/user/MBAACC/MBAA.exe`
3. App shows "Failed to load data Files, Please re-install"
4. `headless exec` returned `{"status": "ok", ...}`

### Expected behavior

bwrap should `--chdir` to the EXE's directory by default. A `--cwd` flag
could be added to `headless exec` for callers that want to override.

### Status

Fixed in commit `d13d12b` (the `--chdir` is always set to `exe_dir`). This
issue remains open to track adding a `--cwd` override flag and documenting
the behavior.

---

## LIMITATION-004 — Console-subsystem apps produce no captured stdout

**Priority**: P2
**Component**: `bin/headless` → `cmd_exec`
**Affected versions**: v1.0.0

### Summary

When a PE32 console-subsystem app (e.g. `zzcaster.exe`) is launched with
`wine` (not `wineconsole`), Wine does not allocate a Windows console, and
the app's `printf`/`cout` output goes nowhere. `headless logs` returns an
empty string even though the app is running and printing.

### Steps to reproduce

1. `headless exec zzcaster.exe` (subsystem 3)
2. `headless logs <sess>` → `{"status": "ok", "logs": ""}`

### Expected behavior

For console-subsystem apps, either:
- Use `wineconsole --backend=user` (creates a visible Wine console window)
- Or capture the EXE's stdout/stderr directly (already done, but Wine's
  `wine` binary doesn't forward console output for subsystem-3 apps)

A `HEADLESS_USE_WINECONSOLE=1` opt-in was added in commit `d13d12b`, but the
default behavior is still "no output". The CLI should at least warn:
```json
{
  "status": "ok",
  "warning": "Console-subsystem app launched without wineconsole. stdout/stderr may not be captured. Set HEADLESS_USE_WINECONSOLE=1 to enable."
}
```

---

## LIMITATION-005 — No `headless register-dll` command

**Priority**: P2
**Component**: `bin/headless` → new command
**Affected versions**: v1.0.0

### Summary

Some apps require native DLLs to be registered via `regsvr32` (which calls
`DllRegisterServer`). Currently the only way to do this is to run
`headless exec C:\\windows\\system32\\regsvr32.exe /s <dll>` — but this
creates a session, copies the wineprefix template (~700MB), runs, and
leaves the session around. There is no lightweight "modify the template
in place" operation.

### Expected behavior

```bash
headless register-dll C:\\windows\\syswow64\\dxdiagn.dll
headless register-dll /path/to/native/d3dx9_36.dll --arch i386
```

This would run `regsvr32` against the template wineprefix (not a session
copy) and report which CLSIDs were registered.

---

## LIMITATION-006 — No `headless drag`, `headless scroll`, or multi-key combos

**Priority**: P3
**Component**: `bin/headless` → input commands
**Affected versions**: v1.0.0

### Summary

The input commands are limited to single clicks, single keypresses, ASCII
typing, and clipboard writes. Missing capabilities that real apps need:
- Mouse drag (for sliders, drag-and-drop)
- Mouse scroll wheel
- Simultaneous key combinations beyond 2 keys (e.g. `ctrl+shift+esc`)
- Reliable Unicode typing (current `type` is ASCII-only; Unicode requires
  the clipboard workaround)

### Suggested additions

```bash
headless drag <x1> <y1> <x2> <y2> --session <sess>
headless scroll <amount> --session <sess>   # positive=down, negative=up
headless key ctrl+shift+esc --session <sess>
headless type-unicode "日本語" --session <sess>   # uses clipboard + paste
```

---

## ENHANCEMENT-001 — `headless exec` should block until window or death (`--wait`)

**Priority**: P1
**Component**: `bin/headless` → `cmd_exec`
**Affected versions**: v1.0.0

### Summary

The typical agent pattern is:
```bash
headless exec app.exe        # returns immediately
headless wait-window <sess>  # polls for 30s
headless screenshot ...      # capture
```

This is three round-trips. A `--wait` flag on `exec` would combine them:
```bash
headless exec app.exe --wait --timeout 30
```
Returns when either a window appears (with window info) or the process dies
(with log tail). Reduces agent latency and avoids the "exec says ok but app
is dead" trap of BUG-001.

---

## ENHANCEMENT-002 — Performance metrics in session output

**Priority**: P3
**Component**: `bin/headless` → session registry
**Affected versions**: v1.0.0

### Summary

There is no way to measure:
- Time from `exec` to first window
- Time from `exec` to first non-blank screenshot
- Steady-state FPS (for games)
- CPU/memory usage of the Wine process tree
- Screenshot capture latency

For CI and regression detection, these metrics matter. Consider adding a
`headless metrics <sess>` command that returns a snapshot, and an optional
`--metrics` flag on `exec` that emits metrics to stderr during the run.

---

## ENHANCEMENT-003 — Smoke test should exercise COM and 32-bit apps

**Priority**: P2
**Component**: `bin/headless` → `run_verify` + `.github/workflows/main.yml`
**Affected versions**: v1.0.0

### Summary

`headless --verify` runs a minimal DX9 triangle (64-bit, no COM, no audio,
no input). It passes even when:
- Wow6432Node CLSIDs are missing (BUG-004)
- Wine Mono installer hangs (BUG-005)
- Console-subsystem apps produce no output (LIMITATION-004)
- Apps with relative-path data files fail (LIMITATION-003)

The CI workflow runs `--verify` and reports green, giving false confidence.

### Expected behavior

Add verification cases:
1. A 32-bit DX9 triangle (exercises WoW64 rendering)
2. A 32-bit app that calls `CoCreateInstance(DxDiagProvider)` (exercises COM)
3. A 32-bit console app that prints to stdout (exercises console capture)
4. An app that loads a data file via relative path (exercises `--chdir`)

Each case should assert a non-blank screenshot and/or expected log output.

---

## DOCS-001 — `docs/GUIDE_LLM.md` lacks troubleshooting for silent failures

**Priority**: P1
**Component**: `docs/GUIDE_LLM.md`
**Affected versions**: v1.0.0

### Summary

The LLM agent guide (19KB) covers architecture and common commands but
does not address the failure modes that agents are most likely to encounter:

- "exec returned ok but the app is not visible" → check `headless logs`,
  set `HEADLESS_WINEDEBUG=+relay`
- "wait-window timed out" → check if the process is still alive via
  `headless list`
- "screenshot is all black" → app may still be loading; wait and retry, or
  check for crash
- "CoCreateInstance returned REGDB_E_CLASSNOTREG" → Wow6432Node CLSIDs
  missing (BUG-004)
- "Wine Mono Installer dialog appears" → BUG-005

A "Troubleshooting" section with decision trees would save agents
significant time.

---

## DOCS-002 — No documentation of `HEADLESS_*` environment variables

**Priority**: P2
**Component**: `docs/GUIDE_LLM.md`, `README.md`
**Affected versions**: v1.0.0

### Summary

The following environment variables are honored by `bin/headless` but not
documented anywhere:
- `HEADLESS_WINEDEBUG` — override the default WINEDEBUG setting
- `HEADLESS_DLL_OVERRIDES` — set WINEDLLOVERRIDES (semicolon-separated)
- `HEADLESS_USE_WINECONSOLE` — force wineconsole for console apps
- `HEADLESS_NO_WAIT_WARNING` — suppress the screenshot wait warning
- `APPDIR` — required when running from an extracted AppImage

Each should be documented with its purpose, default behavior, and example.

---

## Release Planning Suggestions

### v1.1.0 — Reliability

Focus on eliminating silent failures:
- BUG-001 (exec returns ok on crash)
- BUG-002 (wait-window vs crash)
- BUG-003 (WINEDEBUG default)
- BUG-006 (blank screenshot warning)
- BUG-007 (modal dialogs in windows)
- BUG-008 (orphaned winedbg)
- ENHANCEMENT-001 (--wait flag)
- DOCS-001 (troubleshooting guide)

### v1.2.0 — Agent UX

Focus on reducing agent round-trips:
- LIMITATION-001 (click-text)
- LIMITATION-002 (find-text, find-buttons)
- LIMITATION-004 (console app output warning)
- DOCS-002 (env var docs)

### v1.3.0 — Real-world app coverage

Focus on making real games/apps work:
- ENHANCEMENT-003 (expanded smoke test)
- LIMITATION-005 (register-dll command)
- LIMITATION-006 (drag, scroll, multi-key)

### v1.4.0 — Polish

- ENHANCEMENT-002 (performance metrics)
- BUG-004 upstream Wine bug tracking
- BUG-005 Mono/Gecko bundling option

---

## How to Contribute

Since issue tracking is not currently enabled on the repository, please
add new entries to this file following the format above. When fixing an
issue, update its `Status` field with the commit SHA and move it under a
"Resolved in vX.Y.Z" heading at the bottom of this file.

### Entry template

```markdown
## <TYPE>-<NNN> — <short title>

**Priority**: P0|P1|P2|P3
**Component**: <file or module>
**Affected versions**: <version>

### Summary
<1-2 paragraph description of the problem>

### Steps to reproduce
1. ...

### Expected behavior
<what should happen instead>

### Suggested fix
<code sketch or approach>

### Status
Open | Fixed in <commit> | Resolved in vX.Y.Z
```
