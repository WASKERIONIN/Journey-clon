class_name SoundScape
extends Node
## Звуковой мир берега: шаги по песку, брод по воде, ветер, катушка,
## всплески, поклёвка и тихая музыка. Всё синтезируется кодом
## в AudioStreamWAV при запуске — бинарных ассетов в проекте нет.
##
## Реактивность: шаги — из Player в момент постановки стопы; вода —
## из wet01; ветер — из силы ветра и высоты; сияние — из разгона.
## События рыбалки приходят сигналами RodCast (см. main.gd).

const RATE_SFX := 22050
const RATE_MUSIC := 5512

const PAD_BASE := [146.83, 220.0, 293.66, 329.63] # D3 A3 D4 E4 — открытая кварта
const PAD_BASE_AMP := [1.0, 0.75, 0.5, 0.42]
const PAD_SHIMMER := [220.0, 293.66, 329.63]
const PAD_SHIMMER_AMP := [0.85, 0.6, 0.5]

var game: GameState
var player: Player

var _step_streams: Array[AudioStreamWAV] = []
var _water_step_streams: Array[AudioStreamWAV] = []
var _step_players: Array[AudioStreamPlayer3D] = []
var _step_rr := 0
var _wade_loop: AudioStreamPlayer3D
var _land: AudioStreamPlayer3D
var _wind: AudioStreamPlayer
var _pad: AudioStreamPlayer
var _shimmer: AudioStreamPlayer
var _wind_filter: AudioEffectLowPassFilter
var _wade_gain := 0.0
var _wind_gain := 0.0
var _shimmer_gain := 0.0
var _pad_fade := 0.0

var _cast_sfx: AudioStreamPlayer
var _splash_sfx: AudioStreamPlayer
var _plop_sfx: AudioStreamPlayer
var _bite_sfx: AudioStreamPlayer
var _reel_sfx: AudioStreamPlayer
var _catch_sfx: AudioStreamPlayer
var _sand_sfx: AudioStreamPlayer


func setup(game_ref, player_ref: Player) -> void:
	game = game_ref
	player = player_ref
	_make_buses()
	_make_sounds()


func _make_buses() -> void:
	_ensure_bus("Sand")
	_ensure_bus("Wind")
	_ensure_bus("Music")

	_wind_filter = AudioEffectLowPassFilter.new()
	_wind_filter.cutoff_hz = 1800.0
	AudioServer.add_bus_effect(AudioServer.get_bus_index("Wind"), _wind_filter, 0)

	var music_lp := AudioEffectLowPassFilter.new()
	music_lp.cutoff_hz = 2600.0
	AudioServer.add_bus_effect(AudioServer.get_bus_index("Music"), music_lp, 0)
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.62
	reverb.damping = 0.45
	reverb.wet = 0.14
	reverb.dry = 0.9
	AudioServer.add_bus_effect(AudioServer.get_bus_index("Music"), reverb, 1)


func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) < 0:
		AudioServer.add_bus()
		var idx := AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")


