"""Wraps xtool/LocationTrackerClient.app into an unsigned .ipa.

`xtool dev build --ipa` does the same but shells out to `zip`, which a stock WSL Ubuntu
does not have. File modes are preserved so the app binary stays executable.
"""
import os
import zipfile

APP, OUT = "xtool/LocationTrackerClient.app", "xtool/LocationTrackerClient.ipa"

if os.path.exists(OUT):
    os.remove(OUT)

with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(APP):
        for name in files:
            full = os.path.join(root, name)
            rel = "Payload/LocationTrackerClient.app/" + os.path.relpath(full, APP).replace(os.sep, "/")
            info = zipfile.ZipInfo(rel)
            info.external_attr = (os.stat(full).st_mode & 0xFFFF) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as fh:
                z.writestr(info, fh.read())

print("packaged", OUT)
