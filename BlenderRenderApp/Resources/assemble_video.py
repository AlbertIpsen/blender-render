"""Joins a split job's PNG frames into the video format the .blend asks for, on the Mac.

  blender -b input.blend --factory-startup -P assemble_video.py -- <frames dir> <out dir> <b64 options>

Options: name, start, step, pct. The frames already have the file's look baked in, so the view
transform is set to Standard to stop it being applied twice. A top channel covers anything already
in the sequencer, and sound strips keep playing.
"""
import base64
import json
import os
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
frames_dir, out_dir = argv[0], argv[1]
opts = json.loads(base64.urlsafe_b64decode(argv[2] + "=" * (-len(argv[2]) % 4)))
VIDEO_EXT = {"MPEG4": ".mp4", "QUICKTIME": ".mov", "MKV": ".mkv", "WEBM": ".webm", "AVI": ".avi",
             "OGG": ".ogv", "FLASH": ".flv", "MPEG1": ".mpg", "MPEG2": ".mpg", "DV": ".dv"}

sc = bpy.context.scene
r = sc.render
frames = sorted(f for f in os.listdir(frames_dir) if f.lower().endswith(".png"))
if not frames:
    raise SystemExit("no frames to join")

start, step = int(opts["start"]), max(1, int(opts.get("step") or 1))
sc.frame_start, sc.frame_end, sc.frame_step = start, start + len(frames) - 1, 1
if opts.get("pct"):
    r.resolution_percentage = int(opts["pct"])
if step > 1:
    r.fps_base *= step

v = sc.view_settings
v.view_transform, v.look, v.exposure, v.gamma, v.use_curve_mapping = "Standard", "None", 0.0, 1.0, False
r.use_sequencer, r.use_compositing = True, False

seq = sc.sequence_editor or sc.sequence_editor_create()
strips = seq.strips if hasattr(seq, "strips") else seq.sequences
strip = strips.new_image("frames", os.path.join(frames_dir, frames[0]), 128, start)
for f in frames[1:]:
    strip.elements.append(f)
strip.frame_final_duration = len(frames)

name = "".join(c if c.isalnum() or c in "-_ " else "_" for c in opts.get("name", "render")).strip() or "render"
r.use_file_extension = False
r.filepath = os.path.join(out_dir, name + VIDEO_EXT.get(r.ffmpeg.format, ".mp4"))
print(f"assemble_video: {len(frames)} frames -> {r.filepath}")
bpy.ops.render.render(animation=True)
