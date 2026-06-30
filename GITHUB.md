# Publishing HeadlessLab to GitHub

This document explains how to host HeadlessLab on GitHub. The Git repository is kept **scripts-only** (lightweight, ~150KB without host-debs/), while the heavy part (Wine prefix + llvmpipe + bwrap) is distributed as an **AppImage** asset in GitHub Releases.

| Content | Size | Destination | How |
|---------|---------|----------|------|
| Scripts + docs + examples + host-debs | ~105MB | Git repository (normal push) | `git push origin main` |
| Precompiled bundle (prefix/) | ~253MB | GitHub Release asset | Upload `HeadlessLab.AppImage` |

---

## Why this architecture?

1. **Git file size limits**: GitHub has a strict **100MB** limit per file. The `libLLVM.so.19.1` library inside `prefix/` is **124MB**, making it impossible to push uncompressed to a traditional repository.
2. **Release Assets**: GitHub allows uploads of up to 2GB per file in Releases. The ~253MB AppImage fits perfectly here.
3. **FUSE-free (No FUSE/Root dependency)**: In Docker containers for LLM agents or headless CI/CD servers, FUSE is frequently unavailable. The `setup.sh` script bypasses this by running the AppImage with the `--appimage-extract` flag, extracting the prefix locally without requiring special privileges or FUSE.

---

## Step-by-Step Guide

### 1. Prepare and Create the Repository on GitHub

Create an empty repository on GitHub (via Web UI or using the `gh` CLI).

### 2. Push the Scripts-Only Repository

To create the clean (scripts-only) version of the repository:

1. The `prefix/`, `wineprefix/`, and `rootfs/` folders are listed in `.gitignore` so they are not tracked.
2. Initialize the repository and make the initial push:

```bash
git init -b main
git add .
git commit -m "Initial commit: HeadlessLab scripts, docs, examples, and bundled host-debs"
git remote add origin https://github.com/Vmarcelo49/HeadlessLab.git
git push -u origin main
```

### 3. Package the AppImage

To generate the runtime AppImage for publication:

```bash
./bin/pack-appimage.sh
```

This will create the `HeadlessLab.AppImage` file (~253MB) in the root directory. The script automatically downloads `appimagetool` and compiles the prefix.

### 4. Create a GitHub Release and Upload the Asset

Create the version tag and publish the Release with the AppImage:

```bash
# Create tag
git tag v1.0.0
git push origin v1.0.0

# Upload the asset to the release using the GitHub CLI:
gh release create v1.0.0 \
    ./HeadlessLab.AppImage \
    --title "v1.0.0 — Initial release" \
    --notes "Mesa llvmpipe + Wine 10.0 + bwrap runtime bundle. See README.md for usage."
```

*(Alternatively, you can create the Release and upload the `HeadlessLab.AppImage` manually via the GitHub Web interface).*

### 5. Update URL in `setup.sh`

After creating the first release, edit `bin/setup.sh` to update the `BUNDLE_URL` variable with the actual asset download URL:

```bash
BUNDLE_URL="${DX9_BUNDLE_URL:-https://github.com/Vmarcelo49/HeadlessLab/releases/download/v1.0.0/HeadlessLab.AppImage}"
```

Push this minor change to the main branch.

---

## End-User / LLM Agent Workflow

When cloning the clean repository, the end-user only needs to run one command to rebuild the entire environment:

```bash
# 1. Clone the scripts-only repository (fast, ~150KB without host-debs)
git clone https://github.com/Vmarcelo49/HeadlessLab.git
cd HeadlessLab

# 2. Install bundled host deps (no sudo)
bash bin/install-host-deps.sh
source ~/.local/share/headlesslab/env.sh

# 3. Run setup (downloads the AppImage from Release and extracts it to prefix/)
./bin/setup.sh

# 4. Validate
./bin/headless --verify
```
