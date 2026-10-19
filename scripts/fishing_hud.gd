class_name FishingHud
extends CanvasLayer
## HUD рыбалки: подсказка «что делать сейчас», сила заброса, окно подсечки,
## натяг/прогресс вываживания и сматывание. Плюс чип зоны/времени и журнал.
##
## Рисуется одним Control-ом через _draw(): никаких сцен и тем — так HUD
## не мешает ни smoke-тесту, ни скриншотам и легко переносится.
##
## Принцип: одна главная строка «что нажать» + полоска, если сейчас есть
## что показывать. Никакой сетки из панелей.

const PANEL_W := 560.0
const PANEL_H := 96.0
const BAR_W := 330.0
const BAR_H := 7.0

const C_BG := Color(0.035, 0.035, 0.045, 0.62)
const C_INK := Color(0.97, 0.94, 0.87, 0.95)
const C_DIM := Color(0.80, 0.76, 0.68, 0.72)
const C_SAND := Color(0.99, 0.80, 0.47)
const C_GOOD := Color(0.56, 0.84, 0.52)
const C_WARN := Color(1.0, 0.62, 0.28)
const C_BAD := Color(0.95, 0.34, 0.28)

var main: MainScene
var _root: Control
var _font: Font
var _t := 0.0
var _toast := ""
var _toast_t := 0.0
var _toast_col := C_INK


func setup(main_ref: MainScene) -> void:
	main = main_ref
	layer = 10
	_font = ThemeDB.fallback_font
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.draw.connect(_on_draw)
	add_child(_root)
	main.rod.bite_missed.connect(func() -> void: _say("Поздно подсекли — рыба ушла", C_WARN))
	main.rod.fish_escaped.connect(func() -> void: _say("Рыба сошла с крючка", C_BAD))
	main.rod.line_snap.connect(func() -> void: _say("Леска лопнула — отпускай в рывок", C_BAD))
	main.rod.surge_telegraph.connect(func() -> void: _say("Рывок! Отпусти ЛКМ", C_WARN))
	main.rod.reel_tick.connect(func() -> void: pass)


func _say(text: String, col: Color) -> void:
	_toast = text
	_toast_t = 2.4
	_toast_col = col


func _process(delta: float) -> void:
	_t += delta
	if _toast_t > 0.0:
		_toast_t -= delta
	_root.queue_redraw()


