#!/usr/bin/env python3
"""BlenderRender connector for Claude: an MCP server (stdio) that queues .blend files on the render PC.

Jobs go to the BlenderRender Mac app (a folder in its inbox per request), where they wait in "Waiting to
Start" (job ids starting "held-") until Albert picks the PCs and presses Start; then they become a
split job ("split-", the same id) or a job on one PC. Without the app, a job goes straight into the
main PC's queue (remote/pc/rq.py) and is held there until Start in the app. Uses the app's own settings (~/Library/Application Support/BlenderRender/config.json),
packs textures with the Mac's Blender exactly like the app, and downloads into the app's folder.

Standard library only (macOS's Python 3.9). Register with Claude Code:
  claude mcp add --scope user blenderrender -- python3 /path/to/blenderrender_mcp.py
"""
import base64
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import traceback
import uuid
from pathlib import Path

SERVER = {"name": "blenderrender", "version": "1.0.0"}
PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
APP = Path("/Applications/BlenderRender.app")
CONFIG = Path.home() / "Library/Application Support/BlenderRender/config.json"
HERE = Path(__file__).resolve().parent
PACK_SCRIPT = next((p for p in (APP / "Contents/Resources/pack_inspect.py",
                                HERE.parent / "BlenderRenderApp/Resources/pack_inspect.py") if p.exists()), None)
APP_DEFAULTS = "com.geysier.blenderrender"
INBOX = CONFIG.parent / "inbox"
SPLITS = CONFIG.parent / "splits"
HELD = CONFIG.parent / "held"


class ToolError(Exception):
    """A problem to report to Claude as a tool result (isError), not a protocol error."""


# --- talking to the render PC ---------------------------------------------------------------------

def config():
    try:
        cfg = json.loads(CONFIG.read_text())
    except (OSError, ValueError):
        raise ToolError("BlenderRender isn't set up on this Mac yet. Open the BlenderRender app and "
                        "follow Help > Set Up a Render PC.")
    cfg.setdefault("queueDir", r"C:\GeysierRender\queue")
    cfg.setdefault("downloadDir", str(Path.home() / "Downloads/BlenderRender"))
    cfg.setdefault("macBlender", "/Applications/Blender.app/Contents/MacOS/Blender")
    if not cfg.get("testDir") and not (cfg.get("host") and cfg.get("user")):
        raise ToolError("BlenderRender has no render PC configured. Enter it in BlenderRender's Settings.")
    return cfg


