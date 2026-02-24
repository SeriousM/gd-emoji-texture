## EmojiPickerDialog
## Tabbed emoji picker Window, built entirely in code.
## One tab per installed SVG pack. Tabs restore last position via EditorSettings.
## Features: category sections, fuzzy keyword search, recent emojis.
@tool
class_name EmojiPickerDialog
extends Window

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when the user confirms an emoji selection.
signal emoji_selected(codepoint: String, pack_id: String)

# ── Constants ─────────────────────────────────────────────────────────────────

const SETTINGS_LAST_TAB  := "emoji_texture/picker/last_tab"
const SETTINGS_RECENTS   := "emoji_texture/picker/recent_emojis"
const ICON_SIZE          := 128
const GRID_COLUMNS       := 6
const MAX_RECENTS        := 24
const SEARCH_MIN_SCORE   := 20   # minimum score to show in search results

# ── UI nodes (built in _build_ui) ─────────────────────────────────────────────

var _tab_container: TabContainer
var _search_edit: LineEdit
var _recents_row: HBoxContainer
var _search_results_panel: ScrollContainer
var _search_grid: GridContainer

# ── State ──────────────────────────────────────────────────────────────────────

var _recents: Array[Dictionary] = []        # [{cp, pack_id, char}]
var _current_pack_id := ""                  # pack shown in the active tab
var _pack_grids: Dictionary = {}            # pack_id → { category → GridContainer }
var _built := false
var _load_generation := 0                   # incremented on each refresh to cancel stale coroutines
var _loading := false
var _load_total := 0
var _load_done  := 0

## Emoji buttons to create per frame during async population.
const LOAD_BATCH := 40

# ── Loading overlay nodes ────────────────────────────────────────────────────

var _loading_overlay: PanelContainer
var _progress_bar: ProgressBar
var _progress_label: Label

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	title = "Pick Emoji"
	min_size = Vector2(700, 620)
	size = Vector2(860, 740)
	wrap_controls = true
	exclusive = true
	close_requested.connect(_on_close_requested)
	_build_ui()
	_load_recents()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible:
		# Ensure UI is built even if _ready() hasn't fired yet
		# (NOTIFICATION_VISIBILITY_CHANGED can arrive before _ready when popup_centered
		# is called immediately after add_child in the same frame).
		_build_ui()
		_load_recents()
		_refresh_tabs()
		_restore_last_tab()
		_populate_recents_row()

