# Feature Proposal: `headless record` — Video Recording for Motion Detection

## Why This Feature is Critical

### The Problem

Right now, agents can only take **single static screenshots**. This creates a
fundamental blind spot: **agents cannot see motion**. For games and interactive
apps, motion IS the state:

| Scenario | What a single screenshot shows | What the agent needs to see |
|----------|-------------------------------|---------------------------|
| Loading screen | "Now Loading..." text | Whether the bar is progressing or frozen |
| Character select | Static menu | Whether cursor moves when pressing keys |
| Fight started | Two characters on screen | Whether characters are animating (game didn't hang) |
| Menu transition | Blank or old menu | Whether transition is happening or app froze |
| Error dialog | Dialog visible | Whether dialog auto-dismisses after timeout |
| Netplay connection | "Connecting..." text | Whether connection indicator is changing |

Without motion, agents must **guess** whether the app is progressing or hung.
They take a screenshot, wait 2s, take another, and diff manually — expensive
and unreliable. A 3-second video clip would answer the question instantly.

### Evidence from Our MBAACC Testing

During our testing of MBAA.exe and zzcaster.exe, we hit this exact problem
multiple times:

1. **MBAA.exe crash detection**: We couldn't tell if the game was loading or
   crashed for ~15 seconds. A 3-second recording would have shown "nothing
   changes" = crashed.

2. **zzcaster Training mode**: After clicking "Training", we couldn't tell if
   MBAA.exe launched successfully or if it was still loading. A recording
   would have shown the transition.

3. **Wine Mono installer**: The dialog appeared "stable" in screenshots but
   was actually hung. A recording would have shown zero pixel changes over
   10 seconds = hung.

4. **DX9 triangle smoke test**: We verify >100 colors, but can't verify the
   triangle is actually **rotating** (the example animates). A recording
   would prove the render loop is running.

### What Agents Currently Do (Workaround)

```bash
headless screenshot --session $SESS --out /tmp/shot1.png
sleep 2
headless screenshot --session $SESS --out /tmp/shot2.png
# Manually diff the two PNGs with Python
# Still can't tell if motion happened between captures
```

This is 3 round-trips, ~5 seconds, and only catches changes between 2 frames.
A recording captures ALL frames in the interval.

---

## Proposed Interface

### `headless record` — Capture a short video clip

```bash
# Record 3 seconds at 10 fps (default)
headless record --session sess_xxx --out /tmp/clip.mp4

# Record 5 seconds at 15 fps
headless record --session sess_xxx --out /tmp/clip.mp4 --duration 5 --fps 15

# Record a specific window instead of full screen
headless record --session sess_xxx --out /tmp/clip.mp4 --window 0x02a00003

# Record as animated GIF (smaller, no audio, good for docs)
headless record --session sess_xxx --out /tmp/clip.gif --format gif

# Record and also capture a frame-by-frame diff report
headless record --session sess_xxx --out /tmp/clip.mp4 --analyze
```

### JSON Response

```json
{
  "status": "ok",
  "path": "/tmp/clip.mp4",
  "duration_s": 3.0,
  "fps": 10,
  "frames_captured": 30,
  "file_size": 245680,
  "format": "mp4",
  "analysis": {
    "frames_changed": 18,
    "frames_unchanged": 12,
    "motion_detected": true,
    "motion_ratio": 0.6,
    "first_change_frame": 3,
    "last_change_frame": 29,
    "average_diff_per_frame": 0.15
  }
}
```

### `headless record-gif` — Convenience alias for GIF output

```bash
headless record-gif --session sess_xxx --out /tmp/clip.gif
# Same as: headless record --session sess_xxx --out /tmp/clip.gif --format gif
```

---

## Implementation Plan

### Phase 1: Basic MP4 Recording (~150 LOC)

**Approach**: Capture frames via python-xlib (31.6 fps proven), pipe to
ffmpeg for encoding.

```python
def cmd_record(args):
    """Record a short video clip of the virtual display."""
    display = _resolve_display(args, required_session=True)
    duration = getattr(args, 'duration', 3.0)
    fps = getattr(args, 'fps', 10)
    out_path = args.out
    fmt = getattr(args, 'format', None)  # auto-detect from extension
    analyze = getattr(args, 'analyze', False)
    window_id = getattr(args, 'window', None)

    # Auto-detect format from extension
    if fmt is None:
        if out_path.endswith('.gif'):
            fmt = 'gif'
        elif out_path.endswith('.webm'):
            fmt = 'webm'
        else:
            fmt = 'mp4'

    # Connect to X display
    from Xlib.display import Display as XlibDisplay
    from Xlib import X
    from PIL import Image
    import io

    disp = XlibDisplay(display)
    root = disp.screen().root

    # If window specified, capture that window; else capture root
    if window_id:
        target = disp.create_resource_object('window', int(window_id, 16))
        geom = target.get_geometry()
    else:
        target = root
        geom = root.get_geometry()

    width, height = geom.width, geom.height

    # Start ffmpeg process
    if fmt == 'gif':
        ffmpeg_args = [
            'ffmpeg', '-y',
            '-f', 'rawvideo',
            '-pixel_format', 'rgb24',
            '-video_size', f'{width}x{height}',
            '-framerate', str(fps),
            '-i', '-',  # read from stdin
            '-vf', f'fps={fps},split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse',
            '-loop', '0',
            out_path
        ]
    elif fmt == 'webm':
        ffmpeg_args = [
            'ffmpeg', '-y',
            '-f', 'rawvideo',
            '-pixel_format', 'rgb24',
            '-video_size', f'{width}x{height}',
            '-framerate', str(fps),
            '-i', '-',
            '-c:v', 'libvpx-vp9',
            '-b:v', '500k',
            '-crf', '35',
            out_path
        ]
    else:  # mp4
        ffmpeg_args = [
            'ffmpeg', '-y',
            '-f', 'rawvideo',
            '-pixel_format', 'rgb24',
            '-video_size', f'{width}x{height}',
            '-framerate', str(fps),
            '-i', '-',
            '-c:v', 'libx264',
            '-preset', 'fast',
            '-crf', '28',
            '-pix_fmt', 'yuv420p',
            out_path
        ]

    proc = subprocess.Popen(
        ffmpeg_args,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE
    )

    # Capture frames and pipe to ffmpeg
    total_frames = int(duration * fps)
    frame_interval = 1.0 / fps
    frames_captured = 0
    prev_pixels = None
    analysis = {'frames_changed': 0, 'frames_unchanged': 0} if analyze else None

    start_time = time.time()
    for i in range(total_frames):
        # Capture frame
        image = target.get_image(0, 0, width, height, X.ZPixmap, 0xFFFFFFFF)
        # Convert to RGB bytes
        if image.depth == 24:
            img = Image.frombytes("RGB", (width, height), image.data, "raw", "BGRX")
        elif image.depth == 32:
            img = Image.frombytes("RGBA", (width, height), image.data, "raw", "BGRA")
            img = img.convert("RGB")

        frame_bytes = img.tobytes()

        # Write to ffmpeg
        try:
            proc.stdin.write(frame_bytes)
        except BrokenPipeError:
            break

        frames_captured += 1

        # Optional: analyze motion
        if analyze and prev_pixels is not None:
            # Sample every 100th pixel for speed
            curr_sample = frame_bytes[::300]
            prev_sample = prev_pixels[::300]
            changed = sum(1 for a, b in zip(curr_sample, prev_sample) if abs(a - b) > 10)
            total = len(curr_sample)
            if changed / total > 0.01:  # >1% pixels changed
                analysis['frames_changed'] += 1
            else:
                analysis['frames_unchanged'] += 1

        prev_pixels = frame_bytes

        # Wait for next frame interval
        elapsed = time.time() - start_time
        expected = (i + 1) * frame_interval
        if elapsed < expected:
            time.sleep(expected - elapsed)

    # Close ffmpeg
    proc.stdin.close()
    proc.wait(timeout=10)

    # Build response
    response = {
        "status": "ok",
        "path": out_path,
        "duration_s": duration,
        "fps": fps,
        "frames_captured": frames_captured,
        "format": fmt,
    }

    if os.path.exists(out_path):
        response["file_size"] = os.path.getsize(out_path)

    if analyze:
        analysis['motion_detected'] = analysis['frames_changed'] > 0
        analysis['motion_ratio'] = (
            analysis['frames_changed'] / frames_captured if frames_captured > 0 else 0
        )
        response["analysis"] = analysis

    print_json(response)
```

### Phase 2: Motion Analysis Mode (~50 LOC)

The `--analyze` flag adds frame-by-frame diff reporting:

```json
{
  "analysis": {
    "frames_changed": 18,
    "frames_unchanged": 12,
    "motion_detected": true,
    "motion_ratio": 0.6,
    "first_change_frame": 3,
    "last_change_frame": 29,
    "average_diff_per_frame": 0.15
  }
}
```

This lets agents programmatically answer "is the app animating?" without
watching the video. Key use cases:

- `motion_detected: false` over 3 seconds → app is hung/frozen
- `motion_ratio: 0.0` → screen completely static (crashed or waiting)
- `motion_ratio: 1.0` → full-screen animation (loading, transition)
- `motion_ratio: 0.05-0.2` → subtle animation (cursor blink, timer)

### Phase 3: Wait-for-Motion Command (~80 LOC)

```bash
# Wait until the screen starts changing (app started rendering)
headless wait-motion --session sess_xxx --timeout 10000

# Wait until the screen STOPS changing (app finished loading)
headless wait-motion --session sess_xxx --timeout 10000 --stop
```

```json
{
  "status": "ok",
  "motion_detected": true,
  "elapsed_ms": 1240,
  "frames_checked": 12
}
```

This complements `wait-window` (which waits for a window to appear) by
waiting for actual rendering to start/stop. Use cases:

- `wait-motion` → "wait until the app starts rendering" (loading screen appears)
- `wait-motion --stop` → "wait until loading completes" (screen stops changing)
- `wait-motion --timeout 5000` → "if nothing moves in 5s, the app is hung"

### Phase 4: Screenshot Diff Command (~60 LOC)

```bash
# Compare two screenshots
headless diff-shots --session sess_xxx --base /tmp/shot1.png --compare /tmp/shot2.png

# Take a screenshot and compare against a base
headless diff-shots --session sess_xxx --base /tmp/expected.png --out /tmp/current.png
```

```json
{
  "status": "ok",
  "identical": false,
  "diff_percent": 2.3,
  "diff_pixels": 41472,
  "threshold": 1.0,
  "changed": true,
  "message": "Screenshots differ by 2.3% (> 1.0% threshold)"
}
```

Use cases:
- "Did clicking that button change the screen?"
- "Does the current state match the expected baseline?"
- "Is the app still on the loading screen?"

---

## Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `ffmpeg` | ✅ Available (`/usr/bin/ffmpeg` 7.1.4) | For video encoding (mp4, webm, gif) |
| `python-xlib` | ✅ Available | For frame capture (31.6 fps proven) |
| `Pillow` | ✅ Available | For pixel format conversion |
| `libx264` | ⚠️ Check | For mp4 encoding (may need to install) |
| `libvpx` | ⚠️ Check | For webm encoding |

**No new dependencies needed for the core feature.** If libx264/libvpx are
missing, fall back to GIF or uncompressed AVI.

---

## Performance Considerations

- **Capture rate**: 31.6 fps via python-xlib (measured). Default 10 fps is
  well within budget.
- **Memory**: Each 1920x1080 RGB frame is ~6MB. At 10 fps for 3 seconds =
  30 frames = ~180MB peak. ffmpeg processes frames as they arrive (streaming),
  so memory stays low (~12MB for 2 frames in flight).
- **Disk**: A 3-second mp4 at 10 fps is ~200-500KB. A GIF is ~1-3MB.
- **CPU**: Frame capture is cheap (Xlib get_image). ffmpeg encoding is the
  bottleneck but runs in a separate process.

---

## Use Cases for LLM Agents

### 1. "Did the app crash or is it just loading?"

```bash
headless record --session $SESS --out /tmp/check.mp4 --duration 3 --analyze
# If motion_ratio == 0.0, app is likely hung/crashed
# If motion_ratio > 0.0, app is still rendering (loading)
```

### 2. "Did clicking that button do anything?"

```bash
headless record --session $SESS --out /tmp/before_click.mp4 --duration 1 --analyze
headless click-text "Training" --session $SESS
headless record --session $SESS --out /tmp/after_click.mp4 --duration 3 --analyze
# Compare motion_ratio before and after
```

### 3. "Wait for loading to finish"

```bash
headless wait-motion --session $SESS --timeout 30000 --stop
# Returns when screen stops changing for 2 seconds
```

### 4. "Verify the game is actually running (not just showing a static frame)"

```bash
# After launching a game
headless record --session $SESS --out /tmp/verify.mp4 --duration 5 --analyze
# motion_detected: true confirms the render loop is active
```

### 5. "Capture a bug for documentation"

```bash
headless record --session $SESS --out /tmp/bug.gif --duration 10 --format gif
# GIF can be embedded in issues/reports
```

---

## Comparison with Alternatives

| Approach | Pros | Cons |
|----------|------|------|
| **`headless record` (proposed)** | One command, motion analysis, works headless | Adds ~300 LOC, needs ffmpeg |
| Manual screenshot diffing | No new code | 3+ round-trips, misses between-frame motion, unreliable |
| ffmpeg x11grab directly | No Python overhead | Needs X11 auth, no JSON output, no session awareness |
| VNC recording | Standard tooling | Requires VNC server setup, heavy, not headless-native |

---

## Implementation Priority

| Phase | LOC | Risk | Value | Priority |
|-------|-----|------|-------|----------|
| Phase 1: Basic MP4 | ~150 | Low (ffmpeg + xlib proven) | High | P1 |
| Phase 2: Motion analysis | ~50 | Low (pixel diffing) | High | P1 |
| Phase 3: Wait-for-motion | ~80 | Medium (timing logic) | Medium | P2 |
| Phase 4: Screenshot diff | ~60 | Low | Medium | P2 |

**Total**: ~340 LOC across 4 phases. All phases are independent — Phase 1
alone delivers the core value (video + basic analysis).

---

## Testing Plan

1. **Unit test**: Record a 3-second clip of the Xvfb root window with known
   content, verify mp4 is non-empty and playable
2. **Motion detection test**: Create a test image that changes every 500ms,
   verify `motion_detected: true` and `motion_ratio > 0.5`
3. **Static detection test**: Record a static image for 3s, verify
   `motion_detected: false` and `motion_ratio == 0.0`
4. **GIF test**: Record as GIF, verify it's a valid animated GIF
5. **Integration test**: Launch dx9_triangle.exe, record 5s, verify
   `motion_detected: true` (triangle is animating)
6. **Performance test**: Verify 10 fps capture doesn't exceed 50% CPU
