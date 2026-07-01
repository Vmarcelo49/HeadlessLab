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

## Resolved in v1.1.0

The following issues were resolved in the v1.1.0 milestone (commits
`9a375cb`, `483014d`, `bc34fb2`):

### BUG-001 — `headless exec` returns success when the process dies immediately

**Priority**: P0
**Component**: `bin/headless` → `cmd_exec`
**Resolved in**: v1.1.0 (commit `9a375cb`)

**Summary**: `headless exec` returned `{"status": "ok"}` even when the EXE
crashed within seconds. The old check (sleep 2s + `/proc/{pid}`) was
unreliable because bwrap outlives the wine child and `winedbg --auto` keeps
zombie processes alive.

**Fix**: Implemented a polling loop with 3 crash detection signals:
1. bwrap exit (`proc.poll()` returns non-None)
2. Log crash markers ("Unhandled page fault", "access violation", etc.)
3. No wine processes under prefix after timeout

A grace period (default 1.5s, configurable via `HEADLESS_EXEC_GRACE`) waits
after first seeing a live user PID before declaring success, to catch
crashes that take a moment to propagate. Returns `PROCESS_DIED` with log tail.

---

### BUG-002 — `headless wait-window` cannot distinguish "still loading" from "crashed"

**Priority**: P0
**Component**: `bin/headless` → `cmd_wait_window`
**Resolved in**: v1.1.0 (commit `483014d`)

**Summary**: `wait-window` polled `wmctrl` for 30s and returned `timeout`
even if the process died at t=2s — indistinguishable from a slow-loading app.

**Fix**: `cmd_wait_window` now checks process liveness on each iteration.
If no wine processes are under the prefix, or if the log shows a crash
marker and only helper PIDs remain, returns `PROCESS_DIED` immediately.
Session marked `state: "crashed"`. Reuses module-level `live_user_pids()`
and `log_shows_crash()` helpers from BUG-001.

---

### BUG-003 — `headless logs` returns empty because WINEDEBUG is hardcoded to `-all`

**Priority**: P0
**Component**: `bin/headless` → `cmd_exec` (WINEDEBUG setting)
**Resolved in**: v1.1.0 (commit `483014d`)

**Summary**: `WINEDEBUG` was hardcoded to `-all,+debugstr`, suppressing all
Wine errors/warnings. Logs were empty for most failures.

**Fix**: Default changed to `warn+heap,err+all` — captures warnings, errors,
and heap diagnostics without trace spam. `HEADLESS_WINEDEBUG` env var still
overrides. Documented in `docs/GUIDE_LLM.md`.

---

### BUG-004 — Wow6432Node CLSIDs are not populated, breaking 32-bit COM apps

**Priority**: P0
**Component**: `bin/headless` → wineboot template creation
**Resolved in**: v1.1.0 (commit `6be68fd`)

**Summary**: Wine 11's PE-only WoW64 doesn't reflect CLSID registry entries
between 32-bit and 64-bit views. Any 32-bit app calling `CoCreateInstance`
with `KEY_WOW64_32KEY` got `REGDB_E_CLASSNOTREG`. Affected DxDiagProvider,
MMDeviceEnumerator, WBEM Locator, DirectSound, DirectInput, DirectDraw, etc.

**Fix**: `mirror_clsids_to_wow64()` function runs during template creation,
mirroring all 616+ CLSIDs from 64-bit to 32-bit (Wow6432Node) view with
system32→syswow64 path conversion. Also creates missing DLL symlinks in
syswow64 subdirectories (wbem/, ADO/, OLE DB/, etc.).

---

### BUG-005 — Wine Mono/Gecko installer hangs the template creation forever

**Priority**: P0
**Component**: `bin/headless` → wineboot template creation
**Resolved in**: v1.1.0 (commit `6be68fd`)

**Summary**: The AppImage doesn't bundle Wine Mono MSI. During `wineboot -u`,
the "Wine Mono Installer" dialog appeared and never completed, blocking the
wineserver.

**Fix**: Template creation now sets `WINEDLLOVERRIDES=mscoree=d;mshtml=d`
to disable Mono, and creates a `.update-timestamp` marker so sessions skip
`wineboot -u` entirely.

---

### BUG-006 — `headless screenshot` returns success for blank/black captures

**Priority**: P1
**Component**: `bin/headless` → `cmd_screenshot`
**Resolved in**: v1.1.0 (commit `483014d`)

**Summary**: `screenshot` always returned `{"status": "ok"}` even when the
capture was a 390-byte all-black PNG.

**Fix**: `cmd_screenshot` now analyzes the PNG with Pillow (sampling every
4th pixel) and counts unique colors. If < 5, includes a `warning` field.
`unique_colors` is always included so agents can make threshold decisions.

---

