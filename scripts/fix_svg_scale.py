"""
fix_svg_scale.py
Bumps svg/scale from 1.0 to 4.0 in all .svg.import files under addons/emoji-texture/packs/
so that SVGs are rasterised at a resolution large enough to look crisp at 128 px.
"""

import os
import re

PACKS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "addons", "emoji-texture", "packs",
)
OLD = "svg/scale=1.0"
NEW = "svg/scale=4.0"

updated = 0
skipped = 0

for root, _dirs, files in os.walk(PACKS_DIR):
    for fname in files:
        if not fname.endswith(".svg.import"):
            continue
        path = os.path.join(root, fname)
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
        if OLD in text:
            new_text = text.replace(OLD, NEW)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new_text)
            updated += 1
        else:
            skipped += 1

print(f"Done: {updated} files updated to svg/scale=4.0, {skipped} already correct/different.")
