# BlenderRender

Drop a `.blend` on a Mac, render it on the other computers on your network (Windows PCs with an NVIDIA GPU, and other Macs), and get the results back.

- `BlenderRenderApp/`: the macOS app (SwiftUI)
- `pc/`: the render queue every computer runs (`rq.py`), its network side (`rqnet.py`) and `pc/BlenderRenderPC.exe`; with `remote_gpu.py` and `progress.py`
- `pc-app/`: BlenderRender PC, the Windows tray app (C#, .NET Framework 4.8); `pc-app/build.sh` rebuilds the exe
- `setup_windows_pc.ps1`: one-time PC setup, run by BlenderRender PC (or by hand, with the Mac's SSH key filled in)
- `mcp/`: lets Claude queue renders
- `remote_render.sh`, `render_status.sh`: command-line rendering (copy `remote_render.env.example` to `remote_render.env`)

## Install

**Downloads** (always the latest version):

- Mac: [BlenderRender.zip](https://github.com/AlbertIpsen/blender-render/releases/latest/download/BlenderRender.zip)
- Windows PC: [BlenderRenderPC.exe](https://github.com/AlbertIpsen/blender-render/releases/latest/download/BlenderRenderPC.exe)

Needs macOS 14+ and Blender in `/Applications`. Both apps download their updates from this repo's releases, so no GitHub account is needed. The first time it looks for other computers, macOS asks to allow BlenderRender on the local network: choose **Allow**.

## Set up a Windows render PC

About 10 minutes, once per PC. You need to be at the PC, or connected to it with AnyDesk. The same steps are in the app under Help > Set Up a Render PC.

**Before you start, on the PC**

1. Install the same Blender version as the Mac (major.minor, e.g. 5.2) from blender.org, in its default folder. A Steam install works too.
2. Install the latest NVIDIA Studio or Game Ready driver.
3. Connect the PC to the same network as the Mac, with Ethernet if you can: frames come back much faster than over Wi-Fi.

**1. Download BlenderRender PC on the PC.** Open [github.com/AlbertIpsen/blender-render/releases/latest/download/BlenderRenderPC.exe](https://github.com/AlbertIpsen/blender-render/releases/latest/download/BlenderRenderPC.exe) in a browser on the PC.

- If the browser says the file isn't commonly downloaded, choose **Keep**.
- If Windows says it protected your PC, click **More info**, then **Run anyway**. The app isn't signed by a publisher Windows knows.
- Click **Set Up This PC** and choose **Yes** when Windows asks for permission. Over AnyDesk, that prompt may only show on the PC's own screen.

**2. Add it on the Mac.** In BlenderRender, open Settings and click **Add PC…**: it lists every computer with BlenderRender on the network. Click **Add** next to the PC. (The Render PCs panel lists them too.) Every Mac with BlenderRender on the network sees it and can add it.

**3. Keep the PC ready.** Renders run only while the PC is on, awake and logged in.

- In Windows Settings > System > Power, set sleep to **Never** when plugged in.
- In your router, give the PC a fixed (reserved) IP address, so the address the Mac saved keeps working.
- BlenderRender PC sits in the taskbar corner and starts at logon. Its switch, **Allow this computer to do render jobs**, stops the PC taking render jobs, for example while you play a game on it.

**What setup changes on the PC**

- Creates `C:\GeysierRender` (render files, plus the queue in `C:\GeysierRender\queue`).
- Adds two scheduled tasks that start at logon: `BlenderRenderQueue` (renders the jobs, and keeps `rqnet.py` running so Macs can reach the queue) and `BlenderRenderPC` (the taskbar app).
- Opens TCP port 48211 for private networks only, for the Macs.
- With the script from the Mac: also turns on Windows' OpenSSH server for that Mac's key (port 22, private networks).

**If the Mac can't connect**

- **Network set to Public:** the firewall rule only covers private networks, and setup warns about this at the end. Fix it in Settings > Network & internet > your connection > Properties > **Private network**.
- **Address changed:** the PC got a new IP address. Reserve one in the router, then update the address in Settings on the Mac.
- **PC asleep or logged out:** wake it and log in. The queue only runs in a logged-in session.
- **It doesn't show up under On This Network:** check BlenderRender PC is running (its icon in the taskbar corner) and both are on the same network, and that macOS allowed BlenderRender on the local network (System Settings > Privacy & Security > Local Network).
- **Blender not found:** BlenderRender PC says so. Install Blender in its default folder and click **Set Up This PC** again.
- **Different Blender version:** a PC with another major.minor version than the Mac is left out of split jobs. Install the matching version.

## The queue

Every job waits under Waiting to Start until you press Start: one added in the app, one from Claude (the connector asks the app to hold it, `Held.swift`), and one sent straight to a PC (`rq receive` holds it there unless the options say `start_now`). While it waits, its PCs menu chooses who renders it: one PC renders the whole job and doesn't need this Mac; two or more split an animation. This Mac is always on the list: it runs the same `rq.py` in `~/Library/Application Support/BlenderRender/thismac` with its own Blender on Metal. **Pause All** in the toolbar freezes every render where it is (`rq pause` suspends Blender, so no samples are lost) and starts nothing new until Resume All. It's kept across launches, and a PC that was offline gets it when it's back. It's separate from a PC's own switch in BlenderRender PC. A cancelled or failed job has **Render Again**: it goes back under Waiting to Start with the same settings, its .blend fetched from its PC (`rq blend`) or, for a split job, kept on this Mac until the job is removed. Every cancel and remove is written to `cancel.log`, in that folder and on the PC, with what asked for it.

## Computers on the network

Every computer's queue runs `rqnet.py` next to `rq.py` (the worker keeps it running). It says who it is every 5 seconds on UDP port 48210 (`Discovery.swift` listens) and answers rq commands from other computers on TCP port 48211; the Mac app sends them through `rqnet.py call`, so a computer added from the network is used exactly like one over SSH. Only queue commands are accepted, and sending work (receive, batch, cache-put) only while the computer allows render jobs: the `share` flag, minus a PC's own off switch. Anyone on the same network with BlenderRender can use a computer that allows it; switching it off is the way to say no. On a Mac, **Allow this computer to do render jobs** (Settings and the Render PCs panel) shares This Mac's own queue, off by default. A computer's address is kept up to date from what it says, so DHCP changes don't matter. All render computers are alike: there's no main PC. Settings from before kept one in `host`/`user`; the app moves it into the list on launch (keeping its id, `main`, so its jobs stay with it). A PC set up the older way, by address over SSH, keeps working that way until it runs the current scripts and is heard on the network; then the app talks to it over the network instead, by itself, and SSH is no longer needed on it. Until then, when the app updates its scripts over SSH it also opens its port, turns sharing on and restarts its worker.

While the Setup Guide is open, the Mac serves a page on the local network (`SetupServer.swift`) at an address like `192.168.1.20/4821`. Opened in a browser on the PC, it offers BlenderRender PC.exe with the setup script attached; the app runs the script with one admin prompt and the script sends its pairing code back. The same address also works as a PowerShell line, `iex (irm 192.168.1.20/4821)`. The code changes each time and a few wrong tries turn it off; it's plain HTTP, so use Copy Script on a network you don't trust.

The Mac app is the coordinator (`Splitter.swift`): a PC that's free asks for work and gets a batch cut to about 5 minutes at its measured speed, so faster PCs do more and a PC busy with another job is left alone. A PC renders one job at a time, in queue order: a job waits only for earlier jobs on the same PCs, until every frame of theirs is back (the Mac joining the video doesn't hold it up). A PC that drops out loses only its current batch. While rendering, a PC holds itself awake, and during a split the Mac nudges every PC each minute so none sleeps between batches (Settings > Keep all computers awake while rendering). Videos render as PNG frames and the Mac's Blender joins them, so the Mac has to stay on until the job is done. Every PC needs the same Blender major.minor version as the Mac. A job with one PC switched on goes there whole instead: that PC renders the video itself, so the Mac can be shut down and the result downloaded later. Stills go to one PC too.

Claude's `queue_render` hands animations to the app through a folder (`inbox` in the app's support folder), so they split the same way. If the app doesn't answer, the job is held on the first render computer in the list. The connector reaches every computer the way the app does, so its status lists the jobs on all of them, with where each one is.

## BlenderRender PC (the Windows app)

Sits in the taskbar corner of every render PC and starts at logon (scheduled task BlenderRenderPC). Its switch, Allow this computer to do render jobs, turns the PC off for rendering (`rq off`): jobs that arrive wait, Macs leave the PC out of new splits, and a split batch it hasn't started goes to another computer. Switching off during a render asks whether to stop now (the render goes back in line) or let it finish.

Its window says whether the PC is rendering (and for which Mac) or on standby, and which Macs are connected: every rq call names its Mac (`BR_FROM`, base64 in `BR_FROM_B64` over SSH), kept in `clients.json`, and each job records who sent it. **Check for updates** looks on GitHub right away; it shows its version next to the computer name.

It carries the queue scripts and its own setup script, so it sets a new PC up without a Mac. It keeps itself up to date: every 6 hours it puts newer scripts it carries in place, and fetches `BlenderRenderPC.exe` from the latest public release when that's a different build, then restarts from it. `release.sh` rebuilds it (needs the .NET SDK, e.g. in `~/.dotnet`) and attaches it to every public release. To change it, edit `pc-app/Program.cs`; PCs still reached over SSH also get the new exe from the Mac when `protocolVersion` changes.

## Publish an update

Make your changes, then:

```bash
./release.sh "What changed"
```

Everyone's app shows "Update & Restart" within 6 hours, or at the next launch. BlenderRender > Check for Updates… checks right away.

If you change the PC scripts, bump `protocolVersion` in `RenderPC.swift` and the version in `pc/rq.py`, so PCs that are already set up get them.