func _on_draw() -> void:
	if main == null or main.rod == null:
		return
	var rod: RodCast = main.rod
	var vp := _root.get_viewport_rect().size
	var cx := vp.x * 0.5

	var hint := ""
	var hint_col := C_INK
	var bar_a := -1.0 # 0..1
	var bar_b := -1.0
	var bar_a_col := C_SAND
	var label_a := ""
	var label_b := ""
	var urgent := false

	match rod.state:
		RodCast.S.RESTING:
			if rod.stowed:
				hint = "ЛКМ — взять удилище"
			else:
				hint = "ЛКМ — замах и заброс   ·   Q — убрать удилище"
		RodCast.S.CHARGE:
			hint = "Отпусти ЛКМ — заброс"
			bar_a = rod.charge_power()
			label_a = "сила"
			bar_a_col = C_GOOD.lerp(C_SAND, bar_a)
			if bar_a > 0.86:
				bar_a_col = C_SAND
		RodCast.S.FLY:
			hint = "…"
			hint_col = C_DIM
		RodCast.S.FLOAT:
			hint = "Жди поклёвки   ·   ЛКМ / R — смотать леску"
			if rod.on_land:
				hint = "Поплавок на песке — рыбы здесь нет   ·   ЛКМ / R — смотать"
				hint_col = C_WARN
		RodCast.S.BITE:
			hint = "КЛЮЁТ — подсекай! (ЛКМ)"
			hint_col = C_SAND
			urgent = true
			bar_a = rod.bite_window01()
			label_a = "окно подсечки"
			bar_a_col = C_SAND.lerp(C_BAD, 1.0 - bar_a)
		RodCast.S.FIGHT:
			var t01 := rod.fight_tension() / 100.0
			var p01 := rod.fight_progress() / 100.0
			if rod.is_pulling():
				hint = "РЫВОК — отпусти ЛКМ!"
				hint_col = C_WARN
				urgent = true
			elif t01 > 0.72:
				hint = "Натяг высокий — ослабь"
				hint_col = C_WARN
			else:
				hint = "Держи ЛКМ — мотать   ·   отпускай в рывок"
			bar_a = t01
			label_a = "натяг"
			bar_a_col = C_GOOD.lerp(C_BAD, clampf((t01 - 0.35) / 0.55, 0.0, 1.0))
			bar_b = p01
			label_b = "рыба"
		RodCast.S.REEL_IN:
			hint = "Сматываю леску…"
			hint_col = C_DIM
			bar_a = rod.reel_progress()
			label_a = "смотано"
			bar_a_col = C_DIM

	if rod.state == RodCast.S.FLOAT or rod.state == RodCast.S.BITE:
		hint = hint + "   ·   " + FishCatalog.zone_label(rod.zone)

	# ---- нижняя панель ----
	var alpha := 1.0
	if rod.state == RodCast.S.RESTING and not rod.stowed:
		alpha = 0.72
	if _toast_t > 0.0:
		alpha = 1.0
	var px := cx - PANEL_W * 0.5
	var py := vp.y - 26.0 - PANEL_H
	_round_rect(Rect2(px, py, PANEL_W, PANEL_H), C_BG, 12.0)

	var cy := py + 10.0
	# главная строка
	var fs := 20
	var col := hint_col
	col.a *= alpha
	_root.draw_string(_font, Vector2(px, cy + 20.0), hint,
		HORIZONTAL_ALIGNMENT_CENTER, PANEL_W, fs, col)
	cy += 30.0

	bar_a_col.a *= alpha
	if bar_a >= 0.0:
		_draw_bar(px + 22.0, cy, BAR_W, BAR_H, bar_a, bar_a_col, alpha,
			rod.state == RodCast.S.FIGHT)
		_root.draw_string(_font, Vector2(px + 22.0 + BAR_W + 10.0, cy + BAR_H + 1.0),
			label_a, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, C_DIM)
		cy += 13.0
	if bar_b >= 0.0:
		_draw_bar(px + 22.0, cy, BAR_W, BAR_H - 1.0, bar_b, C_SAND, alpha)
		_root.draw_string(_font, Vector2(px + 22.0 + BAR_W + 10.0, cy + BAR_H + 0.5),
			label_b, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, C_DIM)
		cy += 13.0

	# подсказка-статус, если панель пустая
	if bar_a < 0.0 and bar_b < 0.0:
		_root.draw_string(_font, Vector2(px, cy + 14.0), "рыбалка на песке: заброс → поклёвка → подсечка → вываживание",
			HORIZONTAL_ALIGNMENT_CENTER, PANEL_W, 12, C_DIM)

	# ---- чип зоны/времени/journal в правом верхнем углу ----
	_draw_chip(vp, alpha)

	# ---- тост события ----
	if _toast_t > 0.0:
		var ta := clampf(_toast_t / 0.5, 0.0, 1.0)
		var tw := PANEL_W
		var tcol := _toast_col
		tcol.a = ta
		_round_rect(Rect2(cx - tw * 0.5, py - 44.0, tw, 32.0),
			Color(0.03, 0.03, 0.04, 0.55 * ta), 10.0)
		_root.draw_string(_font, Vector2(cx - tw * 0.5, py - 44.0 + 21.0), _toast,
			HORIZONTAL_ALIGNMENT_CENTER, tw, 17, tcol)


func _draw_bar(x: float, y: float, w: float, h: float, v: float, col: Color,
		alpha: float, red_zone := false) -> void:
	var track := Color(1.0, 1.0, 1.0, 0.10 * alpha)
	_round_rect(Rect2(x, y, w, h), track, h * 0.5)
	var fill := clampf(v, 0.0, 1.0)
	if fill > 0.002:
		var c := col
		c.a *= alpha
		_round_rect(Rect2(x, y, maxf(w * fill, h), h), c, h * 0.5)
	# красная зона натяга: после 72 % — леска на грани
	if red_zone:
		var rx := x + w * 0.72
		_root.draw_line(Vector2(rx, y - 2.0), Vector2(rx, y + h + 2.0),
			Color(0.95, 0.34, 0.28, 0.45 * alpha), 1.0)


func _draw_chip(vp: Vector2, alpha: float) -> void:
	var seg := "день"
	if main.game != null:
		match FishCatalog.time_segment(main.game.night01):
			"day":
				seg = "день"
			"dusk":
				seg = "закат"
			"night":
				seg = "ночь"
	var known := 0
	if main.seen_species != null:
		known = main.seen_species.size()
	var text := "журнал %d/%d   ·   %s" % [known, FishCatalog.SPECIES.size(), seg]
	var w := 250.0
	var x := vp.x - w - 22.0
	var y := 20.0
	_round_rect(Rect2(x, y, w, 26.0), Color(0.03, 0.03, 0.04, 0.42 * alpha), 9.0)
	var c := C_DIM
	c.a *= alpha
	_root.draw_string(_font, Vector2(x, y + 18.0), text, HORIZONTAL_ALIGNMENT_CENTER, w, 13, c)


func _round_rect(r: Rect2, col: Color, radius: float) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.corner_radius_top_left = int(radius)
	sb.corner_radius_top_right = int(radius)
	sb.corner_radius_bottom_left = int(radius)
	sb.corner_radius_bottom_right = int(radius)
	sb.anti_aliasing = true
	_root.draw_style_box(sb, r)
