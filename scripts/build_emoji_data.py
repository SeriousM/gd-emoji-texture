"""
Downloads and processes emoji data into JSON files for the EmojiTexture addon.

Outputs:
  addons/emoji-texture/data/emoji_list.json   - all emoji with codepoint, name, category, subcategory
  addons/emoji-texture/data/emoji_keywords.json - emojilib v4 keyword map (MIT)
"""

import json
import re
import urllib.request
import urllib.error
import sys
import os

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "addons", "emoji-texture", "data")
os.makedirs(OUT_DIR, exist_ok=True)

# ──────────────────────────────────────────────────────────────────────────────
# 1. emoji_list.json  — parsed from Unicode emoji-test.txt
# ──────────────────────────────────────────────────────────────────────────────

EMOJI_TEST_URL = "https://unicode.org/Public/emoji/16.0/emoji-test.txt"

print(f"Downloading emoji-test.txt from {EMOJI_TEST_URL} ...")
try:
    with urllib.request.urlopen(EMOJI_TEST_URL, timeout=30) as response:
        emoji_test_text = response.read().decode("utf-8")
    print(f"  Downloaded {len(emoji_test_text):,} bytes")
except Exception as e:
    print(f"  ERROR: {e}")
    sys.exit(1)

emojis = []
current_group = ""
current_subgroup = ""

for line in emoji_test_text.splitlines():
    line_stripped = line.strip()

    if line_stripped.startswith("# group:"):
        current_group = line_stripped[len("# group:"):].strip()
        continue
    if line_stripped.startswith("# subgroup:"):
        current_subgroup = line_stripped[len("# subgroup:"):].strip()
        continue
    if not line_stripped or line_stripped.startswith("#"):
        continue

    # Data line format:
    # 1F600         ; fully-qualified     # 😀 E1.0 grinning face
    parts = line.split(";", 1)
    if len(parts) < 2:
        continue

    codepoints_raw = parts[0].strip()
    rest = parts[1].strip()

    # Only include fully-qualified entries to avoid duplicates
    status_and_comment = rest.split("#", 1)
    status = status_and_comment[0].strip()
    if status != "fully-qualified":
        continue

    comment = status_and_comment[1].strip() if len(status_and_comment) > 1 else ""
    # comment format: "😀 E1.0 grinning face"
    comment_parts = comment.split(" ", 2)
    if len(comment_parts) < 3:
        continue

    char = comment_parts[0]
    # comment_parts[1] is the version (E1.0)
    name = comment_parts[2].strip() if len(comment_parts) > 2 else ""

    # Build canonical codepoint string: space-separated lowercase hex, no fe0f
    codepoints = codepoints_raw.split()
    cp_lower = [c.lower() for c in codepoints]
    # canonical storage: hyphens, stripped of fe0f
    cp_no_fe0f = [c for c in cp_lower if c != "fe0f"]
    canonical_cp = "-".join(cp_no_fe0f) if cp_no_fe0f else "-".join(cp_lower)

    emojis.append({
        "char": char,
        "cp": canonical_cp,        # e.g. "1f600" or "1f3c3-1f3fb-200d-2640"
        "name": name,
        "category": current_group,
        "subcategory": current_subgroup,
        "sort_order": len(emojis) + 1,
    })

print(f"  Parsed {len(emojis)} fully-qualified emoji entries")

out_path = os.path.join(OUT_DIR, "emoji_list.json")
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(emojis, f, ensure_ascii=False, separators=(",", ":"))

print(f"  Written → {out_path}  ({os.path.getsize(out_path):,} bytes)")

# ──────────────────────────────────────────────────────────────────────────────
# 2. emoji_keywords.json — emojilib v4 (MIT)
# ──────────────────────────────────────────────────────────────────────────────

EMOJILIB_URL = "https://raw.githubusercontent.com/muan/emojilib/main/dist/emoji-en-US.json"

print(f"\nDownloading emojilib from {EMOJILIB_URL} ...")
try:
    with urllib.request.urlopen(EMOJILIB_URL, timeout=30) as response:
        raw = response.read()
    print(f"  Downloaded {len(raw):,} bytes")
except Exception as e:
    print(f"  ERROR: {e}")
    sys.exit(1)

keywords_data = json.loads(raw.decode("utf-8"))
print(f"  Parsed {len(keywords_data):,} keyword entries")

out_path = os.path.join(OUT_DIR, "emoji_keywords.json")
with open(out_path, "wb") as f:
    f.write(raw)  # write as-is (already compact JSON)

print(f"  Written → {out_path}  ({os.path.getsize(out_path):,} bytes)")

print("\nDone! Both data files are ready.")
