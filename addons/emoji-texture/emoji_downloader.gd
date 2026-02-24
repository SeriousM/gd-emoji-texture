## EmojiDownloader
## Async HTTP download + ZIP extraction for emoji SVG packs.
## Add to the scene tree before calling download_pack().
## Follows the same serial-queue pattern as OmnEmoji's font_downloader.gd,
## and is intentionally type-agnostic so font downloads can reuse it later.
class_name EmojiDownloader
extends Node

# ── Signals ────────────────────────────────────────────────────────────────────

## Emitted periodically during download. bytes_total may be -1 if unknown.
signal download_progress(pack_id: String, bytes_downloaded: int, bytes_total: int)

## Emitted when a pack download finishes (success or failure).
## result keys: status (String), message (String), pack_id (String)
signal download_completed(pack_id: String, result: Dictionary)

# ── Constants ──────────────────────────────────────────────────────────────────

const MIN_FILE_BYTES := 64           # smallest acceptable SVG (SVGO-optimised simple emoji can be ~370 bytes)
const TEMP_ZIP_NAME  := "_emoji_dl_tmp.zip"

## Minimal .import sidecar written next to each extracted SVG.
## Setting svg/scale=4.0 means Twemoji (36 px viewBox) → 144 px texture,
## and OpenMoji (72 px viewBox) → 288 px texture — crisp at 128 px display.
const SVG_IMPORT_TEMPLATE := """[remap]

importer=\"texture\"
type=\"CompressedTexture2D\"

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=false
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=\"\"
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=1
svg/scale=4.0
editor/scale_with_editor_scale=false
editor/convert_colors_with_editor_theme=false
"""

# ── State ──────────────────────────────────────────────────────────────────────

var _http: HTTPRequest = null
var _queue: Array[Dictionary] = []   # pending download tasks
var _current: Dictionary = {}        # active task
var _is_downloading := false
var _extract_thread: Thread = null   # background extraction thread

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 300.0            # large ZIPs can take time
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

func _exit_tree() -> void:
	if _is_downloading:
		_http.cancel_request()
	if _extract_thread and _extract_thread.is_started():
		_extract_thread.wait_to_finish()

# ── Public API ────────────────────────────────────────────────────────────────

## Queue a pack for download. Safe to call multiple times; queued serially.
func download_pack(pack_id: String) -> void:
	var pack := EmojiPackRegistry.get_pack(pack_id)
	if pack.is_empty():
		push_warning("[EmojiDownloader] Unknown pack id: " + pack_id)
		emit_signal("download_completed", pack_id,
			{"status": "error", "message": "Unknown pack: " + pack_id, "pack_id": pack_id})
		return

	var mirrors: Array = pack.get("mirrors", [])
	if mirrors.is_empty():
		push_warning("[EmojiDownloader] No mirrors for pack: " + pack_id)
		emit_signal("download_completed", pack_id,
			{"status": "error", "message": "No mirrors configured.", "pack_id": pack_id})
		return

	_queue.append({
		"pack_id": pack_id,
		"pack": pack,
		"mirrors": mirrors.duplicate(),
		"mirror_index": 0,
	})
	print("[EmojiDownloader] Queued pack: %s (%d mirror(s))" % [pack_id, mirrors.size()])
	_process_queue()

func is_downloading() -> bool:
	return _is_downloading

## Returns the pack_id currently being downloaded, or "" if idle.
func get_active_pack_id() -> String:
	return _current.get("pack_id", "")

## Returns true if pack_id is either active or waiting in the queue.
func is_pack_active_or_queued(pack_id: String) -> bool:
	if _current.get("pack_id", "") == pack_id:
		return true
	for task: Dictionary in _queue:
		if task["pack_id"] == pack_id:
			return true
	return false

## Cancel a pending or active download for the given pack_id.
func cancel_pack(pack_id: String) -> void:
	# Remove from queue
	_queue = _queue.filter(func(t: Dictionary) -> bool: return t["pack_id"] != pack_id)
	# Cancel active if it matches
	if _is_downloading and _current.get("pack_id", "") == pack_id:
		_http.cancel_request()
		_is_downloading = false
		_current = {}
		_process_queue()

# ── Internal ──────────────────────────────────────────────────────────────────

func _process_queue() -> void:
	if _is_downloading or _queue.is_empty():
		return
	_current = _queue.pop_front()
	_try_mirror()

func _try_mirror() -> void:
	var mirrors: Array = _current["mirrors"]
	var idx: int = _current["mirror_index"]
	if idx >= mirrors.size():
		_fail("All mirrors failed for pack: " + _current["pack_id"])
		return

	var url: String = mirrors[idx]
	print("[EmojiDownloader] Downloading %s from mirror %d: %s" % [_current["pack_id"], idx, url])
	_is_downloading = true

	var err := _http.request(url)
	if err != OK:
		push_warning("[EmojiDownloader] HTTPRequest error %d for %s" % [err, url])
		_current["mirror_index"] += 1
		_try_mirror()