func _make_sounds() -> void:
	# шаги: вариации мягкого «пшш» по песку
	for k in range(6):
		_step_streams.append(_gen_footstep(917 + k * 131))
	for k in range(4):
		_water_step_streams.append(_gen_water_step(331 + k * 97))
	for k in range(4):
		var p := AudioStreamPlayer3D.new()
		p.bus = "Sand"
		p.unit_size = 5.0
		p.position = Vector3(0.0, 0.1, 0.0)
		player.add_child(p)
		_step_players.append(p)

	# брод: вода переливается у ног
	_wade_loop = AudioStreamPlayer3D.new()
	_wade_loop.bus = "Sand"
	_wade_loop.stream = _gen_water_loop()
	_wade_loop.unit_size = 6.0
	_wade_loop.position = Vector3(0.0, 0.05, 0.0)
	player.add_child(_wade_loop)
	_wade_loop.volume_db = linear_to_db(0.0001)
	_wade_loop.play()

	# глухой удар посадки
	_land = AudioStreamPlayer3D.new()
	_land.bus = "Sand"
	_land.stream = _gen_land()
	_land.unit_size = 8.0
	_land.position = Vector3(0.0, 0.1, 0.0)
	player.add_child(_land)

	_wind = AudioStreamPlayer.new()
	_wind.bus = "Wind"
	_wind.stream = _gen_wind()
	add_child(_wind)
	_wind.volume_db = linear_to_db(0.0001)
	_wind.play()

	_pad = AudioStreamPlayer.new()
	_pad.bus = "Music"
	_pad.stream = _gen_pad(PAD_BASE, PAD_BASE_AMP, 9.0)
	add_child(_pad)
	_pad.volume_db = linear_to_db(0.0001)
	_pad.play()

	_shimmer = AudioStreamPlayer.new()
	_shimmer.bus = "Music"
	_shimmer.stream = _gen_pad(PAD_SHIMMER, PAD_SHIMMER_AMP, 7.0)
	add_child(_shimmer)
	_shimmer.volume_db = linear_to_db(0.0001)
	_shimmer.play()

	# рыбалка: заброс, всплески, катушка, поимка
	_cast_sfx = _player(_gen_cast(), "Master")
	_splash_sfx = _player(_gen_splash(), "Sand")
	_plop_sfx = _player(_gen_plop(), "Sand")
	_bite_sfx = _player(_gen_bite(), "Sand")
	_reel_sfx = _player(_gen_reel_click(), "Master")
	_catch_sfx = _player(_gen_chime(), "Music")
	_sand_sfx = _player(_gen_sand_plop(), "Sand")


