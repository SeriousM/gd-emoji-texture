## EmojiTexturePlugin
## Main EditorPlugin entry point for the EmojiTexture addon.
## Registers the inspector plugin and adds the "Emoji Packs" dock.
## Structured in isolated _init_* blocks so future features (font fallback, etc.)
## can be added by adding a new block without touching existing ones.
@tool
extends EditorPlugin

const DOCK_NAME := "Emoji Packs"

var _inspector_plugin: EmojiInspectorPlugin = null
var _downloader: EmojiDownloader = null
var _dock: Control = null

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _enter_tree() -> void:
	_init_registry()
	_init_downloader()
	_init_inspector()
	_init_custom_type()
	_init_dock()
	print("[EmojiTexture] Plugin enabled.")

func _exit_tree() -> void:
	_teardown_dock()
	_teardown_custom_type()
	_teardown_inspector()
	_teardown_downloader()
	print("[EmojiTexture] Plugin disabled.")

# ── Init blocks ───────────────────────────────────────────────────────────────

func _init_registry() -> void:
	EmojiPackRegistry.reload()

func _init_downloader() -> void:
	_downloader = EmojiDownloader.new()
	_downloader.name = "EmojiDownloader"
	add_child(_downloader)
	_downloader.download_completed.connect(_on_download_completed)
	_downloader.download_progress.connect(_on_download_progress)

func _init_inspector() -> void:
	_inspector_plugin = EmojiInspectorPlugin.new()
	add_inspector_plugin(_inspector_plugin)

func _init_custom_type() -> void:
	var script := preload("res://addons/emoji-texture/emoji_texture.gd")
	var icon   := preload("res://addons/emoji-texture/EmojiTexture.svg")
	add_custom_type("EmojiTexture", "Texture2D", script, icon)

func _init_dock() -> void:
	_dock = _build_dock()
	add_control_to_dock(DOCK_SLOT_LEFT_BR, _dock)
	_refresh_dock()

# ── Teardown blocks ───────────────────────────────────────────────────────────

func _teardown_dock() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

func _teardown_custom_type() -> void:
	remove_custom_type("EmojiTexture")

func _teardown_inspector() -> void:
	if _inspector_plugin != null:
		_inspector_plugin.cleanup()
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null

func _teardown_downloader() -> void:
	if _downloader != null:
		_downloader.queue_free()
		_downloader = null

# ── Dock construction ─────────────────────────────────────────────────────────

func _build_dock() -> Control:
	var root := VBoxContainer.new()
	root.name = DOCK_NAME

	# Header
	var header := Label.new()
	header.text = "Emoji Packs (SVG)"
	header.add_theme_font_size_override("font_size", 13)
	root.add_child(header)

	var sep := HSeparator.new()
	root.add_child(sep)

	# Pack list container — populated by _refresh_dock()
	var list := VBoxContainer.new()
	list.name = "PackList"
	root.add_child(list)

	var sep2 := HSeparator.new()
	root.add_child(sep2)

	# Status label
	var status := Label.new()
	status.name = "StatusLabel"
	status.text = ""
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(status)

	# Progress bar
	var progress := ProgressBar.new()
	progress.name = "ProgressBar"
	progress.visible = false
	progress.min_value = 0
	progress.max_value = 100
	root.add_child(progress)

	return root

func _refresh_dock() -> void:
	if _dock == null:
		return

	var list := _dock.get_node_or_null("PackList") as VBoxContainer
	if list == null:
		return

	# Clear existing pack rows
	for child in list.get_children():
		child.queue_free()

	# One row per SVG pack
	for pack_id in EmojiPackRegistry.get_svg_pack_ids():
		var pack := EmojiPackRegistry.get_pack(pack_id)
		_add_pack_row(list, pack_id, pack)