func _on_request_completed(result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	var pack_id: String = _current.get("pack_id", "?")

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_warning("[EmojiDownloader] HTTP %d / result %d for %s — trying next mirror"
			% [response_code, result, pack_id])
		_current["mirror_index"] += 1
		_try_mirror()
		return

	print("[EmojiDownloader] Download complete for %s: %d bytes" % [pack_id, body.size()])
	emit_signal("download_progress", pack_id, body.size(), body.size())

	# Write body to temp file then extract
	var tmp_path := _get_tmp_path()
	var fa := FileAccess.open(tmp_path, FileAccess.WRITE)
	if fa == null:
		_fail("Cannot write temp file: " + tmp_path)
		return
	fa.store_buffer(body)
	fa.close()

	# Capture task data; extraction runs on a background thread to avoid blocking the editor.
	var task_snapshot := _current.duplicate(true)
	_extract_thread = Thread.new()
	_extract_thread.start(_extract_zip_threaded.bind(tmp_path, task_snapshot))

func _extract_zip_threaded(zip_path: String, task: Dictionary) -> void:
	## Runs on a background thread. Calls _on_extract_finished via call_deferred when done.
	var pack_id: String    = task["pack_id"]
	var pack: Dictionary   = task["pack"]
	var inner_prefix: String = pack.get("zip_inner_path", "")
	var dest_dir := EmojiPackRegistry.PACKS_DIR + pack_id + "/"

	# Resolve all res:// paths to absolute paths HERE, on the main thread context,
	# before entering the loop. Calling ProjectSettings.globalize_path() thousands
	# of times inside a thread loop can fail with "null value" mid-run.
	var dest_abs := ProjectSettings.globalize_path(dest_dir)
	var zip_abs  := ProjectSettings.globalize_path(zip_path)

	# Ensure destination directory exists
	DirAccess.make_dir_recursive_absolute(dest_abs)

	var reader := ZIPReader.new()
	var err := reader.open(zip_abs)
	if err != OK:
		_cleanup_tmp(zip_path)
		# _fail must run on the main thread
		call_deferred("_fail", "ZIPReader failed to open temp file (err %d)" % err)
		return

	var files := reader.get_files()
	var extracted := 0
	var skipped := 0

	for f in files:
		# Filter by inner path prefix
		if not inner_prefix.is_empty() and not f.begins_with(inner_prefix):
			continue
		# Must end with .svg
		if not f.ends_with(".svg"):
			continue
		# Must not be a directory entry
		if f.ends_with("/"):
			continue

		var file_bytes := reader.read_file(f)
		if file_bytes.size() < MIN_FILE_BYTES:
			skipped += 1
			continue

		# Derive output filename (strip the inner path prefix)
		var out_name := f.get_file()   # just the filename
		var out_abs := dest_abs + out_name

		var fw := FileAccess.open(out_abs, FileAccess.WRITE)
		if fw == null:
			push_warning("[EmojiDownloader] Cannot write: " + out_abs)
			continue
		fw.store_buffer(file_bytes)
		fw.close()

		# Write .import sidecar so Godot rasterises the SVG at 4× scale (crisp at 128 px).
		var import_abs := out_abs + ".import"
		var fi := FileAccess.open(import_abs, FileAccess.WRITE)
		if fi != null:
			fi.store_string(SVG_IMPORT_TEMPLATE)
			fi.close()

		extracted += 1

		# Emit progress every 100 files (call_deferred — we're on a thread)
		if extracted % 100 == 0:
			call_deferred("emit_signal", "download_progress", pack_id, extracted, files.size())

	reader.close()
	_cleanup_tmp(zip_path)

	# Write LICENSE file
	var license_text: String = pack.get("attribution", "")
	if not license_text.is_empty():
		var lic_path := dest_abs + "LICENSE.txt"
		var lf := FileAccess.open(lic_path, FileAccess.WRITE)
		if lf:
			lf.store_string(license_text + "\n\nLicense URL: " + pack.get("license_url", "") + "\n")
			lf.close()

	print("[EmojiDownloader] Extracted %d SVGs for pack '%s' (skipped %d tiny files)"
		% [extracted, pack_id, skipped])

	# Return to main thread
	call_deferred("_on_extract_finished", pack_id, extracted, skipped)

func _on_extract_finished(pack_id: String, extracted: int, _skipped: int) -> void:
	if _extract_thread and _extract_thread.is_started():
		_extract_thread.wait_to_finish()
	_extract_thread = null

	if extracted == 0:
		_fail("No SVG files extracted from ZIP for " + pack_id)
		return

	print("[EmojiDownloader] Pack '%s' ready." % pack_id)
	_is_downloading = false
	_current = {}
	_process_queue()   # start next queued pack BEFORE emitting, so listeners see correct state
	emit_signal("download_completed", pack_id, {
		"status": "ok",
		"message": "Extracted %d SVG files." % extracted,
		"pack_id": pack_id,
	})

func _fail(message: String) -> void:
	var pack_id: String = _current.get("pack_id", "?")
	push_error("[EmojiDownloader] " + message)
	_is_downloading = false
	_current = {}
	_process_queue()   # start next queued pack BEFORE emitting, so listeners see correct state
	emit_signal("download_completed", pack_id, {
		"status": "error",
		"message": message,
		"pack_id": pack_id,
	})

func _get_tmp_path() -> String:
	return ProjectSettings.globalize_path("user://" + TEMP_ZIP_NAME)

func _cleanup_tmp(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