func _player(stream: AudioStreamWAV, bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = bus
	add_child(p)
	return p


func _process(delta: float) -> void:
	var hv := Vector3(player.vel.x, 0.0, player.vel.z)
	var spd := hv.length()
	var spd01 := clampf(spd / Player.SPRINT_MAX, 0.0, 1.0)

	# --- брод: переливы у ног, тем громче, чем глубже и быстрее ---
	var wade_target := 0.0
	if player.grounded and player.wet01 > 0.02:
		wade_target = (0.05 + 0.16 * player.wet01) * (0.55 + 0.45 * spd01)
	_wade_gain = _damp(_wade_gain, wade_target, 5.0, delta)
	_wade_loop.volume_db = linear_to_db(maxf(_wade_gain, 0.0001))

	# --- ветер: сильнее на высоте и в порывах ---
	var alt01 := clampf((player.global_position.y - 2.0) / 26.0, 0.0, 1.0)
	var gust := clampf(game.wind_strength - 0.9, 0.0, 0.45) / 0.45
	var wind_target := 0.14 + 0.14 * gust + 0.16 * alt01
	if not player.grounded:
		wind_target += 0.08
	_wind_gain = _damp(_wind_gain, wind_target, 3.0, delta)
	_wind.volume_db = linear_to_db(maxf(_wind_gain, 0.0001))
	_wind_filter.cutoff_hz = lerpf(650.0, 2500.0, clampf(gust + spd01 * 0.5, 0.0, 1.0))

	# --- музыка: фон тихий, сияние — на разгоне ---
	_pad_fade = minf(_pad_fade + delta / 7.0, 1.0)
	_pad.volume_db = linear_to_db(0.26 * _pad_fade + 0.0001)
	var shine := pow(clampf(game.sprint01, 0.0, 1.0), 1.2)
	_shimmer_gain = _damp(_shimmer_gain, shine * 0.12, 1.6, delta)
	_shimmer.volume_db = linear_to_db(maxf(_shimmer_gain, 0.0001))


# ---------------------------------------------------------------------------
# События (Player)
# ---------------------------------------------------------------------------

func on_step(spd01: float, hardness := 1.0) -> void:
	if _step_players.is_empty():
		return
	var p := _step_players[_step_rr]
	_step_rr = (_step_rr + 1) % _step_players.size()
	p.stream = _step_streams[randi() % _step_streams.size()]
	p.pitch_scale = (0.72 + randf() * 0.22) * (0.96 + 0.06 * hardness)
	p.volume_db = linear_to_db((0.035 + 0.11 * spd01) * hardness)
	p.play()


## Шаг в воде: отдельная «мокрая» вариация.
func on_water_step(spd01: float, impact01 := 0.0) -> void:
	if _water_step_streams.is_empty():
		return
	var p := _step_players[_step_rr]
	_step_rr = (_step_rr + 1) % _step_players.size()
	p.stream = _water_step_streams[randi() % _water_step_streams.size()]
	p.pitch_scale = 0.85 + randf() * 0.30
	p.volume_db = linear_to_db(0.06 + 0.13 * spd01 + 0.16 * impact01)
	p.play()


func on_land(impact01: float) -> void:
	_land.pitch_scale = 0.72 + randf() * 0.16
	_land.volume_db = linear_to_db(0.10 + 0.22 * impact01)
	_land.play()


# ---------------------------------------------------------------------------
# События рыбалки (RodCast → main.gd)
# ---------------------------------------------------------------------------

func on_cast(power: float) -> void:
	_cast_sfx.pitch_scale = 0.92 + 0.20 * power
	_cast_sfx.volume_db = linear_to_db(0.22 + 0.30 * power)
	_cast_sfx.play()


func on_splash(strength: float) -> void:
	_splash_sfx.pitch_scale = 0.90 + randf() * 0.22
	_splash_sfx.volume_db = linear_to_db(clampf(0.28 * strength, 0.05, 0.9))
	_splash_sfx.play()


func on_sand_plop() -> void:
	_sand_sfx.pitch_scale = 0.85 + randf() * 0.25
	_sand_sfx.volume_db = linear_to_db(0.42)
	_sand_sfx.play()


func on_bite() -> void:
	_bite_sfx.stop()
	_bite_sfx.play()
	_plop_sfx.pitch_scale = 1.25
	_plop_sfx.volume_db = linear_to_db(0.22)
	_plop_sfx.play()


func on_hooked() -> void:
	_splash_sfx.pitch_scale = 1.06
	_splash_sfx.volume_db = linear_to_db(0.75)
	_splash_sfx.play()


func on_escape() -> void:
	_splash_sfx.pitch_scale = 0.78
	_splash_sfx.volume_db = linear_to_db(0.55)
	_splash_sfx.play()


func on_catch(fish_size: float) -> void:
	_catch_sfx.pitch_scale = clampf(0.92 + fish_size * 0.22, 0.8, 1.3)
	_catch_sfx.volume_db = linear_to_db(0.40)
	_catch_sfx.play()
	_splash_sfx.pitch_scale = 0.85
	_splash_sfx.volume_db = linear_to_db(0.5)
	_splash_sfx.play()


func on_reel_tick() -> void:
	_reel_sfx.pitch_scale = 0.94 + randf() * 0.16
	_reel_sfx.volume_db = linear_to_db(0.10 + randf() * 0.05)
	_reel_sfx.play()


# ---------------------------------------------------------------------------
# Синтез
# ---------------------------------------------------------------------------

## Шаг по песку: глухой мягкий «пшш» — песок шуршит, а не трещит.
func _gen_footstep(p_seed: int) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var n := int(0.16 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp1 := 0.0
	var lp2 := 0.0
	var sway := lerpf(34.0, 58.0, rng.randf())
	var cph := rng.randf() * TAU
	for i in n:
		var t := float(i) / RATE_SFX
		var w := rng.randf_range(-1.0, 1.0)
		var cut := lerpf(0.32, 0.09, t / 0.16)
		lp1 += (w - lp1) * cut
		lp2 += (lp1 - lp2) * cut
		var env := minf(t / 0.016, 1.0) * exp(-t * 16.0)
		var soft := 1.0 + 0.08 * sin(TAU * sway * t + cph)
		s[i] = lp2 * env * soft * 0.34
	return _stream(s, RATE_SFX, false)


## Шаг в воде: ярче и «мокрее», с коротким шлепком.
func _gen_water_step(p_seed: int) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var n := int(0.22 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE_SFX
		var w := rng.randf_range(-1.0, 1.0)
		lp += (w - lp) * 0.38
		var env := minf(t / 0.004, 1.0) * exp(-t * 22.0)
		var plop := sin(TAU * (170.0 - 340.0 * t) * t) * exp(-t * 26.0) * 0.35
		s[i] = (lp * 0.8 + w * 0.15 + plop) * env
	return _stream(s, RATE_SFX, false)


## Шелест разгона: бесшовная петля розового шума с дыханием.
func _gen_water_loop() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8123
	var n := int(1.6 * RATE_SFX)
	var fade := int(0.08 * RATE_SFX)
	var m := n + fade
	var buf := PackedFloat32Array()
	buf.resize(m)
	var lp1 := 0.0
	var lp2 := 0.0
	for i in m:
		var t := float(i) / RATE_SFX
		var w := rng.randf_range(-1.0, 1.0)
		lp1 += (w - lp1) * 0.30
		lp2 += (lp1 - lp2) * 0.12
		var lfo := 0.70 + 0.30 * sin(TAU * 1.7 * t + sin(TAU * 0.7 * t) * 1.2)
		buf[i] = lp2 * lfo
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		if i < fade:
			var k := float(i) / float(fade)
			s[i] = buf[i] * k + buf[n + i] * (1.0 - k)
		else:
			s[i] = buf[i]
	return _stream(s, RATE_SFX, true)


## Ветер: низкий гул шума с медленными волнами громкости.
func _gen_wind() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7717
	var n := int(3.2 * RATE_SFX)
	var fade := int(0.10 * RATE_SFX)
	var m := n + fade
	var buf := PackedFloat32Array()
	buf.resize(m)
	var lp1 := 0.0
	var lp2 := 0.0
	var lp3 := 0.0
	for i in m:
		var w := rng.randf_range(-1.0, 1.0)
		lp1 += (w - lp1) * 0.06
		lp2 += (lp1 - lp2) * 0.10
		lp3 += (lp2 - lp3) * 0.25
		var ph := float(i) / float(n)
		var lfo := 0.72 + 0.18 * sin(TAU * 1.0 * ph) + 0.10 * sin(TAU * 3.0 * ph + 1.3)
		buf[i] = (lp2 + lp3 * 0.4) * lfo
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		if i < fade:
			var k := float(i) / float(fade)
			s[i] = buf[i] * k + buf[n + i] * (1.0 - k)
		else:
			s[i] = buf[i]
	return _stream(s, RATE_SFX, true)


## Посадка: глухой удар с низким тоном.
func _gen_land() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 313
	var n := int(0.28 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE_SFX
		var w := rng.randf_range(-1.0, 1.0)
		lp += (w - lp) * 0.12
		var env := minf(t / 0.003, 1.0) * exp(-t * 16.0)
		var thump := sin(TAU * 82.0 * t) * exp(-t * 20.0) * 0.55
		s[i] = (lp * 0.8 + thump) * env
	return _stream(s, RATE_SFX, false)


## Заброс: шумовой хлыст с уходящим вниз свистом.
func _gen_cast() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6061
	var n := int(0.42 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var t := float(i) / RATE_SFX
		var w := rng.randf_range(-1.0, 1.0)
		var cut := lerpf(0.10, 0.55, minf(t / 0.16, 1.0)) * lerpf(1.0, 0.25, t / 0.42)
		lp += (w - lp) * cut
		lp2 += (lp - lp2) * cut
		var env := minf(t / 0.02, 1.0) * pow(1.0 - t / 0.42, 1.6)
		s[i] = lp2 * env * 0.9
	return _stream(s, RATE_SFX, false)


## Всплеск поплавка: шлепок + низкий «буль».
func _gen_splash() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var n := int(0.50 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE_SFX
		var w := rng.randf_range(-1.0, 1.0)
		lp += (w - lp) * lerpf(0.45, 0.06, t / 0.5)
		var env := minf(t / 0.004, 1.0) * exp(-t * 13.0)
		var bloop := sin(TAU * (240.0 - 210.0 * t) * t) * exp(-t * 9.0) * 0.5
		s[i] = (lp * 1.1 + bloop) * env
	var peak := 0.0001
	for i in n:
		peak = maxf(peak, absf(s[i]))
	for i in n:
		s[i] = s[i] / peak * 0.85
	return _stream(s, RATE_SFX, false)


## Мелкий «буль» — тычок рыбы носом.
func _gen_plop() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7109
	var n := int(0.16 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE_SFX
		var env := minf(t / 0.003, 1.0) * exp(-t * 26.0)
		var bloop := sin(TAU * (320.0 - 260.0 * t) * t) * 0.8
		var w := rng.randf_range(-1.0, 1.0) * 0.18
		s[i] = (bloop + w) * env
	return _stream(s, RATE_SFX, false)


## Поклёвка: низкий, «тяжёлый» буль — рыба тянет под воду.
func _gen_bite() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4441
	var n := int(0.34 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE_SFX
		var w := rng.randf_range(-1.0, 1.0)
		lp += (w - lp) * 0.20
		var env := minf(t / 0.006, 1.0) * exp(-t * 14.0)
		var bloop := sin(TAU * (150.0 - 120.0 * t) * t) * 0.9
		s[i] = (bloop + lp * 0.55) * env
	return _stream(s, RATE_SFX, false)


## Щелчок катушки.
func _gen_reel_click() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1777
	var n := int(0.035 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	var hp := 0.0
	var prev := 0.0
	for i in n:
		var t := float(i) / RATE_SFX
		var w := rng.randf_range(-1.0, 1.0)
		hp = w - prev
		prev = w
		var env := minf(t / 0.001, 1.0) * exp(-t * 130.0)
		s[i] = hp * env * 0.5
	return _stream(s, RATE_SFX, false)


## Поплавок шлёпнулся на песок.
func _gen_sand_plop() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8811
	var n := int(0.22 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	for i in n:
		var t := float(i) / RATE_SFX
		var w := rng.randf_range(-1.0, 1.0)
		lp += (w - lp) * 0.22
		lp2 += (lp - lp2) * 0.14
		var env := minf(t / 0.003, 1.0) * exp(-t * 30.0)
		s[i] = lp2 * env * 1.1
	return _stream(s, RATE_SFX, false)


## Поимка: тёплый аккорд-«сияние» — награда без фанфар.
func _gen_chime() -> AudioStreamWAV:
	var n := int(1.5 * RATE_SFX)
	var s := PackedFloat32Array()
	s.resize(n)
	var freqs := [329.63, 493.88, 659.25, 987.77] # E4 B4 E5 B5
	var amps := [0.9, 0.55, 0.40, 0.22]
	for i in n:
		var t := float(i) / RATE_SFX
		var v := 0.0
		for k in freqs.size():
			var f: float = freqs[k]
			var a: float = amps[k]
			var delay: float = 0.06 * float(k)
			if t < delay:
				continue
			var lt := t - delay
			var env := minf(lt / 0.02, 1.0) * exp(-lt * (2.2 + 0.5 * float(k)))
			v += sin(TAU * f * lt) * a * env
		s[i] = v * 0.35
	return _stream(s, RATE_SFX, false)


## Пад: аккорд из синусов, бесшовная петля (частоты кратны числу циклов).
func _gen_pad(freqs: Array, amps: Array, length_s: float) -> AudioStreamWAV:
	var n := int(length_s * RATE_MUSIC)
	var voices: Array = []
	for k in freqs.size():
		var cycles := maxf(1.0, roundf(float(freqs[k]) * length_s))
		var f := cycles / length_s
		voices.append([f, float(amps[k]), 1 + (k % 3), float(k) * 1.7])
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE_MUSIC
		var ph := t / length_s
		var v := 0.0
		for p in voices:
			var f: float = p[0]
			var a: float = p[1]
			var lfo_k: int = p[2]
			var off: float = p[3]
			var breath := 0.80 + 0.20 * sin(TAU * float(lfo_k) * ph + off)
			v += (sin(TAU * f * t) + 0.22 * sin(TAU * f * 2.0 * t)) * a * breath
		s[i] = v
	var peak := 0.0001
	for i in n:
		peak = maxf(peak, absf(s[i]))
	for i in n:
		s[i] = s[i] / peak * 0.85
	return _stream(s, RATE_MUSIC, true)


func _stream(s: PackedFloat32Array, rate: int, loop: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		var v := int(clampf(s[i], -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = s.size()
	wav.data = data
	return wav


func _damp(v: float, target: float, rate: float, delta: float) -> float:
	return lerpf(v, target, 1.0 - exp(-rate * delta))
