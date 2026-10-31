"""Render queue on the render PC, driven over SSH by the BlenderRender Mac app.

Lives in C:\\GeysierRender\\queue next to render_job.py, remote_gpu.py and progress.py (pushed by the
app), plus rq_config.json and rq.cmd (written once by setup_windows_pc.ps1). Every command prints
JSON on stdout, except `send` which streams a tar of the job's output.

  rq version                 protocol version, worker state, GPU
  rq list                    all jobs, oldest first
  rq receive <b64 options>   read a .blend from stdin into a new queued job, print its id
  rq cancel <id>             stop a queued or rendering job
  rq delete <id>             cancel if needed, then remove the job and its files
  rq send <id>               tar of the job's out/ folder on stdout
  rq size <id>               about how many bytes `send` will stream (for the app's progress bar)
  rq log <id>                last 200 lines of the job's Blender log
  rq cache-has <key>         is this split job's .blend already on the PC
  rq cache-put <key>         read a split job's .blend from stdin, kept for all its batches
  rq cache-drop <key>        delete it when the split job is over
  rq batch <b64 options>     queue a batch of frames from a cached .blend, print its id
  rq preview <id>            raw bytes of the job's first PNG/JPEG (for notification thumbnails)
  rq worker                  render queued jobs one at a time, forever (scheduled task at logon)
  rq ensure-worker           start the worker if it isn't running

Split jobs: the Mac app hands each PC a batch of frames at a time. A batch is a normal job that
names a cached .blend (`blend`) and its split job (`parent`), so the file is only sent once.

Jobs are folders under jobs/<id>/: input.blend, job.json (what to render), status.json (where it
is), log.txt, out/ (renders) and a `cancel` flag file.

Time left (status `eta`, seconds as of `eta_at`): for animations it comes from measured wall-clock
frame times, the median of the last 15 frames times the frames still to go. Cycles' own "Remaining"
only covers sampling, which on a typical animation is about half of each frame (scene sync, denoise
and video encoding are the rest), so it can't be trusted there. Stills use Cycles' figure, since
sampling dominates a single frame. No estimate until the first animation frame has finished.
"""
import base64
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import uuid
from pathlib import Path

VERSION = 9
HERE = Path(__file__).resolve().parent
JOBS = HERE / "jobs"
CACHE = HERE / "cache"
WIN = os.name == "nt"
TASK_NAME = "BlenderRenderQueue"


def config():
    p = HERE / "rq_config.json"
    cfg = json.loads(p.read_text()) if p.exists() else {}
    cfg.setdefault("blender", "blender")
    cfg.setdefault("gpu", True)
    return cfg


def read_json(p, default=None):
    try:
        return json.loads(Path(p).read_text())
    except (OSError, ValueError):
        return default


def write_json(p, data):
    p = Path(p)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data))
    for _ in range(20):  # Windows refuses to replace a file someone is reading right now
        try:
            os.replace(tmp, p)
            return
        except PermissionError:
            time.sleep(0.05)
    os.replace(tmp, p)


def update_status(job_dir, **kw):
    st = read_json(job_dir / "status.json", {})
    st.update(kw, updated=time.time())
    write_json(job_dir / "status.json", st)
    return st


def out(data):
    sys.stdout.write(json.dumps(data))
    sys.stdout.flush()


def job_dir(job_id):
    if not re.fullmatch(r"[\w-]+", job_id or ""):
        raise SystemExit(f"bad job id: {job_id!r}")
    d = JOBS / job_id
    if not d.is_dir():
        raise SystemExit(f"no job {job_id}")
    return d


# --- single worker: an exclusive lock on worker.lock, released by the OS when the process dies ---

def _try_lock(fh):
    try:
        if WIN:
            import msvcrt
            msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def worker_running():
    HERE.joinpath("worker.lock").touch()
    with open(HERE / "worker.lock", "r+") as fh:
        if not _try_lock(fh):
            return True
    return False  # closing the file released our probe lock


def ensure_worker():
    if worker_running():
        return True
    if WIN:
        subprocess.run(["schtasks", "/run", "/tn", TASK_NAME], capture_output=True)
    else:  # test mode on a Mac: a detached child
        subprocess.Popen([sys.executable, str(HERE / "rq.py"), "worker"], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(20):
        time.sleep(0.25)
        if worker_running():
            return True
    return False


# --- commands ---

def blender_version():
    """"5.2.1", or "" if Blender won't say. Split jobs need the same version on every PC.

    Remembered per Blender install, because the app asks every 20 seconds.
    """
    exe = config()["blender"]
    try:
        stamp = f"{exe}:{os.path.getmtime(exe)}"
    except OSError:
        stamp = exe
    known = read_json(HERE / "blender_version.json", {})
    if known.get("stamp") == stamp:
        return known.get("version", "")
    flags = subprocess.CREATE_NO_WINDOW if WIN else 0
    try:
        text = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=30,
                              creationflags=flags).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    m = re.search(r"Blender (\d+\.\d+(?:\.\d+)?)", text)
    version = m.group(1) if m else ""
    write_json(HERE / "blender_version.json", {"stamp": stamp, "version": version})
    return version


