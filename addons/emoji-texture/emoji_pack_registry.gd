## EmojiPackRegistry
## Static class — loads and caches all provider/data JSON files.
## SVG-specific logic is isolated to get_svg_path(); everything else is type-agnostic
## so font-based packs can be added later without touching the public API.
class_name EmojiPackRegistry
extends RefCounted

const PACKS_JSON     := "res://addons/emoji-texture/providers/packs.json"
const EMOJI_LIST_JSON := "res://addons/emoji-texture/data/emoji_list.json"
const KEYWORDS_JSON  := "res://addons/emoji-texture/data/emoji_keywords.json"
const PACKS_DIR      := "res://addons/emoji-texture/packs/"

# ── Cache ──────────────────────────────────────────────────────────────────────
static var _packs: Dictionary = {}          # id → pack Dictionary
static var _pack_ids: PackedStringArray = []
static var _emoji_list: Array = []
static var _keywords: Dictionary = {}       # char → Array[String]
static var _loaded := false

# ── Load / Reload ──────────────────────────────────────────────────────────────

static func _ensure_loaded() -> void:
	if _loaded:
		return
	reload()

static func reload() -> void:
	_packs = {}
	_pack_ids = []
	_emoji_list = []
	_keywords = {}

	# packs.json
	var packs_json := _load_json(PACKS_JSON) as Dictionary
	if packs_json.has("packs"):
		for pack: Dictionary in packs_json["packs"]:
			var id: String = pack.get("id", "")
			if id.is_empty():
				continue
			_packs[id] = pack
			_pack_ids.append(id)

	# emoji_list.json
	var list = _load_json(EMOJI_LIST_JSON)
	if list is Array:
		_emoji_list = list

	# emoji_keywords.json
	var kw = _load_json(KEYWORDS_JSON)
	if kw is Dictionary:
		_keywords = kw

	_loaded = true
	print("[EmojiTexture] Registry loaded: %d packs, %d emoji, %d keyword entries"
		% [_pack_ids.size(), _emoji_list.size(), _keywords.size()])

static func _load_json(path: String):
	if not FileAccess.file_exists(path):
		push_warning("[EmojiTexture] JSON not found: " + path)
		return null
	var text := FileAccess.get_file_as_string(path)
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_warning("[EmojiTexture] JSON parse error in %s: %s" % [path, json.get_error_message()])
		return null
	return json.get_data()

# ── Pack queries (type-agnostic) ───────────────────────────────────────────────

static func get_pack_ids() -> PackedStringArray:
	_ensure_loaded()
	return _pack_ids

## Returns packs filtered by type string ("svg", "font", …)
static func get_packs_of_type(type: String) -> Array:
	_ensure_loaded()
	var result: Array = []
	for id in _pack_ids:
		if _packs[id].get("type", "") == type:
			result.append(_packs[id])
	return result

## Returns the pack dictionary for the given id, or an empty Dictionary.
static func get_pack(id: String) -> Dictionary:
	_ensure_loaded()
	return _packs.get(id, {})

## Returns ids of all packs whose type is "svg".
static func get_svg_pack_ids() -> PackedStringArray:
	_ensure_loaded()
	var result: PackedStringArray = []
	for id in _pack_ids:
		if _packs[id].get("type", "") == "svg":
			result.append(id)
	return result

## True when the pack directory exists and contains at least one .svg file.
static func is_pack_installed(id: String) -> bool:
	_ensure_loaded()
	var dir_path := PACKS_DIR + id + "/"
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)):
		return false
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return false
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".svg"):
			dir.list_dir_end()
			return true
		fname = dir.get_next()
	dir.list_dir_end()
	return false

## Counts installed SVG files for a pack (0 if not installed).
static func get_installed_svg_count(id: String) -> int:
	if not is_pack_installed(id):
		return 0
	var dir := DirAccess.open(PACKS_DIR + id + "/")
	if dir == null:
		return 0
	var count := 0
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".svg"):
			count += 1
		fname = dir.get_next()
	dir.list_dir_end()
	return count

# ── SVG-specific path resolution ───────────────────────────────────────────────

