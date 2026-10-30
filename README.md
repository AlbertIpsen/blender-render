# BlenderRender

Drop a `.blend` on a Mac, render it on a Windows PC with an NVIDIA GPU, and get the results back.

- `BlenderRenderApp/`: the macOS app (SwiftUI)
- `pc/`, `remote_gpu.py`, `progress.py`: scripts the app installs on the render PC
- `setup_windows_pc.ps1`: one-time PC setup (the app fills in the Mac's SSH key; see Help > Set Up a Render PC)
- `mcp/`: lets Claude queue renders
- `remote_render.sh`, `render_status.sh`: command-line rendering (copy `remote_render.env.example` to `remote_render.env`)

## Install

Needs macOS 14+, Blender in `/Applications`, and repo access, because the app updates itself from this private repo through the GitHub CLI.

```bash
brew install gh
gh auth login
gh release download --repo AlbertIpsen/blender-render --pattern BlenderRender.zip --dir /tmp --clobber
ditto -x -k /tmp/BlenderRender.zip /Applications
```

## Publish an update

Make your changes, then:

```bash
./release.sh "What changed"
```

Everyone's app shows "Update & Restart" within 6 hours, or at the next launch. BlenderRender > Check for Updates… checks right away.

If you change the PC scripts, bump `protocolVersion` in `RenderPC.swift` and the version in `pc/rq.py`, so PCs that are already set up get them.