def cmd_version():
    state = read_json(HERE / "worker_state.json", {})
    out({"version": VERSION, "worker": worker_running(), "gpu": state.get("gpu", ""),
         "blender": config()["blender"], "blender_version": blender_version(), "host": os.environ.get("COMPUTERNAME") or os.uname().nodename})


def cmd_stats():
    """GPU load and free disk for the app's Render PCs window. GPU fields are missing without nvidia-smi."""
    info = {"disk_free": shutil.disk_usage(HERE).free}
    flags = subprocess.CREATE_NO_WINDOW if WIN else 0
    query = "name,utilization.gpu,temperature.gpu,memory.used,memory.total"
    try:
        text = subprocess.run(["nvidia-smi", f"--query-gpu={query}", "--format=csv,noheader,nounits"],
                              capture_output=True, text=True, timeout=5, creationflags=flags).stdout
        name, load, temp, used, total = [v.strip() for v in text.splitlines()[0].split(",")]
        info.update(gpu_name=name, gpu_load=float(load), gpu_temp=float(temp),
                    vram_used=float(used), vram_total=float(total))
    except (OSError, subprocess.SubprocessError, ValueError, IndexError):
        pass  # no NVIDIA tools, or a field reads "[N/A]"
    out(info)


def cmd_list():
    jobs = []
    if JOBS.is_dir():
        for d in JOBS.iterdir():
            job = read_json(d / "job.json")
            if not job:
                continue
            job.update(read_json(d / "status.json", {}))
            job["id"] = d.name
            jobs.append(job)
    jobs.sort(key=lambda j: j.get("submitted", 0))
    state = read_json(HERE / "worker_state.json", {})
    out({"jobs": jobs, "worker": worker_running(), "gpu": state.get("gpu", "")})


def cmd_receive(b64):
    opts = json.loads(base64.urlsafe_b64decode(b64 + "=" * (-len(b64) % 4)))
    job_id = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:4]
    d = JOBS / job_id
    d.mkdir(parents=True)
    part = d / "input.blend.part"
    size = 0
    with open(part, "wb") as fh:
        src = sys.stdin.buffer
        while chunk := src.read(1 << 20):
            fh.write(chunk)
            size += len(chunk)
    if size == 0:
        shutil.rmtree(d)
        raise SystemExit("no data received")
    os.replace(part, d / "input.blend")
    opts["submitted"] = time.time()
    opts["size"] = size
    write_json(d / "job.json", opts)
    update_status(d, state="queued")
    started = ensure_worker()
    out({"id": job_id, "worker": started})


def cache_path(key):
    if not re.fullmatch(r"[\w-]+", key or ""):
        raise SystemExit(f"bad cache key: {key!r}")
    return CACHE / f"{key}.blend"


def cmd_cache_has(key):
    out({"has": cache_path(key).exists()})


def cmd_cache_put(key):
    CACHE.mkdir(exist_ok=True)
    p = cache_path(key)
    part = p.with_suffix(".part")
    size = 0
    with open(part, "wb") as fh:
        src = sys.stdin.buffer
        while chunk := src.read(1 << 20):
            fh.write(chunk)
            size += len(chunk)
    if size == 0:
        part.unlink()
        raise SystemExit("no data received")
    os.replace(part, p)
    out({"ok": True})


def cmd_cache_drop(key):
    cache_path(key).unlink(missing_ok=True)
    out({"ok": True})


def cmd_batch(b64):
    opts = json.loads(base64.urlsafe_b64decode(b64 + "=" * (-len(b64) % 4)))
    if not cache_path(opts.get("blend")).exists():
        raise SystemExit("the split job's .blend isn't on this PC")
    job_id = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:4]
    d = JOBS / job_id
    d.mkdir(parents=True)
    opts["submitted"] = time.time()
    write_json(d / "job.json", opts)
    update_status(d, state="queued")
    out({"id": job_id, "worker": ensure_worker()})


def cmd_cancel(job_id):
    d = job_dir(job_id)
    (d / "cancel").touch()
    st = read_json(d / "status.json", {})
    if st.get("state") == "queued":
        update_status(d, state="cancelled", ended=time.time())
    out({"ok": True})


