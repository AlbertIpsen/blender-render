"""Run first on the render PC (-P remote_gpu.py -P <job script>): switch Cycles to the GPU.

Prefers OptiX, falls back to CUDA; every non-CPU device of that type is enabled. Preferences are not saved.
"""
import bpy

prefs = bpy.context.preferences.addons["cycles"].preferences
for kind in ("OPTIX", "CUDA"):
    try:
        prefs.compute_device_type = kind
    except TypeError:
        continue
    prefs.refresh_devices()
    if any(d.type == kind for d in prefs.devices):
        break
else:
    raise SystemExit("remote_gpu: no OptiX/CUDA device found")

for d in prefs.devices:
    d.use = d.type == prefs.compute_device_type
for sc in bpy.data.scenes:
    sc.cycles.device = "GPU"
print("remote_gpu:", prefs.compute_device_type, [d.name for d in prefs.devices if d.use])
