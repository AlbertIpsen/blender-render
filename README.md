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

In Settings, choose Add PC… and follow the three steps. While that window is open, the Mac serves the setup script on the local network (`SetupServer.swift`), so the PC only needs a short line like `iex (irm 192.168.1.20/4821)`, and the script sends its pairing code back when it finishes. The code changes each time and a few wrong tries turn it off; it's plain HTTP, so use Copy Script on a network you don't trust. With two or more PCs switched on, the add sheet offers to split an animation between them.

The Mac app is the coordinator (`Splitter.swift`): a PC that's free asks for work and gets a batch cut to about 5 minutes at its measured speed, so faster PCs do more and a PC busy with another job is left alone. Split jobs render one at a time, in queue order: the next one starts once every frame of the one ahead is back (the Mac joining the video doesn't hold it up). A PC that drops out loses only its current batch. While rendering, a PC holds itself awake, and during a split the Mac nudges every PC each minute so none sleeps between batches (Settings > Keep all computers awake while rendering). Videos render as PNG frames and the Mac's Blender joins them, so the Mac has to stay on until the job is done. Every PC needs the same Blender major.minor version as the Mac. Each job can instead go whole to one PC, chosen under Render on when it's added: that PC renders the video itself, so the Mac can be shut down and the result downloaded later. Stills go to one PC too.

Claude's `queue_render` hands animations to the app through a folder (`inbox` in the app's support folder), so they split the same way. If the app doesn't answer or fewer than two PCs can take part, the job goes to the main PC.

## Publish an update

Make your changes, then:

```bash
./release.sh "What changed"
```

Everyone's app shows "Update & Restart" within 6 hours, or at the next launch. BlenderRender > Check for Updates… checks right away.

If you change the PC scripts, bump `protocolVersion` in `RenderPC.swift` and the version in `pc/rq.py`, so PCs that are already set up get them.