# ── Build UI ──────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	if _built:
		return
	_built = true

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	# ── Search bar ──
	var search_row := HBoxContainer.new()
	root.add_child(search_row)

	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search emoji…"
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.clear_button_enabled = true
	_search_edit.text_changed.connect(_on_search_changed)
	search_row.add_child(_search_edit)

	# ── Recents row ──
	var recents_panel := PanelContainer.new()
	root.add_child(recents_panel)

	var recents_vbox := VBoxContainer.new()
	recents_panel.add_child(recents_vbox)

	var recents_label := Label.new()
	recents_label.text = "Recent"
	recents_label.add_theme_font_size_override("font_size", 11)
	recents_vbox.add_child(recents_label)

	var recents_scroll := ScrollContainer.new()
	recents_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	recents_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	recents_scroll.custom_minimum_size = Vector2(0, ICON_SIZE + 10)
	recents_vbox.add_child(recents_scroll)

	_recents_row = HBoxContainer.new()
	_recents_row.add_theme_constant_override("separation", 2)
	recents_scroll.add_child(_recents_row)

	# ── Search results panel (hidden unless searching) ──
	_search_results_panel = ScrollContainer.new()
	_search_results_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_search_results_panel.visible = false
	root.add_child(_search_results_panel)

	_search_grid = GridContainer.new()
	_search_grid.columns = GRID_COLUMNS
	_search_grid.add_theme_constant_override("h_separation", 2)
	_search_grid.add_theme_constant_override("v_separation", 2)
	_search_results_panel.add_child(_search_grid)

	# ── Tab container ──
	_tab_container = TabContainer.new()
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_container.tab_changed.connect(_on_tab_changed)
	root.add_child(_tab_container)

	# ── Loading progress overlay (slim bar at bottom, hidden when idle) ──
	_loading_overlay = PanelContainer.new()
	_loading_overlay.visible = false
	root.add_child(_loading_overlay)

	var _ov_hbox := HBoxContainer.new()
	_ov_hbox.add_theme_constant_override("separation", 6)
	_loading_overlay.add_child(_ov_hbox)

	_progress_label = Label.new()
	_progress_label.text = "Loading…"
	_progress_label.add_theme_font_size_override("font_size", 11)
	_ov_hbox.add_child(_progress_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.value = 0.0
	_progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress_bar.custom_minimum_size = Vector2(0, 14)
	_ov_hbox.add_child(_progress_bar)

# ── Tab population ────────────────────────────────────────────────────────────

func _refresh_tabs() -> void:
	# Cancel any in-flight population coroutine from a previous refresh.
	_load_generation += 1

	# Remove stale tabs
	for i in range(_tab_container.get_tab_count() - 1, -1, -1):
		_tab_container.remove_child(_tab_container.get_tab_control(i))

	_pack_grids = {}

	var svg_packs := EmojiPackRegistry.get_svg_pack_ids()
	var any_installed := false
	var task_queue: Array = []   # Array of {grid, record, pack_id}

	for pack_id in svg_packs:
		if not EmojiPackRegistry.is_pack_installed(pack_id):
			# Show an "Install pack" placeholder tab
			_add_placeholder_tab(pack_id)
			continue
		any_installed = true
		_add_pack_tab(pack_id, task_queue)

	if not any_installed and svg_packs.is_empty():
		_add_no_packs_tab()

	if not task_queue.is_empty():
		_populate_all_async(task_queue, _load_generation)

## Build the structural nodes for a pack tab (labels + empty grids) and
## append one task entry per emoji into task_queue for async button creation.
func _add_pack_tab(pack_id: String, task_queue: Array) -> void:
	var pack := EmojiPackRegistry.get_pack(pack_id)
	var tab_name: String = pack.get("name", pack_id)

	var scroll := ScrollContainer.new()
	scroll.name = tab_name
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	var categories := EmojiPackRegistry.get_categories()
	var grids: Dictionary = {}

	for category in categories:
		var groups := EmojiPackRegistry.get_grouped_emoji_for_category(category)
		if groups.is_empty():
			continue

		# Category header
		var cat_label := Label.new()
		cat_label.text = category
		cat_label.add_theme_font_size_override("font_size", 22)
		cat_label.add_theme_constant_override("margin_top", 10)
		vbox.add_child(cat_label)

		for group in groups:
			var subcat: String = group.get("subcategory", "")
			var emoji_list: Array = group.get("emoji", [])
			if emoji_list.is_empty():
				continue

			# Subcategory label
			var sub_label := Label.new()
			sub_label.text = "  " + subcat.replace("-", " ").replace("_", " ").capitalize()
			sub_label.add_theme_font_size_override("font_size", 16)
			vbox.add_child(sub_label)

			# Empty grid — buttons are added asynchronously
			var grid := GridContainer.new()
			grid.columns = GRID_COLUMNS
			grid.add_theme_constant_override("h_separation", 2)
			grid.add_theme_constant_override("v_separation", 2)
			vbox.add_child(grid)

			for emoji_record in emoji_list:
				task_queue.append({"grid": grid, "record": emoji_record, "pack_id": pack_id})

			grids[subcat] = grid

	_pack_grids[pack_id] = grids
	_tab_container.add_child(scroll)

## Fills emoji buttons into their grids over multiple frames to prevent freezing.
## generation must match _load_generation — if it drifts a newer refresh has started
## and this coroutine should exit silently.
func _populate_all_async(task_queue: Array, generation: int) -> void:
	_loading = true
	_load_total = task_queue.size()
	_load_done  = 0
	_progress_bar.max_value = _load_total
	_progress_bar.value     = 0.0
	_progress_label.text    = "Loading 0 / %d…" % _load_total
	_loading_overlay.visible = true

	var i := 0
	while i < task_queue.size():
		if generation != _load_generation:
			# A newer _refresh_tabs() call has superseded us — exit without touching UI.
			return
		var batch_end := mini(i + LOAD_BATCH, task_queue.size())
		while i < batch_end:
			var t: Dictionary = task_queue[i]
			_add_emoji_button(t["grid"], t["record"], t["pack_id"])
			i += 1
		_load_done = i
		_progress_bar.value  = _load_done
		_progress_label.text = "Loading %d / %d…" % [_load_done, _load_total]
		await get_tree().process_frame

	if generation == _load_generation:
		_loading = false
		_loading_overlay.visible = false

func _add_placeholder_tab(pack_id: String) -> void:
	var pack := EmojiPackRegistry.get_pack(pack_id)
	var tab_name: String = pack.get("name", pack_id) + " ⬇"

	var vbox := VBoxContainer.new()
	vbox.name = tab_name
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER

	var lbl := Label.new()
	lbl.text = ("Pack not installed.\nUse the 'Emoji Packs' dock\nto download '%s'." % pack.get("name", pack_id))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	_tab_container.add_child(vbox)

func _add_no_packs_tab() -> void:
	var vbox := VBoxContainer.new()
	vbox.name = "No Packs"
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER

	var lbl := Label.new()
	lbl.text = "No emoji packs installed.\nOpen the 'Emoji Packs' dock to download one."
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	_tab_container.add_child(vbox)

# ── Emoji button ──────────────────────────────────────────────────────────────

func _add_emoji_button(parent: GridContainer, emoji_record: Dictionary, pack_id: String) -> void:
	var cp: String = emoji_record.get("cp", "")
	var char_val: String = emoji_record.get("char", "")
	var display_name: String = EmojiPackRegistry.get_display_name(emoji_record)

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	btn.tooltip_text = display_name
	btn.flat = true

	var svg_path := EmojiPackRegistry.get_svg_path(pack_id, cp) if not pack_id.is_empty() else ""
	if not svg_path.is_empty() and ResourceLoader.exists(svg_path):
		var tex = ResourceLoader.load(svg_path, "Texture2D", ResourceLoader.CACHE_MODE_REUSE)
		if tex is Texture2D:
			btn.icon = tex
			btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			btn.expand_icon = true
			btn.text = ""
		else:
			btn.text = char_val
	else:
		# SVG not available — fall back to the emoji character rendered large
		btn.text = char_val
		btn.add_theme_font_size_override("font_size", ICON_SIZE * 65 / 100)
	btn.pressed.connect(_on_emoji_selected.bind(cp, pack_id, char_val))
	parent.add_child(btn)

# ── Search ────────────────────────────────────────────────────────────────────

func _on_search_changed(query: String) -> void:
	if query.strip_edges().is_empty():
		_search_results_panel.visible = false
		_tab_container.visible = true
		return

	_search_results_panel.visible = true
	_tab_container.visible = false

	# Collect and score
	var active_pack := _get_active_pack_id()
	# If active tab has no pack (placeholder), find first installed pack
	if active_pack.is_empty() or not EmojiPackRegistry.is_pack_installed(active_pack):
		active_pack = ""
		for pid in EmojiPackRegistry.get_svg_pack_ids():
			if EmojiPackRegistry.is_pack_installed(pid):
				active_pack = pid
				break
	var search_pack := active_pack

	var scored: Array[Dictionary] = []
	for emoji_record in EmojiPackRegistry.get_emoji_list():
		var s := EmojiPackRegistry.score_emoji(query, emoji_record)
		if s >= SEARCH_MIN_SCORE:
			scored.append({"score": s, "record": emoji_record})

	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["score"] > b["score"])

	# Rebuild search grid
	for child in _search_grid.get_children():
		child.queue_free()

	var shown := 0
	for item in scored:
		if shown >= 80:
			break
		_add_emoji_button(_search_grid, item["record"], search_pack)
		shown += 1

