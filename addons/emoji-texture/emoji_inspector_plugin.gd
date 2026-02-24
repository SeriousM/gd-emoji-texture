## EmojiInspectorPlugin
## Injects a "Pick Emoji" button into the inspector when an EmojiTexture is selected.
@tool
class_name EmojiInspectorPlugin
extends EditorInspectorPlugin

var _picker: EmojiPickerDialog = null
var _active_texture: EmojiTexture = null
var _preview_container: HBoxContainer = null   # stored so non-bound signal works

# ── EditorInspectorPlugin API ─────────────────────────────────────────────────

func _can_handle(object: Object) -> bool:
	return object is EmojiTexture

func _parse_begin(object: Object) -> void:
	if not object is EmojiTexture:
		return

	# Disconnect from previous resource before switching
	if is_instance_valid(_active_texture):
		if _active_texture.changed.is_connected(_on_resource_changed):
			_active_texture.changed.disconnect(_on_resource_changed)

	_active_texture = object as EmojiTexture

	var container := HBoxContainer.new()
	container.add_theme_constant_override("separation", 8)

	# Preview panel
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(80, 80)
	preview.expand_mode = TextureRect.EXPAND_FIT_HEIGHT_PROPORTIONAL
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.name = "EmojiPreview"

	# Info label
	var info_vbox := VBoxContainer.new()
	info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_label := Label.new()
	name_label.name = "EmojiName"
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_vbox.add_child(name_label)

	var pack_label := Label.new()
	pack_label.name = "PackLabel"
	pack_label.add_theme_font_size_override("font_size", 10)
	info_vbox.add_child(pack_label)

	# Pick button
	var btn := Button.new()
	btn.text = "Pick Emoji…"
	btn.pressed.connect(_on_pick_pressed)

	container.add_child(preview)
	container.add_child(info_vbox)
	container.add_child(btn)
	add_custom_control(container)

	# Store container so the non-bound signal handler can find it
	_preview_container = container

	# Populate preview with current value
	_refresh_preview()

	# Connect to changes so preview updates live (non-bound — avoids duplicate issues)
	object.changed.connect(_on_resource_changed)

# ── Helpers ───────────────────────────────────────────────────────────────────

func _on_resource_changed() -> void:
	_refresh_preview()

func _refresh_preview() -> void:
	var container := _preview_container
	if not is_instance_valid(_active_texture):
		return
	if not is_instance_valid(container):
		return

	var preview := container.get_node_or_null("EmojiPreview") as TextureRect
	var name_label := container.get_node_or_null("EmojiName") as Label
	var pack_label := container.get_node_or_null("PackLabel") as Label

	if preview == null:
		return

	# Do NOT call invalidate() here — that emits changed → infinite loop.
	# The setters on EmojiTexture already clear _inner when properties change.
	if _active_texture.is_ready():
		preview.texture = _active_texture
	else:
		preview.texture = null

	var cp: String = _active_texture.emoji_codepoint
	if not cp.is_empty() and name_label:
		# Find name in registry (GDScript has no for-else, use a flag)
		var found := false
		for e: Dictionary in EmojiPackRegistry.get_emoji_list():
			if e.get("cp", "") == cp:
				name_label.text = EmojiPackRegistry.get_display_name(e)
				found = true
				break
		if not found:
			name_label.text = cp
	elif name_label:
		name_label.text = "(none selected)"

	if pack_label:
		var pack := EmojiPackRegistry.get_pack(_active_texture.pack_id)
		pack_label.text = pack.get("name", _active_texture.pack_id) if not pack.is_empty() else _active_texture.pack_id

func _on_pick_pressed() -> void:
	if not is_instance_valid(_active_texture):
		return

	if _picker == null or not is_instance_valid(_picker):
		_picker = EmojiPickerDialog.new()
		EditorInterface.get_base_control().add_child(_picker)

	# Reconnect signal fresh to avoid duplicate connections
	if _picker.emoji_selected.is_connected(_on_emoji_selected):
		_picker.emoji_selected.disconnect(_on_emoji_selected)
	_picker.emoji_selected.connect(_on_emoji_selected)

	_picker.popup_centered()

func _on_emoji_selected(codepoint: String, pack_id: String) -> void:
	if not is_instance_valid(_active_texture):
		return

	# Use undo/redo so the change is undoable and the editor marks the scene dirty
	var undo_redo := EditorInterface.get_editor_undo_redo()
	var old_cp := _active_texture.emoji_codepoint
	var old_pack := _active_texture.pack_id
	undo_redo.create_action("Pick Emoji")
	undo_redo.add_do_property(_active_texture, "emoji_codepoint", codepoint)
	undo_redo.add_do_property(_active_texture, "pack_id", pack_id)
	undo_redo.add_undo_property(_active_texture, "emoji_codepoint", old_cp)
	undo_redo.add_undo_property(_active_texture, "pack_id", old_pack)
	undo_redo.commit_action()

# ── Cleanup ───────────────────────────────────────────────────────────────────

func cleanup() -> void:
	if is_instance_valid(_active_texture):
		if _active_texture.changed.is_connected(_on_resource_changed):
			_active_texture.changed.disconnect(_on_resource_changed)
	if _picker != null and is_instance_valid(_picker):
		_picker.queue_free()
	_picker = null
	_active_texture = null
	_preview_container = null
	_active_texture = null
