class_name CatchCard
extends CanvasLayer
## Карточка улова в углу кадра: вид, редкость, размер и вес. Появляется
## только на несколько секунд после поимки и гаснет — это не HUD с полосками,
## а «открытка» события. Показывает и «новый вид», если он первый.

const HOLD_TIME := 5.0
const FADE_TIME := 0.9

var _panel: PanelContainer
var _rarity: Label
var _name: Label
var _stats: Label
var _desc: Label
var _tag: Label
var _style: StyleBoxFlat
var _timer := 0.0


func setup() -> void:
	layer = 12
	_panel = PanelContainer.new()
	_panel.anchor_left = 0.0
	_panel.anchor_top = 1.0
	_panel.anchor_right = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 28.0
	_panel.offset_top = -300.0
	_panel.offset_right = 452.0
	_panel.offset_bottom = -132.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style = StyleBoxFlat.new()
	_style.bg_color = Color(0.06, 0.05, 0.05, 0.72)
	_style.border_width_left = 3
	_style.corner_radius_top_left = 6
	_style.corner_radius_top_right = 6
	_style.corner_radius_bottom_left = 6
	_style.corner_radius_bottom_right = 6
	_style.content_margin_left = 16.0
	_style.content_margin_right = 16.0
	_style.content_margin_top = 12.0
	_style.content_margin_bottom = 12.0
	_panel.add_theme_stylebox_override("panel", _style)
	add_child(_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(box)

	_rarity = _label(12)
	box.add_child(_rarity)
	_name = _label(24)
	_name.add_theme_color_override("font_color", Color(0.99, 0.95, 0.88))
	box.add_child(_name)
	_stats = _label(15)
	_stats.add_theme_color_override("font_color", Color(0.93, 0.87, 0.76))
	box.add_child(_stats)
	_tag = _label(12)
	_tag.add_theme_color_override("font_color", Color(1.0, 0.82, 0.45))
	box.add_child(_tag)
	_desc = _label(12)
	_desc.add_theme_color_override("font_color", Color(0.78, 0.72, 0.64))
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_desc)

	_panel.visible = false


func _label(fs: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", fs)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func show_fish(info: Dictionary, is_new: bool) -> void:
	if info.is_empty():
		return
	var col: Color = info.get("rarity_color", Color(0.8, 0.8, 0.8))
	_style.border_color = col
	_rarity.text = ("★".repeat(int(info.get("stars", 1)))
		+ "  " + str(info.get("rarity_label", ""))).to_upper()
	_rarity.add_theme_color_override("font_color", col)
	_name.text = str(info.get("name", "Рыба"))
	var size_cm: float = info.get("size_cm", 0.0)
	var weight_kg: float = info.get("weight_kg", 0.0)
	_stats.text = "%d см · %.2f кг · %d очков" % [int(size_cm), weight_kg, int(info.get("value", 0))]
	_tag.text = "НОВЫЙ ВИД" if is_new else ""
	_tag.visible = is_new
	_desc.text = str(info.get("desc", ""))
	_timer = HOLD_TIME
	_panel.modulate.a = 1.0
	_panel.visible = true


func _process(delta: float) -> void:
	if not _panel.visible:
		return
	_timer -= delta
	if _timer <= 0.0:
		_panel.modulate.a = maxf(0.0, _panel.modulate.a - delta / FADE_TIME)
		if _panel.modulate.a <= 0.0:
			_panel.visible = false