def rq(cfg, *args, stdin=None, stdout=None, timeout=120):
    """Run rq.py on the PC (or in the local test folder) and return stdout bytes."""
    if cfg.get("testDir"):
        cmd = [sys.executable, os.path.join(cfg["testDir"], "rq.py"), *args]
    else:
        cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=15",
               "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/blenderrender-mcp-%C", "-o", "ControlPersist=120",
               "%s@%s" % (cfg["user"], cfg["host"]),
               '"%s\\rq.cmd" %s' % (cfg["queueDir"], " ".join(args))]
    try:
        p = subprocess.run(cmd, stdin=stdin or subprocess.DEVNULL, stdout=stdout or subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise ToolError("The render PC didn't answer in time. Is it on, awake and logged in?")
    if p.returncode != 0:
        err = p.stderr.decode(errors="replace").strip()
        raise ToolError("Render PC error: %s" % (err or "exit code %d" % p.returncode))
    return p.stdout if stdout is None else b""


def rq_json(cfg, *args, **kw):
    data = rq(cfg, *args, **kw)
    try:
        return json.loads(data)
    except ValueError:
        raise ToolError("Unexpected reply from the render PC: %r" % data[:300])


def ensure_app_running():
    """Start BlenderRender in the background (no focus change) so it shows the job and notifies."""
    if APP.exists():
        subprocess.run(["open", "-g", "-a", str(APP)], capture_output=True)


# --- formatting ---------------------------------------------------------------------------------------

def duration(secs):
    secs = int(secs)
    if secs >= 3600:
        return "%d h %d min" % (secs // 3600, secs % 3600 // 60)
    if secs >= 60:
        return "%d min %d s" % (secs // 60, secs % 60)
    return "%d s" % secs


def describe(job, position=None):
    """One job as a dict of plain facts, with the time left counted down to now."""
    out = {"id": job["id"], "name": job.get("name"), "state": job.get("state"),
           "mode": job.get("mode"), "resolution_percent": job.get("pct"), "samples": job.get("samples")}
    if job.get("split_across"):
        out["split_across"] = job["split_across"]
        out["frames_done"] = job["frames_done"]
        if job.get("output"):
            out["output_folder"] = job["output"]
    if job.get("mode") == "animation":
        out["frames"] = "%s-%s" % (job.get("start"), job.get("end"))
        if (job.get("step") or 1) > 1:
            out["every_nth_frame"] = job["step"]
    else:
        out["frame"] = job.get("frame")
    state = job.get("state")
    if state == "rendering":
        out["progress_percent"] = round(100 * (job.get("progress") or 0))
        if job.get("mode") == "animation" and job.get("frame") is not None:
            out["current_frame"] = job["frame"]
        if job.get("eta") is not None and job.get("eta_at"):
            left = max(0, job["eta"] - (time.time() - job["eta_at"]))
            out["time_left"] = duration(left)
            out["done_around"] = time.strftime("%H:%M", time.localtime(time.time() + left))
        else:
            out["time_left"] = "estimating (animations: after the first frame)"
    elif state == "queued" and position:
        out["queue_position"] = position
    elif state == "held":
        out["note"] = "Waiting for Albert to choose its PCs and press Start in BlenderRender."
        if job.get("pcs"):
            out["pcs_ticked"] = job["pcs"]
    elif state in ("done", "failed", "cancelled"):
        out["files"] = job.get("files", 0)
        if job.get("started") and job.get("ended"):
            out["render_time"] = duration(job["ended"] - job["started"])
        if job.get("error"):
            out["error"] = job["error"]
    return out


def split_jobs():
    """The Mac app's split jobs, shaped like PC jobs, from the state files it keeps."""
    jobs = []
    for file in SPLITS.glob("*/state.json"):
        try:
            s = json.loads(file.read_text())
        except (OSError, ValueError):
            continue
        step = s["step"]
        frames = (s["end"] - s["start"]) // step + 1
        done = sum((b["end"] - b["start"]) // step + 1 for b in s["batches"] if b["status"] == "done")
        job = {"id": "split-" + s["id"], "name": s["name"], "mode": "animation", "state": s["state"],
               "start": s["start"], "end": s["end"], "step": step, "pct": s["pct"], "samples": s["samples"],
               "started": s["submitted"], "ended": s.get("ended"), "error": s.get("error"), "files": s.get("files", 0),
               "progress": done / frames, "output": s.get("output"), "log_lines": s.get("log", []),
               "split_across": [p.get("name") or p.get("host") for p in s["pcs"]], "frames_done": "%d of %d" % (done, frames)}
        if s["state"] == "rendering" and not done and not any(b["status"] == "running" for b in s["batches"]):
            job["state"] = "queued"
        if s["state"] == "rendering" and done:
            job["eta"] = (time.time() - s["submitted"]) / done * (frames - done)
            job["eta_at"] = time.time()
        jobs.append(job)
    return sorted(jobs, key=lambda j: j["started"])


def held_jobs():
    """Jobs waiting in the app for Start (HeldJob in Held.swift)."""
    names = {p.get("id"): p.get("name") or p.get("host") for p in config_pcs()}
    jobs = []
    for file in HELD.glob("*/job.json"):
        try:
            h = json.loads(file.read_text())
        except (OSError, ValueError):
            continue
        jobs.append({"id": "held-" + h["id"], "name": h["name"], "state": "held",
                     "mode": "animation" if h["isAnimation"] else "still", "start": h["start"], "end": h["end"],
                     "frame": h["frame"], "step": h.get("step") or 1, "pct": h["pct"], "samples": h["samples"],
                     "started": h["submitted"], "pcs": [names.get(p, p) for p in h.get("pcs", [])]})
    return sorted(jobs, key=lambda j: j["started"])


def config_pcs():
    try:
        cfg = json.loads(CONFIG.read_text())
    except (OSError, ValueError):
        return []
    return [{"id": "main", "name": "render PC", "host": cfg.get("host")}] + (cfg.get("extraPCs") or []) + [{"id": "mac", "name": "This Mac"}]


def find_held(cfg, job_id):
    """A held job, or what it became once started."""
    for j in held_jobs():
        if j["id"] == job_id:
            return j
    try:
        started = json.loads((HELD / "started.json").read_text()).get(job_id[len("held-"):])
    except (OSError, ValueError):
        started = None
    if not started:
        raise ToolError("No job %s waiting in the BlenderRender app." % job_id)
    if started["job"].startswith("split-"):
        return find_split(started["job"])
    if started.get("pc") in ("", "main"):
        return find_job(cfg, started["job"])
    names = {p.get("id"): p.get("name") or p.get("host") for p in config_pcs()}
    return {"id": started["job"], "state": "started", "name": job_id,
            "note": "Started on %s as job %s; follow it in the BlenderRender app." % (names.get(started["pc"], started["pc"]), started["job"])}


def find_split(job_id):
    for j in split_jobs():
        if j["id"] == job_id:
            return j
    raise ToolError("No split job %s in the BlenderRender app." % job_id)


def ask_app(request, blend=None, wait=20):
    """Put a request in the app's inbox and return its reply, or None if no app took it.

    `blend` moves in with the request; unless the app kept it, it's moved back afterwards.
    """
    folder = INBOX / uuid.uuid4().hex
    folder.mkdir(parents=True)
    held = folder / "input.blend"
    request_file = folder / "request.json"
    try:
        if blend:
            shutil.move(str(blend), str(held))
        tmp = folder / "request.tmp"
        tmp.write_text(json.dumps(request))
        os.replace(tmp, request_file)
        ensure_app_running()
        reply_file = folder / "reply.json"
        deadline = time.time() + wait
        while True:
            if reply_file.exists():
                return json.loads(reply_file.read_text())
            if time.time() > deadline:
                try:
                    request_file.unlink()  # still unclaimed: no app is reading the inbox
                    return None
                except OSError:
                    deadline = time.time() + 60  # the app has it; a reply is moments away
            time.sleep(0.25)
    finally:
        if blend and held.exists():
            shutil.move(str(held), str(blend))
        shutil.rmtree(folder, ignore_errors=True)


def pretty_gpu(raw):
    """"OPTIX ['NVIDIA GeForce RTX 2060 SUPER']" -> "RTX 2060 SUPER" (empty until the first render)."""
    name = raw.split("'")[1] if raw.count("'") >= 2 else raw
    for prefix in ("NVIDIA GeForce ", "NVIDIA "):
        if name.startswith(prefix):
            name = name[len(prefix):]
    return name


def text(obj):
    return obj if isinstance(obj, str) else json.dumps(obj, indent=2, ensure_ascii=False)


# --- tools ----------------------------------------------------------------------------------------------

def pack_and_inspect(cfg, blend):
    """Pack the file's textures into a temp copy with the Mac's Blender; return (packed path, info)."""
    blend = Path(os.path.expanduser(blend)).resolve()
    if not blend.is_file() or blend.suffix.lower() != ".blend":
        raise ToolError("Not a .blend file: %s" % blend)
    if not PACK_SCRIPT:
        raise ToolError("pack_inspect.py not found; reinstall BlenderRender.")
    if not os.access(cfg["macBlender"], os.X_OK):
        raise ToolError("Blender not found at %s (set it in BlenderRender's Settings)." % cfg["macBlender"])
    tmp = Path(tempfile.mkdtemp(prefix="blenderrender-mcp-"))
    packed = tmp / blend.name
    p = subprocess.run([cfg["macBlender"], "-b", str(blend), "--factory-startup", "-P", str(PACK_SCRIPT),
                        "--", str(packed)], capture_output=True, timeout=900)
    out = p.stdout.decode(errors="replace")
    line = next((l for l in reversed(out.splitlines()) if l.startswith("inspect: ")), None)
    if not line or not packed.exists():
        shutil.rmtree(tmp, ignore_errors=True)
        raise ToolError("Blender couldn't read %s:\n%s" % (blend.name, out[-800:]))
    return packed, json.loads(line[len("inspect: "):])


def tool_status(cfg, _args):
    v = rq_json(cfg, "version")
    lst = rq_json(cfg, "list")
    jobs = [j for j in lst["jobs"] if not j.get("parent")]  # batches of a split job belong to the Mac app
    jobs += split_jobs()
    queued = [j for j in jobs if j.get("state") == "queued"]
    waiting = held_jobs() + [j for j in jobs if j.get("state") == "held"]
    return {
        "waiting_to_start": [describe(j) for j in waiting],
        "render_pc": v.get("host"), "gpu": pretty_gpu(v.get("gpu") or ""), "queue_worker_running": lst.get("worker"),
        "rendering": [describe(j) for j in jobs if j.get("state") == "rendering"],
        "up_next": [describe(j, i + 1) for i, j in enumerate(queued)],
        "finished": [describe(j) for j in sorted((j for j in jobs if j.get("state") in ("done", "failed", "cancelled")),
                                                 key=lambda j: -(j.get("ended") or 0))][:10],
    }


def tool_inspect(cfg, args):
    packed, info = pack_and_inspect(cfg, args["blend_path"])
    shutil.rmtree(packed.parent, ignore_errors=True)
    info["default_mode"] = "animation" if info["video"] and info["frame_end"] > info["frame_start"] else "still"
    return info


# Fast preview: Cycles as in the final, but every 4th frame (the video plays at fps/4, same length),
# 35% size, at most 16 samples and persistent data. A 55 s 60 fps video renders in under 30 min.
FAST_STEP, FAST_PCT, FAST_SAMPLES = 4, 35, 16


def tool_queue(cfg, args):
    packed, info = pack_and_inspect(cfg, args["blend_path"])
    try:
        if not info.get("camera"):
            raise ToolError("The scene has no active camera, so there's nothing to render.")
        mode = args.get("mode") or ("animation" if info["video"] and info["frame_end"] > info["frame_start"] else "still")
        if mode not in ("still", "animation"):
            raise ToolError("mode must be 'still' or 'animation'")
        fast = bool(args.get("fast_preview")) and mode == "animation"
        opts = {"name": args.get("name") or Path(args["blend_path"]).stem, "mode": mode,
                "pct": int(args.get("resolution_percent") or (min(info["pct"], FAST_PCT) if fast else info["pct"])),
                "samples": int(args.get("samples") or (min(info["samples"], FAST_SAMPLES) if fast else info["samples"])),
                "source": packed.name}
        if not cfg.get("keepAwake", True):
            opts["keep_awake"] = False
        if mode == "animation":
            opts["start"] = int(args.get("frame_start", info["frame_start"]))
            opts["end"] = int(args.get("frame_end", info["frame_end"]))
            if opts["end"] < opts["start"]:
                raise ToolError("frame_end is before frame_start")
            opts["step"] = int(args.get("frame_step") or (FAST_STEP if fast else 1))
            if fast:
                opts["fast"] = True
        else:
            opts["frame"] = int(args.get("frame", info["frame_current"]))
        request = {"action": "hold", "name": opts["name"], "mode": mode, "pct": opts["pct"], "samples": opts["samples"],
                   "fast": fast, "info": info}
        if mode == "animation":
            request.update(start=opts["start"], end=opts["end"], step=opts["step"])
        else:
            request["frame"] = opts["frame"]
        split = ask_app(request, blend=packed)  # waits in the app for Albert's Start
        if split and split.get("held"):
            reply = {"id": split["job_id"]}
        else:  # no app: straight to the main PC, where it's held until Start in the app
            b64 = base64.urlsafe_b64encode(json.dumps(opts).encode()).decode().rstrip("=")
            with open(packed, "rb") as fh:
                reply = rq_json(cfg, "receive", b64, stdin=fh, timeout=1800)
    finally:
        shutil.rmtree(packed.parent, ignore_errors=True)
    ensure_app_running()
    w, h = info["res_x"] * opts["pct"] // 100, info["res_y"] * opts["pct"] // 100
    what = ("frames %d-%d (%d frames%s)" % (opts["start"], opts["end"], (opts["end"] - opts["start"]) // opts["step"] + 1,
                                           ", every %d" % opts["step"] if opts["step"] > 1 else "")
            if mode == "animation" else "frame %d" % opts["frame"])
    result = {"queued": True, "job_id": reply["id"], "name": opts["name"], "mode": mode, "renders": what,
              "resolution": "%dx%d (%d%%)" % (w, h, opts["pct"]), "samples": opts["samples"],
              "engine": info["engine"], "camera": info["camera"],
              "output": ("video (the file's own format)" if mode == "animation" and info["video"]
                         else "PNG image sequence" if mode == "animation" else "PNG"),
              "note": "It's in BlenderRender's Waiting to Start list. It renders once Albert chooses the PCs and "
                      "presses Start there; the app notifies when it's done."}
    if split and split.get("held"):
        result["pcs_ticked"] = split.get("pcs", [])
    if info.get("missing"):
        result["warning"] = "Textures missing on this Mac, so not packed: " + ", ".join(info["missing"])
    return result


def find_job(cfg, job_id):
    if job_id.startswith("held-"):
        return find_held(cfg, job_id)
    if job_id.startswith("split-"):
        return find_split(job_id)
    for j in rq_json(cfg, "list")["jobs"]:
        if j["id"] == job_id:
            return j
    raise ToolError("No render job %s on the render PC." % job_id)


def tool_job(cfg, args):
    if args["job_id"].startswith("held-"):
        j = find_held(cfg, args["job_id"])
        return describe(j) if j.get("state") != "started" else j
    if args["job_id"].startswith("split-"):
        return describe(find_split(args["job_id"]))
    jobs = [j for j in rq_json(cfg, "list")["jobs"] if not j.get("parent")]
    queued = [j["id"] for j in jobs if j.get("state") == "queued"]
    for j in jobs:
        if j["id"] == args["job_id"]:
            pos = queued.index(j["id"]) + 1 if j["id"] in queued else None
            return describe(j, pos)
    raise ToolError("No render job %s on the render PC." % args["job_id"])


def sniff_ext(path):
    with open(path, "rb") as fh:
        b = fh.read(16)
    if b[4:8] == b"ftyp":
        return "mov" if b[8:12] == b"qt  " else "mp4"
    for magic, ext in ((b"\x89PNG", "png"), (b"\xff\xd8\xff", "jpg"), (b"\x76\x2f\x31\x01", "exr"),
                       (b"\x1a\x45\xdf\xa3", "mkv"), (b"II", "tif"), (b"MM", "tif")):
        if b.startswith(magic):
            return ext
    return None


def tool_download(cfg, args):
    job = find_job(cfg, args["job_id"])
    if not job.get("files"):
        raise ToolError("Job %s has no output files (state: %s)." % (job["id"], job.get("state")))
    if job.get("split_across"):
        return download_split(job, args)
    name = (job.get("name") or job["id"]).replace("/", "-").replace(":", "-")
    stamp = "-".join(job["id"].split("-")[:2])
    dest = Path(os.path.expanduser(args.get("destination") or cfg["downloadDir"])) / ("%s %s" % (name, stamp))
    tmp = Path(tempfile.mkdtemp(prefix="blenderrender-dl-"))
    try:
        with open(tmp / "job.tar", "wb") as fh:
            rq(cfg, "send", job["id"], stdout=fh, timeout=3600)
        with tarfile.open(tmp / "job.tar") as tar:
            tar.extractall(tmp)
        dest.mkdir(parents=True, exist_ok=True)
        files = []
        for src in sorted((tmp / "out").iterdir()) if (tmp / "out").is_dir() else []:
            target = dest / src.name
            if not src.suffix and src.is_file():
                ext = sniff_ext(src)
                if ext:
                    target = dest / (src.name + "." + ext)
            if target.exists():
                shutil.rmtree(target) if target.is_dir() else target.unlink()
            shutil.move(str(src), str(target))
            files.append(target.name)
        if (tmp / "log.txt").exists():
            shutil.move(str(tmp / "log.txt"), str(dest / "log.txt"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    # Tell the app it's downloaded, so its row offers "Show in Finder" instead of "Download".
    subprocess.run(["defaults", "write", APP_DEFAULTS, "downloaded", "-dict-add", job["id"], str(dest)],
                   capture_output=True)
    if args.get("reveal", True):
        subprocess.run(["open", "-R", str(dest / files[0]) if files else str(dest)], capture_output=True)
    return {"downloaded_to": str(dest), "files": files[:50] + (["... %d more" % (len(files) - 50)] if len(files) > 50 else [])}


def download_split(job, args):
    """The app already saved a split job's result; copy it if another folder was asked for."""
    src = Path(job["output"])
    dest = src
    if args.get("destination"):
        dest = Path(os.path.expanduser(args["destination"])) / src.name
        shutil.copytree(src, dest, dirs_exist_ok=True)
    if args.get("reveal", True):
        subprocess.run(["open", str(dest)], capture_output=True)
    return {"downloaded_to": str(dest), "files": sorted(p.name for p in dest.iterdir())[:50]}


def app_action(action, job_id):
    if job_id.startswith("held-"):
        find_held(None, job_id)
    else:
        find_split(job_id)
    reply = ask_app({"action": action, "job": job_id})
    if reply is None:
        raise ToolError("The BlenderRender app didn't answer. Is it open?")
    if reply.get("error"):
        raise ToolError(reply["error"])


def tool_cancel(cfg, args):
    if args["job_id"].startswith("held-") and any(j["id"] == args["job_id"] for j in held_jobs()):
        app_action("cancel", args["job_id"])
        return {"cancelled": args["job_id"], "note": "It was still waiting for Start, so it's gone from the queue."}
    if args["job_id"].startswith("split-"):
        app_action("cancel", args["job_id"])
        return {"cancelled": args["job_id"], "note": "The render stops on every PC and its frames are deleted."}
    find_job(cfg, args["job_id"])
    rq_json(cfg, "cancel", args["job_id"], "--by=claude-connector")
    return {"cancelled": args["job_id"], "note": "Anything already rendered stays downloadable."}


def tool_remove(cfg, args):
    if args["job_id"].startswith("held-") and any(j["id"] == args["job_id"] for j in held_jobs()):
        app_action("remove", args["job_id"])
        return {"removed": args["job_id"]}
    if args["job_id"].startswith("split-"):
        app_action("remove", args["job_id"])
        return {"removed": args["job_id"], "note": "Downloads on this Mac are kept."}
    find_job(cfg, args["job_id"])
    rq_json(cfg, "delete", args["job_id"], "--by=claude-connector", timeout=60)
    return {"removed": args["job_id"], "note": "Its files on the render PC are deleted; downloads on this Mac are kept."}


def tool_log(cfg, args):
    if args["job_id"].startswith("split-"):
        return "\n".join(find_split(args["job_id"])["log_lines"][-int(args.get("lines") or 80):]) or "(empty log)"
    log = rq_json(cfg, "log", args["job_id"]).get("log", "")
    n = int(args.get("lines") or 80)
    # Progress lines are noise in a log read; keep Blender's own output.
    lines = [l for l in log.splitlines() if not l.startswith("progress: ")]
    return "\n".join(lines[-n:]) or "(empty log)"


JOB_ID = {"type": "string", "description": "Job id as returned by queue_render or render_status, e.g. 20261023-160201-f7a7."}
TOOLS = [
    ("render_status", tool_status, "Render PC and BlenderRender queue status: what's rendering (with progress "
     "and time left), what's up next, and recently finished jobs.", {}, [], {"readOnlyHint": True}),
    ("inspect_blend", tool_inspect, "Read a .blend file's render settings with the Mac's Blender before queueing it: "
     "engine, resolution, samples, frame range, camera, whether it outputs video, and textures missing on this Mac.",
     {"blend_path": {"type": "string", "description": "Absolute path to the .blend file on this Mac."}},
     ["blend_path"], {"readOnlyHint": True}),
    ("queue_render", tool_queue, "Add a .blend file to the BlenderRender queue on the render PC. Textures are packed "
     "first, so the file renders exactly like on this Mac with its own camera, lights and render settings. Anything "
     "not given uses the file's own value: mode is 'animation' when the file outputs video over a frame range, "
     "otherwise 'still'. The job appears in the BlenderRender app, which notifies when it's done.",
     {"blend_path": {"type": "string", "description": "Absolute path to the .blend file on this Mac."},
      "mode": {"type": "string", "enum": ["still", "animation"]},
      "frame": {"type": "integer", "description": "Frame for a still (default: the file's current frame)."},
      "frame_start": {"type": "integer", "description": "First frame of an animation (default: the file's)."},
      "frame_end": {"type": "integer", "description": "Last frame of an animation (default: the file's)."},
      "resolution_percent": {"type": "integer", "minimum": 1, "maximum": 400,
                             "description": "Resolution scale in % (default: the file's)."},
      "samples": {"type": "integer", "minimum": 1, "description": "Cycles samples (default: the file's)."},
      "frame_step": {"type": "integer", "minimum": 1, "description": "Animations: render every Nth frame; a video "
                     "then plays at fps/N so it keeps its length (default 1, or 4 with fast_preview)."},
      "fast_preview": {"type": "boolean", "description": "Animations: quick approval preview with the final look. "
                       "Every 4th frame, 35% size, at most 16 samples, persistent data. Use for every preview video."},
      "name": {"type": "string", "description": "Job name shown in the app and used for output files (default: file name)."}},
     ["blend_path"], {"readOnlyHint": False, "destructiveHint": False}),
    ("render_job", tool_job, "Status of one render job, with progress and time left while it renders.",
     {"job_id": JOB_ID}, ["job_id"], {"readOnlyHint": True}),
    ("download_render", tool_download, "Download a finished (or partly finished) job's images or video to this Mac, "
     "into BlenderRender's download folder unless a destination is given, and show it in Finder.",
     {"job_id": JOB_ID, "destination": {"type": "string", "description": "Folder to download into (optional)."},
      "reveal": {"type": "boolean", "description": "Show the files in Finder afterwards (default true)."}},
     ["job_id"], {"readOnlyHint": False, "destructiveHint": False}),
    ("cancel_render", tool_cancel, "Stop a queued or rendering job. Frames already rendered can still be downloaded.",
     {"job_id": JOB_ID}, ["job_id"], {"readOnlyHint": False, "destructiveHint": True}),
    ("remove_render", tool_remove, "Delete a job and its files from the render PC (stops it first if it's running). "
     "Downloads on this Mac are kept.", {"job_id": JOB_ID}, ["job_id"], {"readOnlyHint": False, "destructiveHint": True}),
    ("render_log", tool_log, "The end of a job's Blender log, to see why a render failed.",
     {"job_id": JOB_ID, "lines": {"type": "integer", "description": "How many lines (default 80)."}},
     ["job_id"], {"readOnlyHint": True}),
]
HANDLERS = {name: fn for name, fn, *_ in TOOLS}


# --- MCP over stdio (JSON-RPC 2.0, one message per line) ----------------------------------------------

def tool_list():
    return [{"name": name, "description": desc,
             "inputSchema": {"type": "object", "properties": props, "required": req},
             "annotations": ann}
            for name, _fn, desc, props, req, ann in TOOLS]


def handle(msg):
    method, params = msg.get("method"), msg.get("params") or {}
    if method == "initialize":
        asked = params.get("protocolVersion")
        return {"protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
                "capabilities": {"tools": {}}, "serverInfo": SERVER,
                "instructions": "Queue .blend renders on the user's Windows GPU render PC and fetch the results. "
                                "Jobs also appear in the BlenderRender Mac app."}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": tool_list()}
    if method == "tools/call":
        name, args = params.get("name"), params.get("arguments") or {}
        if name not in HANDLERS:
            raise LookupError("unknown tool %s" % name)
        try:
            result = HANDLERS[name](config(), args)
            return {"content": [{"type": "text", "text": text(result)}], "isError": False}
        except ToolError as e:
            return {"content": [{"type": "text", "text": str(e)}], "isError": True}
        except Exception as e:  # report, don't crash the server
            traceback.print_exc(file=sys.stderr)
            return {"content": [{"type": "text", "text": "BlenderRender connector error: %s" % e}], "isError": True}
    raise LookupError("method not found: %s" % method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if "id" not in msg:
            continue  # notifications (initialized, cancelled) need no reply
        try:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "result": handle(msg)}
        except LookupError as e:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": str(e)}}
        except Exception as e:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32603, "message": str(e)}}
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