func _add_pack_row(parent: VBoxContainer, pack_id: String, pack: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.name = "Row_" + pack_id

	# Info vbox
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_lbl := Label.new()
	name_lbl.text = pack.get("name", pack_id)
	info.add_child(name_lbl)

	var detail_lbl := Label.new()
	detail_lbl.name = "DetailLabel"
	detail_lbl.add_theme_font_size_override("font_size", 10)
	_update_pack_detail(detail_lbl, pack_id, pack)
	info.add_child(detail_lbl)

	# Install / Uninstall button
	var btn := Button.new()
	btn.name = "ActionBtn"
	var installed := EmojiPackRegistry.is_pack_installed(pack_id)
	var is_active  := _downloader != null and _downloader.get_active_pack_id() == pack_id
	var is_queued  := _downloader != null and not is_active \
					  and _downloader.is_pack_active_or_queued(pack_id)
	if installed:
		btn.text = "Uninstall"
		btn.pressed.connect(_on_uninstall_pressed.bind(pack_id, row))
	elif is_active:
		btn.text = "Downloading…"
		btn.disabled = true
	elif is_queued:
		btn.text = "Queued…"
		btn.disabled = true
	else:
		btn.text = "Install (%.0f MB)" % pack.get("estimated_size_mb", 0)
		btn.pressed.connect(_on_install_pressed.bind(pack_id, btn))

	row.add_child(info)
	row.add_child(btn)
	parent.add_child(row)

	# Separator
	parent.add_child(HSeparator.new())

func _update_pack_detail(label: Label, pack_id: String, pack: Dictionary) -> void:
	var installed := EmojiPackRegistry.is_pack_installed(pack_id)
	if installed:
		var count := EmojiPackRegistry.get_installed_svg_count(pack_id)
		label.text = "✓ Installed — %d SVGs  |  %s" % [count, pack.get("license", "")]
	else:
		label.text = "Not installed  |  %s  |  v%s" % [pack.get("license", ""), pack.get("version", "")]

# ── Dock event handlers ───────────────────────────────────────────────────────

func _on_install_pressed(pack_id: String, btn: Button) -> void:
	btn.disabled = true
	btn.text = "Downloading…"
	_set_status("Downloading %s…" % EmojiPackRegistry.get_pack(pack_id).get("name", pack_id))
	_set_progress(0, true)
	_downloader.download_pack(pack_id)

func _on_uninstall_pressed(pack_id: String, row: HBoxContainer) -> void:
	var dir_path := EmojiPackRegistry.PACKS_DIR + pack_id + "/"
	var abs_path := ProjectSettings.globalize_path(dir_path)
	if DirAccess.dir_exists_absolute(abs_path):
		_delete_dir_recursive(abs_path)
	# Rescan so Godot removes stale imports
	EditorInterface.get_resource_filesystem().scan()
	# Refresh dock UI
	_refresh_dock()
	_set_status("Pack '%s' removed." % pack_id)

func _on_download_completed(pack_id: String, result: Dictionary) -> void:
	# Show success / error for the finished pack.
	if result.get("status", "") == "ok":
		_set_status("✓ %s installed. Scanning for imports…" % pack_id)
		EditorInterface.get_resource_filesystem().scan()
	else:
		_set_status("✗ Error: " + result.get("message", "Unknown error"))

	# If another pack is already active (queued download started), update the progress bar
	# to reflect it; otherwise hide the bar.
	var next_id := _downloader.get_active_pack_id() if _downloader else ""
	if next_id.is_empty():
		_set_progress(0, false)
	else:
		_set_progress(0, true)
		_set_status("Downloading %s…" % EmojiPackRegistry.get_pack(next_id).get("name", next_id))

	_refresh_dock()

func _on_download_progress(pack_id: String, bytes_down: int, bytes_total: int) -> void:
	if bytes_total > 0:
		var pct := float(bytes_down) / float(bytes_total) * 100.0
		_set_progress(pct, true)
		_set_status("Downloading %s… %.0f%%" % [pack_id, pct])
	else:
		_set_status("Downloading %s… %d KB" % [pack_id, bytes_down / 1024])

# ── Dock helpers ──────────────────────────────────────────────────────────────

func _set_status(text: String) -> void:
	if _dock == null:
		return
	var lbl := _dock.get_node_or_null("StatusLabel") as Label
	if lbl:
		lbl.text = text

func _set_progress(value: float, visible: bool) -> void:
	if _dock == null:
		return
	var bar := _dock.get_node_or_null("ProgressBar") as ProgressBar
	if bar:
		bar.visible = visible
		bar.value = value

func _delete_dir_recursive(abs_path: String) -> void:
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname == "." or fname == "..":
			fname = dir.get_next()
			continue
		var full := abs_path.path_join(fname)
		if dir.current_is_dir():
			_delete_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		fname = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs_path)

# ── Future extension point ────────────────────────────────────────────────────
# To add font fallback support (OmnEmoji-style), add:
#   func _init_font_manager() -> void: ...
#   func _teardown_font_manager() -> void: ...
# and call them from _enter_tree / _exit_tree without touching existing blocks.