## Returns the res:// path to the SVG file for a given pack and canonical codepoint.
## canonical_cp is hyphen-separated lowercase hex WITHOUT fe0f, e.g. "1f600" or "1f3c3-1f3fb-200d-2640".
## Returns "" if the pack is unknown or has wrong type.
static func get_svg_path(pack_id: String, canonical_cp: String) -> String:
	_ensure_loaded()
	var pack := get_pack(pack_id)
	if pack.is_empty() or pack.get("type", "") != "svg":
		return ""

	var sep: String = pack.get("codepoint_separator", "-")
	var case_mode: String = pack.get("codepoint_case", "lower")

	## hex_min_digits controls leading-zero handling per pack:
	##   4  → pad each part to at least 4 hex digits ("a9" → "00a9", as OpenMoji expects)
	##   0  → strip leading zeros ("00a9" → "a9", "0023" → "23", as Twemoji expects)
	var hex_min: int = pack.get("hex_min_digits", 4)

	var raw_parts := canonical_cp.split("-")

	# Build the adjusted codepoint string
	var adjusted_parts: PackedStringArray = []
	for p in raw_parts:
		var part := p
		if hex_min == 0:
			part = part.lstrip("0")
			if part.is_empty():
				part = "0"
		else:
			while part.length() < hex_min:
				part = "0" + part
		if case_mode == "upper":
			part = part.to_upper()
		adjusted_parts.append(part)

	var cp := sep.join(adjusted_parts)
	var filename: String = pack.get("filename_prefix", "") + cp + pack.get("filename_suffix", ".svg")
	var path := PACKS_DIR + pack_id + "/" + filename

	# fe0f probe: for packs that embed fe0f in filenames (e.g. twemoji), the canonical cp
	# has fe0f stripped, but the actual file may include it (e.g. "2764-fe0f-200d-1f525.svg").
	# Try inserting "fe0f" after each raw codepoint part until a match is found.
	if pack.get("fe0f_in_filename", false) and not ResourceLoader.exists(path):
		for i in range(raw_parts.size()):
			var probe := raw_parts.duplicate()
			probe.insert(i + 1, "fe0f")
			var probe_parts: PackedStringArray = []
			for p in probe:
				var part := p
				if hex_min == 0:
					part = part.lstrip("0")
					if part.is_empty():
						part = "0"
				else:
					while part.length() < hex_min:
						part = "0" + part
				if case_mode == "upper":
					part = part.to_upper()
				probe_parts.append(part)
			var probe_path: String = PACKS_DIR + pack_id + "/" + \
					(pack.get("filename_prefix", "") as String) + sep.join(probe_parts) + (pack.get("filename_suffix", ".svg") as String)
			if ResourceLoader.exists(probe_path):
				return probe_path

	return path

## Convenience: given the emoji character itself, derive canonical_cp and return svg path.
static func get_svg_path_for_char(pack_id: String, emoji_char: String) -> String:
	var cp := _char_to_canonical_cp(emoji_char)
	return get_svg_path(pack_id, cp)

static func _char_to_canonical_cp(emoji_char: String) -> String:
	var parts: PackedStringArray = []
	var i := 0
	while i < emoji_char.length():
		var code := emoji_char.unicode_at(i)
		if code >= 0xD800 and code <= 0xDBFF:
			# High surrogate — GDScript strings are UTF-32 so this shouldn't occur,
			# but handle just in case.
			i += 1
			continue
		if code != 0xFE0F:  # strip variation selector
			parts.append("%x" % code)
		i += 1
	return "-".join(parts)

# ── Emoji list ────────────────────────────────────────────────────────────────

static func get_emoji_list() -> Array:
	_ensure_loaded()
	return _emoji_list

## Returns all unique categories in order of first appearance.
static func get_categories() -> PackedStringArray:
	_ensure_loaded()
	var seen: Dictionary = {}
	var result: PackedStringArray = []
	for e: Dictionary in _emoji_list:
		var cat: String = e.get("category", "")
		if not seen.has(cat):
			seen[cat] = true
			result.append(cat)
	return result

## Returns all emoji records for a given category.
static func get_emoji_for_category(category: String) -> Array:
	_ensure_loaded()
	var result: Array = []
	for e: Dictionary in _emoji_list:
		if e.get("category", "") == category:
			result.append(e)
	return result

## Returns subcategory-grouped structure:
## [ { "subcategory": "...", "emoji": [ {...}, ... ] }, ... ]
static func get_grouped_emoji_for_category(category: String) -> Array:
	_ensure_loaded()
	var groups: Array = []
	var subcat_index: Dictionary = {}  # subcat_name → index in groups
	for e: Dictionary in _emoji_list:
		if e.get("category", "") != category:
			continue
		var sub: String = e.get("subcategory", "other")
		if not subcat_index.has(sub):
			subcat_index[sub] = groups.size()
			groups.append({"subcategory": sub, "emoji": []})
		groups[subcat_index[sub]]["emoji"].append(e)
	return groups

# ── Display helpers ─────────────────────────────────────────────────────────────

## Converts a raw name (may use underscores from unicode-cldr) to a human-readable
## display string: underscores → spaces, then title-cased.
static func get_display_name(emoji_record: Dictionary) -> String:
	return emoji_record.get("name", "").replace("_", " ").capitalize()

# ── Keyword / search ───────────────────────────────────────────────────────────

static func get_keywords(emoji_char: String) -> PackedStringArray:
	_ensure_loaded()
	var kw = _keywords.get(emoji_char, [])
	if kw is Array:
		return PackedStringArray(kw)
	return PackedStringArray()

## Scores how well an emoji record matches a query string. Returns 0 for no match.
## 100 = exact char, 80 = name starts with, 60 = keyword starts with,
## 40 = name contains, 20 = keyword contains.
static func score_emoji(query: String, emoji_record: Dictionary) -> int:
	if query.is_empty():
		return 1  # show everything when no query
	var q := query.to_lower().strip_edges()
	var char_val: String = emoji_record.get("char", "")
	# Support both raw (underscore) and display (space) name matching
	var raw_name: String = emoji_record.get("name", "").to_lower()
	var name: String = raw_name.replace("_", " ")
	var keywords := get_keywords(char_val)

	# Exact char match
	if char_val == query:
		return 100

	# Name starts with query
	if name.begins_with(q) or raw_name.begins_with(q):
		return 80

	# Any keyword starts with query
	for kw in keywords:
		if kw.begins_with(q):
			return 60

	# Name contains query
	if name.contains(q) or raw_name.contains(q):
		return 40

	# Any keyword contains query
	for kw in keywords:
		if kw.contains(q):
			return 20

	return 0
