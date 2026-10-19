class_name MeshKit
extends RefCounted
## Мелкие строительные примитивы для процедурных деревянных/каменных
## объектов (пирс, камни, коряги). Всё складывается в один SurfaceTool —
## один меш, один вызов отрисовки. Цвет — вершинный (материал включает
## vertex_color_use_as_albedo), поэтому доски и камни живут в одной сетке.
##
## Winding — как у ландшафта: Godot считает лицевой грань, у которой
## cross(e1, e2) смотрит ОТ наружной нормали (см. комментарий в coast.gd).


static func begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


static func finish(st: SurfaceTool) -> ArrayMesh:
	return st.commit()


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		n: Vector3, col: Color) -> void:
	st.set_color(col)
	st.set_normal(n)
	st.add_vertex(a)
	st.set_color(col)
	st.set_normal(n)
	st.add_vertex(b)
	st.set_color(col)
	st.set_normal(n)
	st.add_vertex(c)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		n: Vector3, col: Color) -> void:
	_tri(st, a, b, c, n, col)
	_tri(st, a, c, d, n, col)


## Коробка с произвольным базисом (планка, перила, ящик).
static func add_box(st: SurfaceTool, center: Vector3, dims: Vector3,
		bx: Basis, col: Color) -> void:
	var h := dims * 0.5
	var p: Array[Vector3] = []
	for i in range(8):
		var s := Vector3(
			h.x if (i & 1) != 0 else -h.x,
			h.y if (i & 2) != 0 else -h.y,
			h.z if (i & 4) != 0 else -h.z
		)
		p.append(center + bx * s)
	# грани: порядок вершин проверен по правилу cross(e1,e2) = −n
	_quad(st, p[1], p[5], p[7], p[3], bx * Vector3.RIGHT, col) # +X
	_quad(st, p[0], p[2], p[6], p[4], bx * Vector3.LEFT, col) # −X
	_quad(st, p[2], p[3], p[7], p[6], bx * Vector3.UP, col) # +Y
	_quad(st, p[0], p[4], p[5], p[1], bx * Vector3.DOWN, col) # −Y
	_quad(st, p[4], p[6], p[7], p[5], bx * Vector3.BACK, col) # +Z
	_quad(st, p[0], p[1], p[3], p[2], bx * Vector3.FORWARD, col) # −Z


## Цилиндр вдоль оси Y с сужением и (опционально) торцами.
static func add_cylinder(st: SurfaceTool, center: Vector3, r_bottom: float,
		r_top: float, height: float, segs: int, col: Color,
		cap_top := true, cap_bottom := true, bx := Basis.IDENTITY) -> void:
	var hh := height * 0.5
	var col_top := col
	for i in range(segs):
		var a0 := TAU * float(i) / float(segs)
		var a1 := TAU * float(i + 1) / float(segs)
		var c0 := Vector3(cos(a0), 0.0, sin(a0))
		var c1 := Vector3(cos(a1), 0.0, sin(a1))
		var b0 := center + bx * (c0 * r_bottom + Vector3(0.0, -hh, 0.0))
		var b1 := center + bx * (c1 * r_bottom + Vector3(0.0, -hh, 0.0))
		var t0 := center + bx * (c0 * r_top + Vector3(0.0, hh, 0.0))
		var t1 := center + bx * (c1 * r_top + Vector3(0.0, hh, 0.0))
		var n0 := (bx * Vector3(c0.x, 0.0, c0.z)).normalized()
		var n1 := (bx * Vector3(c1.x, 0.0, c1.z)).normalized()
		st.set_color(col)
		st.set_normal(n0)
		st.add_vertex(b0)
		st.set_color(col)
		st.set_normal(n1)
		st.add_vertex(b1)
		st.set_color(col_top)
		st.set_normal(n1)
		st.add_vertex(t1)
		st.set_color(col)
		st.set_normal(n0)
		st.add_vertex(b0)
		st.set_color(col_top)
		st.set_normal(n1)
		st.add_vertex(t1)
		st.set_color(col_top)
		st.set_normal(n0)
		st.add_vertex(t0)
		if cap_top:
			_tri(st, center + bx * Vector3(0.0, hh, 0.0), t0, t1,
				bx * Vector3.UP, col_top)
		if cap_bottom:
			_tri(st, center + bx * Vector3(0.0, -hh, 0.0), b1, b0,
				bx * Vector3.DOWN, col)


## Каменный столб: кольца с шумным радиусом, тёмный низ (мокрый),
## светлее к вершине. Для «морских пальцев» у берега.
static func add_rock_stack(st: SurfaceTool, base: Vector3, height: float,
		r_base: float, r_top: float, seed_value: int, col: Color,
		segs := 12, rings := 6) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.9
	noise.fractal_octaves = 2

	var grid: Array[PackedVector3Array] = []
	var norms: Array[PackedVector3Array] = []
	for k in range(rings + 1):
		var t := float(k) / float(rings)
		var y := base.y + height * t
		var r := lerpf(r_base, r_top, t)
		var ring := PackedVector3Array()
		var nring := PackedVector3Array()
		for i in range(segs):
			var a := TAU * float(i) / float(segs)
			var wob := 1.0 + 0.30 * noise.get_noise_2d(cos(a) * 3.0 + float(k) * 0.7,
				sin(a) * 3.0 + float(seed_value % 17))
			wob *= 1.0 + 0.10 * sin(a * 3.0 + float(seed_value))
			var rr := maxf(r, 0.05) * wob
			ring.append(Vector3(base.x + cos(a) * rr, y, base.z + sin(a) * rr))
			nring.append(Vector3(cos(a), 0.45, sin(a)).normalized())
		grid.append(ring)
		norms.append(nring)

	for k in range(rings):
		var t := float(k) / float(rings)
		# у воды камень мокрый и тёмный, к вершине сохнет
		var c := col * lerpf(0.55, 1.0, smoothf01(t))
		var ring0 := grid[k]
		var ring1 := grid[k + 1]
		var n0 := norms[k]
		var n1 := norms[k + 1]
		for i in range(segs):
			var j := (i + 1) % segs
			var a := ring0[i]
			var b := ring0[j]
			var cc := ring1[j]
			var d := ring1[i]
			# две треугольные грани, нормали — от колец
			_tri(st, a, b, cc, (n0[i] + n0[j] + n1[j]).normalized(), c)
			_tri(st, a, cc, d, (n0[i] + n1[j] + n1[i]).normalized(), c)

	# плоская «макушка»
	var top_ring := grid[rings]
	var top_n := norms[rings]
	var apex := Vector3(base.x, base.y + height * 1.02, base.z)
	for i in range(segs):
		var j := (i + 1) % segs
		_tri(st, apex, top_ring[i], top_ring[j],
			(top_n[i] + top_n[j] + Vector3.UP).normalized(), col)


## Коряга/бревно: сужающийся цилиндр между двумя точками.
static func add_log(st: SurfaceTool, a: Vector3, b: Vector3,
		r_a: float, r_b: float, col: Color, segs := 8) -> void:
	var y := (b - a)
	var seg_len := y.length()
	if seg_len < 0.01:
		return
	y = y / seg_len
	var x := y.cross(Vector3.UP)
	if x.length_squared() < 0.0001:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y).normalized()
	var bs := Basis(x, y, z)
	add_cylinder(st, (a + b) * 0.5, r_a, r_b, seg_len, segs, col, true, true, bs)


static func smoothf01(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)
