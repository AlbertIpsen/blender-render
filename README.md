# BlenderRender

Drop a `.blend` on a Mac, render it on a Windows PC with an NVIDIA GPU, and get the results back.

- `BlenderRenderApp/`: the macOS app (SwiftUI)
- `pc/`, `remote_gpu.py`, `progress.py`: scripts the app installs on the render PC, and `pc/BlenderRenderPC.exe`
- `pc-app/`: BlenderRender PC, the Windows tray app (C#, .NET Framework 4.8); `pc-app/build.sh` rebuilds the exe
- `setup_windows_pc.ps1`: one-time PC setup (the app fills in the Mac's SSH key; see Help > Set Up a Render PC)
- `mcp/`: lets Claude queue renders
- `remote_render.sh`, `render_status.sh`: command-line rendering (copy `remote_render.env.example` to `remote_render.env`)

## Install

Needs macOS 14+ and Blender in `/Applications`. The app is downloaded and updated from the public [blender-render-releases](https://github.com/AlbertIpsen/blender-render-releases) repo, which holds only the zip, so no GitHub account is needed.

## Set up a Windows render PC

About 10 minutes, once per PC. You need to be at the PC, or connected to it with AnyDesk. The same steps are in the app under Help > Set Up a Render PC.

**Before you start, on the PC**

1. Install the same Blender version as the Mac (major.minor, e.g. 5.2) from blender.org, in its default folder. A Steam install works too.
2. Install the latest NVIDIA Studio or Game Ready driver.
3. Connect the PC to the same network as the Mac, with Ethernet if you can: frames come back much faster than over Wi-Fi.

**1. Open Add PC on the Mac.** In BlenderRender, open Settings and choose **Add PC…**. While that window is open, the Mac shows an address like `192.168.1.20/4821`.

**2. Run BlenderRender PC on the PC.** Open that address in a browser on the PC and download **BlenderRender PC**.

- If the browser says the file isn't commonly downloaded, choose **Keep**.
- If Windows says it protected your PC, click **More info**, then **Run anyway**. The app isn't signed by a publisher Windows knows.
- Click **Set Up This PC** and choose **Yes** when Windows asks for permission. Over AnyDesk, that prompt may only show on the PC's own screen.
- The first run can take a few minutes while Windows adds its SSH server.

When it's done, the PC appears in the Mac's Render PCs list by itself, and the Mac copies the render queue over the first time it connects.

**Prefer PowerShell?** Start PowerShell as administrator (Start > type PowerShell > right-click > **Run as administrator**) and type the line Add PC shows, e.g. `iex (irm 192.168.1.20/4821)`. If the PC isn't on the same network, choose **Copy Script** (AnyDesk shares the clipboard) or **Save as File…** in Help > Set Up a Render PC. Paste the script into the administrator PowerShell, or run the saved file with `powershell -ExecutionPolicy Bypass -File setup_windows_pc.ps1`. At the end it prints a line starting with `BR1:`. If it couldn't send that line to the Mac, paste it into Add PC.

**3. Keep the PC ready.** Renders run only while the PC is on, awake and logged in.

- In Windows Settings > System > Power, set sleep to **Never** when plugged in.
- In your router, give the PC a fixed (reserved) IP address, so the address the Mac saved keeps working.
- BlenderRender PC sits in the taskbar corner and starts at logon. Its switch stops the PC taking render jobs, for example while you play a game on it.

**What setup changes on the PC**

- Turns on Windows' OpenSSH server and opens port 22 for private networks only.
- Lets the Mac sign in with its SSH key, so no password is stored anywhere.
- Creates `C:\GeysierRender` (render files, plus the queue in `C:\GeysierRender\queue`).
- Adds two scheduled tasks that start at logon: `BlenderRenderQueue` (renders the jobs) and `BlenderRenderPC` (the taskbar app).

**If the Mac can't connect**

- **Network set to Public:** the firewall rule only covers private networks, and setup warns about this at the end. Fix it in Settings > Network & internet > your connection > Properties > **Private network**.
- **Address changed:** the PC got a new IP address. Reserve one in the router, then update the address in Settings on the Mac.
- **PC asleep or logged out:** wake it and log in. The queue only runs in a logged-in session.
- **Blender not found:** setup prints `WIN_BLENDER=NOT FOUND`. Install Blender in its default folder and run setup again (**Set up again…** in BlenderRender PC).
- **Different Blender version:** a PC with another major.minor version than the Mac is left out of split jobs. Install the matching version.

## The queue

Every job waits under Waiting to Start until you press Start: one added in the app, one from Claude (the connector asks the app to hold it, `Held.swift`), and one sent straight to a PC (`rq receive` holds it there unless the options say `start_now`). While it waits, its PCs menu chooses who renders it: one PC renders the whole job and doesn't need this Mac; two or more split an animation. This Mac is always on the list: it runs the same `rq.py` in `~/Library/Application Support/BlenderRender/thismac` with its own Blender on Metal. Every cancel and remove is written to `cancel.log`, in that folder and on the PC, with what asked for it.

## Several PCs

In Settings, choose Add PC… and follow the three steps. While that window is open, the Mac serves a page on the local network (`SetupServer.swift`) at an address like `192.168.1.20/4821`. Opened in a browser on the PC, it offers BlenderRender PC.exe with the setup script attached; the app runs the script with one admin prompt and the script sends its pairing code back. The same address also works as a PowerShell line, `iex (irm 192.168.1.20/4821)`. The code changes each time and a few wrong tries turn it off; it's plain HTTP, so use Copy Script on a network you don't trust. With two or more PCs switched on, the add sheet offers to split an animation between them.

The Mac app is the coordinator (`Splitter.swift`): a PC that's free asks for work and gets a batch cut to about 5 minutes at its measured speed, so faster PCs do more and a PC busy with another job is left alone. A PC renders one job at a time, in queue order: a job waits only for earlier jobs on the same PCs, until every frame of theirs is back (the Mac joining the video doesn't hold it up). A PC that drops out loses only its current batch. While rendering, a PC holds itself awake, and during a split the Mac nudges every PC each minute so none sleeps between batches (Settings > Keep all computers awake while rendering). Videos render as PNG frames and the Mac's Blender joins them, so the Mac has to stay on until the job is done. Every PC needs the same Blender major.minor version as the Mac. A job with one PC switched on goes there whole instead: that PC renders the video itself, so the Mac can be shut down and the result downloaded later. Stills go to one PC too.

Claude's `queue_render` hands animations to the app through a folder (`inbox` in the app's support folder), so they split the same way. If the app doesn't answer or fewer than two PCs can take part, the job goes to the main PC.

## BlenderRender PC (the Windows app)

Sits in the taskbar corner of every render PC and starts at logon (scheduled task BlenderRenderPC). Its switch turns the PC off for rendering (`rq off`): jobs that arrive wait, the Mac leaves the PC out of new splits, and a split batch it hasn't started goes to another PC. Switching off during a render asks whether to stop now (the render goes back in line) or let it finish. The Mac installs the app on PCs that were set up before it existed. To change it, edit `pc-app/Program.cs`, run `pc-app/build.sh` (needs the .NET SDK, e.g. in `~/.dotnet`) and bump `protocolVersion`, so PCs get the new exe; the running app restarts itself from it.

## Publish an update

Make your changes, then:

```bash
./release.sh "What changed"
```

Everyone's app shows "Update & Restart" within 6 hours, or at the next launch. BlenderRender > Check for Updates… checks right away.

If you change the PC scripts, bump `protocolVersion` in `RenderPC.swift` and the version in `pc/rq.py`, so PCs that are already set up get them.