# ── Recents ───────────────────────────────────────────────────────────────────

func _load_recents() -> void:
	_recents = []
	if not EditorInterface.get_editor_settings().has_setting(SETTINGS_RECENTS):
		return
	var raw: String = EditorInterface.get_editor_settings().get_setting(SETTINGS_RECENTS)
	for entry in raw.split(",", false):
		var parts := entry.split("|", false)
		if parts.size() >= 2:
			_recents.append({"cp": parts[0], "pack_id": parts[1], "char": parts[2] if parts.size() > 2 else ""})

func _save_recents() -> void:
	var parts: PackedStringArray = []
	for r in _recents:
		parts.append("%s|%s|%s" % [r["cp"], r["pack_id"], r.get("char", "")])
	EditorInterface.get_editor_settings().set_setting(SETTINGS_RECENTS, ",".join(parts))

func _add_to_recents(cp: String, pack_id: String, char_val: String) -> void:
	# Remove existing entry for same cp+pack
	_recents = _recents.filter(func(r: Dictionary) -> bool:
		return not (r["cp"] == cp and r["pack_id"] == pack_id))
	_recents.push_front({"cp": cp, "pack_id": pack_id, "char": char_val})
	if _recents.size() > MAX_RECENTS:
		_recents.resize(MAX_RECENTS)
	_save_recents()
	_populate_recents_row()