### BUG-007 — `headless windows` does not list modal dialogs

**Priority**: P1
**Component**: `bin/headless` → `get_windows_for_session` / `cmd_windows`
**Resolved in**: v1.1.0 (commit `bc34fb2`)

**Summary**: `windows --session` filtered by `_NET_WM_PID in session_pids`.
Modal dialogs (MessageBox, Wine Debugger, Error dialogs) often have PIDs not
in the wineprefix's process tree, so they were invisible.

**Fix**: 3-tier fallback in `get_windows_for_session`:
1. Primary: filter by PID (original)
2. Fallback 1: match by `WM_CLASS` against exe basename (via `xprop`)
3. Fallback 2: match by dialog title (Error, Wine Debugger, etc.)

Each window includes `matched_by: "pid" | "wm_class" | "dialog_title"`.

---

### BUG-008 — `headless kill` leaves orphaned debugger/crash-handler processes

**Priority**: P1
**Component**: `bin/headless` → `cmd_kill`
**Resolved in**: v1.1.0 (commit `483014d`)

**Summary**: `kill` didn't clean up `winedbg --auto` and `crashdump.exe`
spawned by Wine when an EXE crashed. They consumed CPU indefinitely.

**Fix**: `cmd_kill` now sweeps all PIDs 1-65536 for `winedbg`/`crashdump`/
`crashhandler` in their cmdline, killing any that reference the session's
wineprefix path.

---

### ENHANCEMENT-001 — `headless exec --wait` flag

**Priority**: P1
**Component**: `bin/headless` → `cmd_exec`
**Resolved in**: v1.1.0 (commit `bc34fb2`)

**Summary**: Agents had to call `exec` then `wait-window` separately (3
round-trips). `exec` could return `ok` while the app was already dead.

**Fix**: Added `--wait` and `--timeout` flags to `exec`. When set, blocks
after launch polling for window stability (reusing BUG-002 crash detection).
Returns `ok` + window info + `elapsed_ms`, or `PROCESS_DIED` if crash, or
`timeout` if no window within `--timeout` ms.

---

### DOCS-001 — Troubleshooting guide for silent failures

**Priority**: P1
**Component**: `docs/GUIDE_LLM.md`
**Resolved in**: v1.1.0 (commit `bc34fb2`)

**Summary**: The LLM agent guide lacked troubleshooting for the failure
modes agents encounter most (exec ok but app dead, blank screenshot, empty
logs, REGDB_E_CLASSNOTREG, Mono installer hang, data file errors).

**Fix**: Added "Troubleshooting Silent Failures" section with 6 decision
trees and a 7-step general debugging checklist.

---

### DOCS-002 — Document `HEADLESS_*` environment variables

**Priority**: P2
**Component**: `docs/GUIDE_LLM.md`
**Resolved in**: v1.1.0 (commit `483014d`)

**Summary**: 7 environment variables (`HEADLESS_WINEDEBUG`,
`HEADLESS_EXEC_WAIT`, `HEADLESS_EXEC_GRACE`, `HEADLESS_DLL_OVERRIDES`,
`HEADLESS_USE_WINECONSOLE`, `HEADLESS_NO_WAIT_WARNING`, `APPDIR`) were
honored but undocumented.

**Fix**: Added comprehensive "Environment Variables" section to
`docs/GUIDE_LLM.md` with defaults, purpose, and examples for all 7 vars.

---

## Open Issues (v1.2.0+ backlog)

### LIMITATION-001 — No text-based click; agents must compute coordinates manually

**Priority**: P1
**Component**: `bin/headless` → new command `click-text`
**Status**: Open

**Summary**: `headless click <x> <y>` requires the caller to know pixel
coordinates. To obtain them, an agent must screenshot, run OCR externally,
do color-based region detection for low-contrast buttons, and compute
bounding box centers — a 6-step pipeline reimplemented per session.

**Expected behavior**: `headless click-text "<text>" --session <sess>`
that performs OCR internally and clicks the center of the first match.
Fallback strategy: full-screen OCR → 2x upscale → color-based button
detection + per-button OCR.

**Dependencies**: Requires `tesseract-ocr` bundled in `host-debs/`.

---

### LIMITATION-002 — No `find-text` or `find-buttons` helpers

**Priority**: P2
**Component**: `bin/headless` → new commands
**Status**: Open

**Summary**: No way to ask "where on screen is text X?" or "where are the
buttons?" without clicking. Forces agents to reinvent OCR and color
segmentation.

**Expected behavior**:
- `headless find-text "Training" --session <sess>` → returns all matches
  with bounding boxes
- `headless find-buttons --session <sess>` → returns button regions with
  colors and OCR'd text

---

### LIMITATION-003 — No explicit `--cwd` flag for `headless exec`

