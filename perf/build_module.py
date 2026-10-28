#!/usr/bin/env python3
"""Build the tanzanite_oc KernelSU/Magisk module zip.

Layout is flat: module.prop, customize.sh, post-fs-data.sh, service.sh,
uninstall.sh, config.env, oc_cpu.sh, oc_gpu.sh all sit at the zip root, which is
what both KernelSU and Magisk expect.

The two OC scripts are copied in from perf/ so there is exactly one copy of the
logic - the same file you test by hand is the file that runs at boot.
"""

import os
import shutil
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "module")
REPO = os.path.dirname(HERE)

# pull the current scripts in, so the module never carries a stale copy
for name in ("oc_cpu.sh", "oc_gpu.sh"):
    shutil.copy2(os.path.join(HERE, name), os.path.join(MOD, name))

FILES = [
    "module.prop",
    "customize.sh",
    "post-fs-data.sh",
    "service.sh",
    "uninstall.sh",
    "config.env",
    "oc_cpu.sh",
    "oc_gpu.sh",
]

EXEC = {"customize.sh", "post-fs-data.sh", "service.sh", "uninstall.sh",
        "oc_cpu.sh", "oc_gpu.sh"}

out = os.path.join(REPO, "dist", "tanzanite_oc_v1.zip")
os.makedirs(os.path.dirname(out), exist_ok=True)

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in FILES:
        path = os.path.join(MOD, f)
        if not os.path.exists(path):
            raise SystemExit("missing: " + path)
        info = zipfile.ZipInfo(f)
        # 0755 for scripts, 0644 for the rest
        info.external_attr = ((0o755 if f in EXEC else 0o644) | 0o100000) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(path, "rb") as fh:
            z.writestr(info, fh.read())

print("built:", out)
print("size :", os.path.getsize(out), "bytes")
with zipfile.ZipFile(out) as z:
    for i in z.infolist():
        print("  %-18s %6d bytes  mode %o" % (i.filename, i.file_size,
                                              (i.external_attr >> 16) & 0o777))
