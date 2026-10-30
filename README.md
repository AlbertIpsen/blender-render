# BlenderRender

Drop a `.blend` on a Mac, render it on a Windows PC with an NVIDIA GPU, and get the results back.

- `BlenderRenderApp/`: the macOS app (SwiftUI)
- `pc/`, `remote_gpu.py`, `progress.py`: scripts the app installs on the render PC
- `setup_windows_pc.ps1`: one-time PC setup (the app fills in the Mac's SSH key; see Help > Set Up a Render PC)
- `mcp/`: lets Claude queue renders
- `remote_render.sh`, `render_status.sh`: command-line rendering (copy `remote_render.env.example` to `remote_render.env`)

## Install

Needs macOS 14+ and Blender in `/Applications`. The app is downloaded and updated from the public [blender-render-releases](https://github.com/AlbertIpsen/blender-render-releases) repo, which holds only the zip, so no GitHub account is needed.

## Several PCs

In Settings, choose Add PC… and follow the three steps. With two or more PCs switched on, the add sheet offers to split an animation between them.

The Mac hands each PC a batch of frames at a time (`Splitter.swift`), so faster PCs do more, and a PC that drops out loses only its current batch. Videos render as PNG frames and the Mac's Blender joins them, so the Mac has to stay on until the job is done. Every PC needs the same Blender major.minor version as the Mac. Stills and unsplit jobs go to the main PC.

## Publish an update

Make your changes, then:

```bash
./release.sh "What changed"
```

Everyone's app shows "Update & Restart" within 6 hours, or at the next launch. BlenderRender > Check for Updates… checks right away.

If you change the PC scripts, bump `protocolVersion` in `RenderPC.swift` and the version in `pc/rq.py`, so PCs that are already set up get them.
