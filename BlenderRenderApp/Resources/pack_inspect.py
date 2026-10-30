"""Run by the Mac app on a dropped .blend: pack its textures into a copy and report its render settings.

  Blender -b dropped.blend -P pack_inspect.py -- <packed copy.blend>

Prints one line `inspect: {...}` with the scene's frames, resolution, engine, samples and any
images that couldn't be packed (missing on this Mac).
"""
import json
import os
import sys

import bpy

out = sys.argv[sys.argv.index("--") + 1]
sc = bpy.context.scene
r = sc.render

try:
    bpy.ops.file.pack_all()
except RuntimeError as e:
    print("pack warning:", e)
missing = [i.name for i in bpy.data.images
           if i.source in {"FILE", "SEQUENCE", "TILED"} and not i.packed_file
           and i.filepath and not os.path.exists(bpy.path.abspath(i.filepath))]

bpy.ops.wm.save_as_mainfile(filepath=out, copy=True, compress=True)

samples = sc.cycles.samples if r.engine == "CYCLES" else getattr(sc.eevee, "taa_render_samples", 0)
video = getattr(r.image_settings, "media_type", "IMAGE") != "IMAGE" or r.image_settings.file_format == "FFMPEG"
print("inspect: " + json.dumps({
    "frame_start": sc.frame_start, "frame_end": sc.frame_end, "frame_current": sc.frame_current,
    "res_x": r.resolution_x, "res_y": r.resolution_y, "pct": r.resolution_percentage,
    "engine": r.engine, "samples": samples, "camera": sc.camera.name if sc.camera else None,
    "video": video, "missing": missing, "blender": bpy.app.version_string,
}))
