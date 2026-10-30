"""Run first on the render PC (-P progress.py): live render progress for remote_render.sh.

Blender 5 prints no per-sample progress in background mode and Python output is block-buffered
over SSH, so this makes stdout line-buffered and prints, at most once a second, a line like
  progress: frame=1 sample=32/128 remaining=00:41.20
from Cycles' render stats. jobs_lib.sh's job_track reads these lines.
"""
import re
import sys
import time

import bpy

sys.stdout.reconfigure(line_buffering=True)
_last = [0.0]


def _on_stats(stats, *_):
    m = re.search(r"Sample (\d+)/(\d+)", stats)
    if not m:
        return
    now = time.monotonic()
    done = m.group(1) == m.group(2)
    if now - _last[0] < 1.0 and not done:
        return
    _last[0] = now
    rem = re.search(r"Remaining:\s*([\d:.]+)", stats)
    print(f"progress: frame={bpy.context.scene.frame_current} sample={m.group(1)}/{m.group(2)}"
          f" remaining={rem.group(1) if rem else ''}")


bpy.app.handlers.render_stats.append(_on_stats)
