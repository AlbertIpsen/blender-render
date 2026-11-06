"""Render one queued job with the .blend's own camera, lights and render settings.

  blender -b input.blend [-P remote_gpu.py] -P progress.py -P render_job.py -- <out dir> <b64 options>

Options (from the Mac app): name, mode ("still" | "animation"), frame (still), start/end (animation),
pct (resolution %, 0 keeps the file's), samples (0 keeps the file's), step (animations: render every
step-th frame; a video then plays at fps/step so it keeps its real length), fast (a fast preview) and
frames_only (a batch of a split job: a
video setting renders PNG frames instead, which the Mac joins at the end). Stills always come out as
PNG when the file is set to a video format; animations keep the file's output format.

Output names always carry their extension, even when the .blend has File Extensions turned off
(common when its own output path already ends in .mp4): videos get name.<container ext>, image
sequences name_0001.png, stills name.png.
"""
import base64
import json
import os
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
out_dir = argv[0]
opts = json.loads(base64.urlsafe_b64decode(argv[1] + "=" * (-len(argv[1]) % 4)))

sc = bpy.context.scene
r = sc.render
if opts.get("pct"):
    r.resolution_percentage = int(opts["pct"])
if opts.get("samples") and r.engine == "CYCLES":
    sc.cycles.samples = int(opts["samples"])
if r.engine == "CYCLES" and opts.get("persistent", True):
    # Keep the scene between frames and only update what changed: without it Cycles rebuilds
    # everything each frame, and on a light scene the GPU waits most of the time.
    r.use_persistent_data = True
name = "".join(c if c.isalnum() or c in "-_ " else "_" for c in opts.get("name", "render")).strip() or "render"
is_video = getattr(r.image_settings, "media_type", "IMAGE") != "IMAGE" or r.image_settings.file_format == "FFMPEG"
# FFmpeg container -> extension. With use_file_extension on, Blender would name a video
# "name0001-0500.mp4", so videos get the extension written into the path instead.
VIDEO_EXT = {"MPEG4": ".mp4", "QUICKTIME": ".mov", "MKV": ".mkv", "WEBM": ".webm", "AVI": ".avi",
             "OGG": ".ogv", "FLASH": ".flv", "MPEG1": ".mpg", "MPEG2": ".mpg", "DV": ".dv"}

if opts.get("frames_only") and is_video:
    if hasattr(r.image_settings, "media_type"):
        r.image_settings.media_type = "IMAGE"
    r.image_settings.file_format = "PNG"
    r.image_settings.color_mode = "RGB"
    is_video = False

if opts.get("mode") == "animation":
    sc.frame_start, sc.frame_end = int(opts["start"]), int(opts["end"])
    step = max(1, int(opts.get("step") or 1))
    sc.frame_step = step
    if step > 1 and is_video:
        r.fps_base *= step  # 60 fps, every 4th frame -> a 15 fps video of the same length
    if is_video:
        r.use_file_extension = False
        r.filepath = os.path.join(out_dir, name + VIDEO_EXT.get(r.ffmpeg.format, ".mp4"))
    else:
        r.use_file_extension = True
        r.filepath = os.path.join(out_dir, name + "_")
    print(f"render_job: animation {sc.frame_start}-{sc.frame_end} step {step} -> {r.filepath}")
    bpy.ops.render.render(animation=True)
else:
    if is_video:
        if hasattr(r.image_settings, "media_type"):
            r.image_settings.media_type = "IMAGE"
        r.image_settings.file_format = "PNG"
    sc.frame_set(int(opts.get("frame", sc.frame_current)))
    r.use_file_extension = True
    r.filepath = os.path.join(out_dir, name)
    print(f"render_job: still frame {sc.frame_current} -> {r.filepath}")
    bpy.ops.render.render(write_still=True)
