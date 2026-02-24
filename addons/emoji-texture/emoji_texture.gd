## EmojiTexture
## A Texture2D resource that renders a single emoji from a chosen SVG pack.
## Set emoji_codepoint (hex string, e.g. "1f600") and pack_id ("noto", "twemoji", …)
## and the texture resolves the corresponding SVG at runtime via EmojiPackRegistry.
@tool
class_name EmojiTexture
extends Texture2D

# ── Exported properties ───────────────────────────────────────────────────────

## Hex codepoint string for the emoji, e.g. "1f600" or "1f1e6_1f1fa".
@export var emoji_codepoint: String = "" :
	set(v):
		if emoji_codepoint == v:
			return
		emoji_codepoint = v
		_inner = null
		emit_changed()

## Pack to source the SVG from ("noto", "twemoji", "openmoji", …).
@export var pack_id: String = "" :
	set(v):
		if pack_id == v:
			return
		pack_id = v
		_inner = null
		emit_changed()

# ── Internal state ────────────────────────────────────────────────────────────

## Lazily resolved inner SVG texture. Cleared whenever either property changes.
var _inner: Texture2D = null

# ── Public helpers ────────────────────────────────────────────────────────────

## Returns true when both properties are set and the SVG file can be loaded.
func is_ready() -> bool:
	return _get_inner() != null

# ── Texture2D virtual overrides ───────────────────────────────────────────────

func _get_width() -> int:
	var t := _get_inner()
	return t.get_width() if t != null else 1

func _get_height() -> int:
	var t := _get_inner()
	return t.get_height() if t != null else 1

func _draw(to_canvas_item: RID, pos: Vector2, modulate: Color, transpose: bool) -> void:
	var t := _get_inner()
	if t != null:
		t.draw(to_canvas_item, pos, modulate, transpose)

func _draw_rect(to_canvas_item: RID, rect: Rect2, tile: bool, modulate: Color, transpose: bool) -> void:
	var t := _get_inner()
	if t != null:
		t.draw_rect(to_canvas_item, rect, tile, modulate, transpose)

func _draw_rect_region(to_canvas_item: RID, rect: Rect2, src_rect: Rect2, modulate: Color, transpose: bool, clip_uv: bool) -> void:
	var t := _get_inner()
	if t != null:
		t.draw_rect_region(to_canvas_item, rect, src_rect, modulate, transpose, clip_uv)

# ── Internal ──────────────────────────────────────────────────────────────────

func _get_inner() -> Texture2D:
	if _inner != null:
		return _inner
	if emoji_codepoint.is_empty() or pack_id.is_empty():
		return null
	var svg_path := EmojiPackRegistry.get_svg_path(pack_id, emoji_codepoint)
	if svg_path.is_empty() or not ResourceLoader.exists(svg_path):
		return null
	var tex = ResourceLoader.load(svg_path, "Texture2D", ResourceLoader.CACHE_MODE_REUSE)
	if tex is Texture2D:
		_inner = tex
	return _inner