def cmd_delete(job_id):
    d = job_dir(job_id)
    (d / "cancel").touch()
    for _ in range(40):  # give the worker time to stop Blender and let go of the files
        if read_json(d / "status.json", {}).get("state") != "rendering":
            break
        time.sleep(0.25)
    shutil.rmtree(d, ignore_errors=True)
    out({"ok": not d.exists()})


def cmd_send(job_id):
    d = job_dir(job_id)
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as tar:
        if (d / "out").is_dir():
            tar.add(d / "out", arcname="out")
        if (d / "log.txt").exists():
            tar.add(d / "log.txt", arcname="log.txt")


def cmd_size(job_id):
    d = job_dir(job_id)
    paths = list((d / "out").rglob("*")) + [d / "out"] if (d / "out").is_dir() else []
    if (d / "log.txt").exists():
        paths.append(d / "log.txt")
    # tar: a 512-byte header per entry, data padded to 512, two empty blocks, then 10 KiB records
    n = sum(512 + (-(-p.stat().st_size // 512) * 512 if p.is_file() else 0) for p in paths) + 1024
    out({"bytes": -(-n // 10240) * 10240, "files": sum(p.is_file() for p in paths)})


def cmd_preview(job_id):
    images = sorted(p for p in (job_dir(job_id) / "out").rglob("*")
                    if p.suffix.lower() in {".png", ".jpg", ".jpeg"})
    if not images:
        raise SystemExit("no PNG/JPEG output")
    sys.stdout.buffer.write(images[0].read_bytes())
    sys.stdout.buffer.flush()


def cmd_log(job_id):
    p = job_dir(job_id) / "log.txt"
    lines = p.read_text(errors="replace").splitlines()[-200:] if p.exists() else []
    out({"log": "\n".join(lines)})


# --- worker ---

def _seconds(cycles_time):
    """Cycles' "01:23.45" / "1:02:03.40" -> seconds; None when empty."""
    try:
        parts = [float(p) for p in cycles_time.split(":")]
    except ValueError:
        return None
    return sum(p * 60 ** i for i, p in enumerate(reversed(parts))) if cycles_time else None


class Eta:
    """Time-left estimate for one job (see the module docstring)."""

    def __init__(self, frames, start, step=1):
        self.frames, self.start, self.step = frames, start, step
        self.frame, self.frame_t0, self.durations = None, 0.0, []

    def update(self, frame, cycles_remaining, now):
        if frame != self.frame:
            if self.frame is not None:
                self.durations.append(now - self.frame_t0)
            self.frame, self.frame_t0 = frame, now
        if self.frames == 1:
            return _seconds(cycles_remaining)
        if not self.durations:
            return None
        recent = sorted(self.durations[-15:])
        per_frame = recent[len(recent) // 2]
        frames_after = max(0, self.frames - (frame - self.start) // self.step - 1)
        return max(0.0, per_frame - (now - self.frame_t0)) + per_frame * frames_after


EOF = object()
PROGRESS = re.compile(r"^progress: frame=(\d*) sample=(\d+)/(\d+) remaining=(.*)$")


def nudge_awake(hold=None):
    """Tell Windows the PC is in use: once by default, or from now until hold=False on this thread."""
    if not WIN:
        return
    import ctypes
    continuous, system_required = 0x80000000, 0x00000001
    flags = system_required if hold is None else continuous | (system_required if hold else 0)
    ctypes.windll.kernel32.SetThreadExecutionState(flags)


def render(d, cfg):
    """Render a job, keeping the PC from sleeping on its own unless the Mac's setting says otherwise."""
    hold = read_json(d / "job.json", {}).get("keep_awake", True)
    if hold:
        nudge_awake(True)
    try:
        render_job(d, cfg)
    finally:
        if hold:
            nudge_awake(False)


def render_job(d, cfg):
    job = read_json(d / "job.json")
    (d / "out").mkdir(exist_ok=True)
    blend = cache_path(job["blend"]) if job.get("blend") else d / "input.blend"
    cmd = [cfg["blender"], "-b", str(blend), "--python-exit-code", "1"]
    if cfg["gpu"]:
        cmd += ["-P", str(HERE / "remote_gpu.py")]
    opts = base64.urlsafe_b64encode(json.dumps(job).encode()).decode()
    cmd += ["-P", str(HERE / "progress.py"), "-P", str(HERE / "render_job.py"), "--", str(d / "out"), opts]

    start, end, step = job.get("start", 1), job.get("end", 1), max(1, int(job.get("step") or 1))
    frames = max(1, (end - start) // step + 1) if job.get("mode") == "animation" else 1
    update_status(d, state="rendering", started=time.time(), frames=frames, progress=0.0, saved=0)

    flags = subprocess.CREATE_NO_WINDOW if WIN else 0
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                            text=True, encoding="utf-8", errors="replace", creationflags=flags)
    lines = queue.Queue()

    def pump():
        for l in proc.stdout:
            lines.put(l)
        lines.put(EOF)
    threading.Thread(target=pump, daemon=True).start()

    saved, last_write, st = 0, 0.0, {}
    eta = Eta(frames, start, step)
    with open(d / "log.txt", "w", encoding="utf-8") as log:
        while True:
            try:
                line = lines.get(timeout=0.5)
                line = line if line is EOF else line.rstrip("\r\n")
            except queue.Empty:
                line = None
            if line is EOF:
                break
            if line is not None:
                log.write(line + "\n")
                if line.startswith("remote_gpu:"):
                    gpu = line.split(":", 1)[1].strip()
                    write_json(HERE / "worker_state.json", {"gpu": gpu})
                    st["gpu"] = gpu
                elif "Saved: '" in line:
                    saved += 1
                    st["saved"] = saved
                    st["last_file"] = os.path.basename(line.split("Saved: '", 1)[1].split("'")[0])
                elif m := PROGRESS.match(line):
                    frame = int(m.group(1) or start)
                    s, n = int(m.group(2)), int(m.group(3))
                    done_frames = (frame - start) // step if frames > 1 else 0
                    now = time.time()
                    left = eta.update(frame, m.group(4), now)
                    st.update(frame=frame, sample=s, samples=n, remaining=m.group(4),
                              progress=min(1.0, (done_frames + s / max(n, 1)) / frames),
                              eta=None if left is None else round(left), eta_at=now)
            if (d / "cancel").exists() and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    proc.kill()
            if st and time.time() - last_write > 1.0:
                update_status(d, **st)
                st, last_write = {}, time.time()
    rc = proc.wait()
    files = sum(1 for p in (d / "out").rglob("*") if p.is_file())
    if (d / "cancel").exists():
        state = "cancelled"
    else:
        state = "done" if rc == 0 and files else "failed"
    if state == "done":
        st["progress"] = 1.0
    st.update(eta=None, state=state, ended=time.time(), exit_code=rc, files=files)
    update_status(d, **st)


def _live():
    """This file as it is on disk now: the app may have pushed a newer version since the worker started."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("rq_live", HERE / "rq.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def cmd_worker():
    HERE.joinpath("worker.lock").touch()
    lock = open(HERE / "worker.lock", "r+")
    if not _try_lock(lock):
        return  # another worker already runs
    JOBS.mkdir(exist_ok=True)
    for d in JOBS.iterdir():  # a previous worker died mid-render
        if read_json(d / "status.json", {}).get("state") == "rendering":
            update_status(d, state="failed", ended=time.time(), error="render PC worker restarted")
    while True:
        queued = []
        for d in JOBS.iterdir():
            st = read_json(d / "status.json", {})
            if st.get("state") == "queued" and not (d / "cancel").exists():
                queued.append((read_json(d / "job.json", {}).get("submitted", 0), d))
        if not queued:
            time.sleep(2)
            continue
        d = min(queued)[1]
        try:
            live = _live()
            live.render(d, live.config())
        except Exception as e:  # keep the queue alive whatever one job does
            update_status(d, state="failed", ended=time.time(), error=str(e))


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    cmd, rest = args[0], args[1:]
    if cmd == "version":
        cmd_version()
    elif cmd == "list":
        cmd_list()
    elif cmd == "stats":
        cmd_stats()
    elif cmd == "nudge":
        nudge_awake()
        out({"ok": True})
    elif cmd == "receive":
        cmd_receive(rest[0])
    elif cmd == "cache-has":
        cmd_cache_has(rest[0])
    elif cmd == "cache-put":
        cmd_cache_put(rest[0])
    elif cmd == "cache-drop":
        cmd_cache_drop(rest[0])
    elif cmd == "batch":
        cmd_batch(rest[0])
    elif cmd == "cancel":
        cmd_cancel(rest[0])
    elif cmd == "delete":
        cmd_delete(rest[0])
    elif cmd == "send":
        cmd_send(rest[0])
    elif cmd == "size":
        cmd_size(rest[0])
    elif cmd == "log":
        cmd_log(rest[0])
    elif cmd == "preview":
        cmd_preview(rest[0])
    elif cmd == "worker":
        cmd_worker()
    elif cmd == "ensure-worker":
        out({"worker": ensure_worker()})
    else:
        raise SystemExit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