func _populate_recents_row() -> void:
	for child in _recents_row.get_children():
		child.queue_free()

	if _recents.is_empty():
		var hint := Label.new()
		hint.text = "No recent emoji yet."
		hint.add_theme_font_size_override("font_size", 10)
		_recents_row.add_child(hint)
		return

	for r in _recents:
		var cp: String = r["cp"]
		var pid: String = r["pack_id"]
		var char_val: String = r.get("char", "")

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
		btn.flat = true

		var svg_path := EmojiPackRegistry.get_svg_path(pid, cp)
		if ResourceLoader.exists(svg_path):
			var tex = ResourceLoader.load(svg_path, "Texture2D", ResourceLoader.CACHE_MODE_REUSE)
			if tex is Texture2D:
				btn.icon = tex
				btn.expand_icon = true
				btn.text = ""
		if btn.icon == null:
			btn.text = char_val
			btn.add_theme_font_size_override("font_size", ICON_SIZE * 65 / 100)

		btn.pressed.connect(_on_emoji_selected.bind(cp, pid, char_val))
		_recents_row.add_child(btn)

# ── Tab persistence ───────────────────────────────────────────────────────────

func _restore_last_tab() -> void:
	if not EditorInterface.get_editor_settings().has_setting(SETTINGS_LAST_TAB):
		return
	var last := int(EditorInterface.get_editor_settings().get_setting(SETTINGS_LAST_TAB))
	if last >= 0 and last < _tab_container.get_tab_count():
		_tab_container.current_tab = last

func _on_tab_changed(idx: int) -> void:
	EditorInterface.get_editor_settings().set_setting(SETTINGS_LAST_TAB, idx)

func _get_active_pack_id() -> String:
	var tab_idx := _tab_container.current_tab
	if tab_idx < 0 or tab_idx >= _tab_container.get_tab_count():
		return ""
	# Match tab index to pack order
	var svg_packs := EmojiPackRegistry.get_svg_pack_ids()
	if tab_idx < svg_packs.size():
		return svg_packs[tab_idx]
	return ""

# ── Selection ─────────────────────────────────────────────────────────────────

func _on_emoji_selected(cp: String, pack_id: String, char_val: String) -> void:
	_add_to_recents(cp, pack_id, char_val)
	emit_signal("emoji_selected", cp, pack_id)
	hide()

func _on_close_requested() -> void:
	hide()

# ── Public ────────────────────────────────────────────────────────────────────

## Call before show() to select a specific pack tab by id.
func focus_pack(pack_id: String) -> void:
	var svg_packs := EmojiPackRegistry.get_svg_pack_ids()
	var idx := svg_packs.find(pack_id)
	if idx >= 0 and idx < _tab_container.get_tab_count():
		_tab_container.current_tab = idx
