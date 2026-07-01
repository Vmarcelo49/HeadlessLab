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
**Resolved in**: v1.2.0 (commit pending)

**Summary**: `headless click <x> <y>` requires the caller to know pixel
coordinates. To obtain them, an agent must screenshot, run OCR externally,
do color-based region detection for low-contrast buttons, and compute
bounding box centers — a 6-step pipeline reimplemented per session.

**Fix**: Added `headless click-text "<text>"` command with 3-tier OCR
fallback strategy:
1. Full-screen OCR with tesseract TSV bounding boxes (PSM 11)
2. 2x upscale + retry (for small text)
3. Color-based button detection + per-button OCR (for low-contrast buttons)

Supports `--index N` (which match to click), `--fuzzy` (partial match),
`--dry-run` (return coordinates without clicking). Returns JSON with
text, x, y, width, height, confidence, method, and clicked status.

Validated with test image: "Training" found via strategy 1 (conf 96%),
"Host" found via strategy 3 button_color (low-contrast red button).

---

### LIMITATION-002 — No `find-text` or `find-buttons` helpers

**Priority**: P2
**Component**: `bin/headless` → new commands
**Resolved in**: v1.2.0 (commit pending)

**Summary**: No way to ask "where on screen is text X?" or "where are the
buttons?" without clicking. Forces agents to reinvent OCR and color
segmentation.

**Fix**: Added two new commands:
- `headless find-text "<text>" --session <sess>` — finds all occurrences of
  text via the same 3-tier OCR fallback as click-text (full-screen OCR,
  2x upscale, color-based button detection). Returns all matches with
  bounding boxes, confidence, and method. Supports `--fuzzy`.
- `headless find-buttons --session <sess>` — finds all colored button
  regions via color detection, returns each with bounding box, dominant
  color, and OCR'd text.

Validated: find-text "Training" returns 1 OCR match; find-text "e" fuzzy
returns 5 matches (3 OCR + 2 button_color); find-buttons returns 2 red
buttons ("Host Game" and "Join Game").

---

### LIMITATION-003 — No explicit `--cwd` flag for `headless exec`

**Priority**: P2
**Component**: `bin/headless` → `cmd_exec`
**Resolved in**: v1.2.0 (commit pending)

**Summary**: `headless exec` automatically sets `--chdir <exe_dir>` in
bwrap (fixed in commit `d13d12b`), but there's no `--cwd` flag for callers
who need a different working directory.

**Fix**: Added `--cwd <path>` flag to `headless exec`. When set, the bwrap
sandbox chdirs to the custom path instead of the EXE's directory. The
custom path is also bind-mounted so it's accessible inside the sandbox.
Returns `CWD_NOT_FOUND` error if the path doesn't exist.

Example: `headless exec --cwd /path/to/data app.exe`

---

### LIMITATION-004 — Console-subsystem apps produce no captured stdout

**Priority**: P2
**Component**: `bin/headless` → `cmd_exec`
**Resolved in**: v1.2.0 (commit pending)

**Summary**: PE32 console-subsystem apps (e.g. `zzcaster.exe`) launched
with plain `wine` don't get a Windows console, so `printf`/`cout` output
goes nowhere. `headless logs` returns empty.

**Fix**: `cmd_exec` now emits a `warning` field in the JSON response when
`pe_subsystem == 3` and `HEADLESS_USE_WINECONSOLE` is not set:

```json
{
  "status": "ok",
  "session_id": "sess_xxx",
  "pid": 1234,
  "arch": "i386",
  "subsystem": 3,
  "warning": "Console-subsystem app launched without wineconsole. stdout/stderr may not be captured in 'headless logs'. Set HEADLESS_USE_WINECONSOLE=1 to enable a visible Wine console window."
}
```

---

### LIMITATION-005 — No `headless register-dll` command

**Priority**: P2
**Component**: `bin/headless` → new command
**Resolved in**: v1.2.0 (commit pending)

**Summary**: Some apps require native DLLs registered via `regsvr32`. The
only way was `headless exec regsvr32.exe` which creates a full session,
copies the wineprefix template (~700MB), and leaves the session around.

**Fix**: Added `headless register-dll <path>` command that runs `regsvr32`
directly against the template wineprefix (not a session copy). Supports
both Unix paths (auto-converted to Z:\\ paths) and Windows paths.
Auto-detects architecture from PE header (or `--arch i386|x86_64`).
Returns `REGISTER_FAILED` or `REGISTER_TIMEOUT` on errors.

---

### LIMITATION-006 — No `headless drag`, `headless scroll`, or multi-key combos

**Priority**: P3
**Component**: `bin/headless` → input commands
**Resolved in**: v1.2.0 (commit pending)

**Summary**: Input commands were limited to single clicks, single keypresses,
ASCII typing, and clipboard. Missing: mouse drag, scroll wheel, 3+ key
combos, reliable Unicode typing.

**Fix**: Added 4 new input commands:
- `headless drag <x1> <y1> <x2> <y2>` — mouse drag with smooth 10-step
  movement, configurable `--button` and `--duration`
- `headless scroll <amount>` — scroll wheel (positive=down, negative=up)
- `headless key ctrl+shift+esc` — multi-key combos via keydown/keyup
  (existing `key` command enhanced, no new command needed)
- `headless type-unicode "日本語"` — Unicode typing via clipboard + Ctrl+V

---

### ENHANCEMENT-002 — Performance metrics in session output

**Priority**: P3
**Component**: `bin/headless` → new command
**Resolved in**: v1.2.0 (commit pending)

**Summary**: No way to measure time-to-window, FPS, CPU/memory usage, or
screenshot latency. Matters for CI regression detection.

**Fix**: Added `headless metrics <sess>` command returning:
- `uptime_s`: session uptime in seconds
- `process.cpu_time_s`: total CPU time
- `process.rss_mb`: resident set size in MB
- `process.alive`: whether the root PID is still alive
- `process.wine_process_count`: processes under the prefix
- `process.user_process_count`: non-helper processes
- `screenshot.capture_ms`: time to capture a screenshot
- `screenshot.unique_colors_sampled`: rendering health indicator

---

### ENHANCEMENT-003 — Smoke test should exercise COM and 32-bit apps

**Priority**: P2
**Component**: `bin/headless` → `run_verify`
**Resolved in**: v1.2.0 (commit pending)

**Summary**: `headless --verify` ran only a minimal 64-bit DX9 triangle.
It passed even when Wow6432Node CLSIDs were missing, Wine Mono hung, or
console apps produced no output.

**Fix**: `run_verify` now runs additional verification cases after the
main DX9 triangle test:
1. 32-bit DX9 triangle (`dx9_triangle_32.exe`) — exercises WoW64 rendering
2. Console app (`hello_win.exe`) — exercises console subsystem detection
   and stdout capture

Each case runs in its own display, captures a screenshot, and reports
[OK]/[WARN] status. Non-blocking: failures are warnings, not hard errors.

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