**Priority**: P2
**Component**: `bin/headless` → `cmd_exec`
**Status**: Partially fixed (auto `--chdir` to exe_dir, but no override flag)

**Summary**: `headless exec` automatically sets `--chdir <exe_dir>` in
bwrap (fixed in commit `d13d12b`), but there's no `--cwd` flag for callers
who need a different working directory.

**Expected behavior**: `headless exec --cwd /custom/path app.exe` to
override the default exe_dir behavior.

---

### LIMITATION-004 — Console-subsystem apps produce no captured stdout

**Priority**: P2
**Component**: `bin/headless` → `cmd_exec`
**Status**: Open

**Summary**: PE32 console-subsystem apps (e.g. `zzcaster.exe`) launched
with plain `wine` don't get a Windows console, so `printf`/`cout` output
goes nowhere. `headless logs` returns empty.

**Expected behavior**: At minimum, emit a warning in the JSON response
when `subsystem == 3` and `HEADLESS_USE_WINECONSOLE` is not set. The
opt-in `HEADLESS_USE_WINECONSOLE=1` exists but defaults to off.

---

### LIMITATION-005 — No `headless register-dll` command

**Priority**: P2
**Component**: `bin/headless` → new command
**Status**: Open

**Summary**: Some apps require native DLLs registered via `regsvr32`. The
only way is `headless exec regsvr32.exe` which creates a full session,
copies the wineprefix template (~700MB), and leaves the session around.

**Expected behavior**: `headless register-dll <path>` that runs `regsvr32`
against the template wineprefix directly and reports registered CLSIDs.

---

### LIMITATION-006 — No `headless drag`, `headless scroll`, or multi-key combos

**Priority**: P3
**Component**: `bin/headless` → input commands
**Status**: Open

**Summary**: Input commands limited to single clicks, single keypresses,
ASCII typing, and clipboard. Missing: mouse drag, scroll wheel, 3+ key
combos (e.g. `ctrl+shift+esc`), reliable Unicode typing.

**Expected behavior**:
- `headless drag <x1> <y1> <x2> <y2> --session <sess>`
- `headless scroll <amount> --session <sess>`
- `headless key ctrl+shift+esc --session <sess>`
- `headless type-unicode "日本語" --session <sess>`

---

### ENHANCEMENT-002 — Performance metrics in session output

**Priority**: P3
**Component**: `bin/headless` → session registry
**Status**: Open

**Summary**: No way to measure time-to-window, FPS, CPU/memory usage, or
screenshot latency. Matters for CI regression detection.

**Expected behavior**: `headless metrics <sess>` command returning a
snapshot, and optional `--metrics` flag on `exec` emitting metrics to
stderr during the run.

---

### ENHANCEMENT-003 — Smoke test should exercise COM and 32-bit apps

**Priority**: P2
**Component**: `bin/headless` → `run_verify` + `.github/workflows/main.yml`
**Status**: Open

**Summary**: `headless --verify` runs a minimal DX9 triangle (64-bit, no
COM, no audio). It passes even when Wow6432Node CLSIDs are missing, Wine
Mono hangs, or console apps produce no output.

**Expected behavior**: Add verification cases:
1. 32-bit DX9 triangle (exercises WoW64 rendering)
2. 32-bit app calling `CoCreateInstance(DxDiagProvider)` (exercises COM)
3. 32-bit console app printing to stdout (exercises console capture)
4. App loading data via relative path (exercises `--chdir`)

---

## Release Planning

### v1.1.0 — Reliability (COMPLETE)

All P0/P1 bugs and docs resolved:
- BUG-001 through BUG-008
- ENHANCEMENT-001 (`--wait` flag)
- DOCS-001, DOCS-002

### v1.2.0 — Agent UX

Focus on reducing agent round-trips:
- LIMITATION-001 (click-text)
- LIMITATION-002 (find-text, find-buttons)
- LIMITATION-004 (console app output warning)
- LIMITATION-003 (--cwd flag)

### v1.3.0 — Real-world app coverage

- ENHANCEMENT-003 (expanded smoke test)
- LIMITATION-005 (register-dll command)
- LIMITATION-006 (drag, scroll, multi-key)

### v1.4.0 — Polish

- ENHANCEMENT-002 (performance metrics)

---

## How to Contribute

Since issue tracking is not currently enabled on the repository, please
add new entries to this file following the format below. When fixing an
issue, move it to the "Resolved in vX.Y.Z" section with the commit SHA.

### Entry template

```markdown
### <TYPE>-<NNN> — <short title>

**Priority**: P0|P1|P2|P3
**Component**: <file or module>
**Status**: Open | Fixed in <commit> | Resolved in vX.Y.Z

**Summary**: <1-2 paragraph description>

**Expected behavior**: <what should happen>

**Fix** (if resolved): <description of the fix>
```
