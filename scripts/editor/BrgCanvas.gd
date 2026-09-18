class_name BrgCanvas
extends Control
## 弹幕编辑器画布：780×960 设计战场的可视化层 + 图形化直接操控。
##
## 职责分工：
##   · `BulletManager`（放在同级 `SubViewport` 里）负责画**真实子弹** —— 复用游戏渲染
##   · 本控件负责画**编辑器叠层**：网格、发射器手柄、方向箭头、范围扇形、半径圆、
##     选中高亮、框选矩形，并处理拖拽
##
## 单位：画布坐标 == 设计坐标（`Playfield.SCALE = 1`），所以鼠标位置就是 `.brg` 坐标，
## 不需要任何换算。
##
## ================================================================== 手柄（P1）
##
## 选中的发射器会显示 4 类可拖拽手柄，**拖哪个就改哪个属性**：
##   · 本体圆      → `Position`（跟随宿主）或 `EmitPoint`（绝对）
##   · 箭头端点    → `EmitDirection`（发射角度）
##   · 扇形两条边  → `Range`（范围，以发射角度为中心对称张开）
##   · 半径圆上的点 → `EmitRadius`（距离）+ `RadiusDirection`（方向）
##
## 「指向自机」哨兵（`-99999`）的发射器**不显示箭头手柄**——那个角度是运行时动态算的，
## 不该被静态拖拽覆盖。但范围手柄照常可用（Range 只是一个对称张角）。

signal emitter_clicked(index: int, additive: bool)
signal empty_clicked()
signal box_selected(indices: Array)
signal drag_started()                       ## 拖拽开始（编辑器借此压一次撤销栈）
signal drag_finished()                      ## 拖拽结束（编辑器借此做一次精确重放）
signal emitter_changed(index: int)          ## 拖拽中改了属性（编辑器借此同步属性面板数值）
signal bullet_pick_requested(pos: Vector2, additive: bool)   ## 单弹拾取模式下的点击

const FIELD_W := 780.0
const FIELD_H := 960.0

## 手柄尺寸
const HANDLE_R := 7.0
const HIT_R := 14.0
const HANDLE_HIT := 10.0
const ARROW_LEN := 56.0
const RANGE_FAN_LEN := ARROW_LEN * 1.6

## 手柄类型
const H_BODY := 0
const H_DIR := 1
const H_RANGE_LO := 2
const H_RANGE_HI := 3
const H_RADIUS := 4
const H_WAY := 5

## 未设置范围/半径时给手柄的「幽灵」初值，便于直接拖出来
const GHOST_RANGE_HALF := 15.0
const GHOST_RADIUS := 26.0

## Way（条数）手柄：放在基准方向 +90° 的垂直侧，离中心的距离随条数增大。
## 这样它不会与方向手柄（基准方向）或半径手柄（半径方向）重叠。
## `Way = 1 + round((dist - BASE) / STEP)`，与手柄位置自洽。
const WAY_R_BASE := 34.0
const WAY_R_STEP := 8.0
const WAY_MIN := 1
const WAY_MAX := 512

## 网格吸附步长（与画布网格线 60 对齐；可在工具栏开关）
const GRID_SNAP_STEP := 60.0

## 单弹拾取模式的命中半径（画布像素）
const PICK_RADIUS := 18.0

## 可操纵自机小球。
## 判定半径**直接取游戏真值** `Sanctity.HIT_R_SANCTITY`(2.0) / `HIT_R_CORRUPTION`(3.0)，
## 与实机判定点一致，避免编辑时按错误大小估缝隙。
## `PLAYER_HIT` 只是鼠标抓取半径（非判定），方便点中这颗很小的球。
const PLAYER_HIT := 16.0

enum DragMode { NONE, MOVE, DIRECTION, RANGE, RADIUS, WAY }

var doc: BrgDocument = null
var selected: Array = []          # Array[int] 发射器序号
var show_grid := true
var show_gizmos := true
var show_labels := true
## 单弹拾取（P2 语义 B）：开启后左键点画布 = 压制最近的那颗子弹，而不是选发射器
var pick_bullet_mode := false
var bullets: Node = null          ## BulletManager（拾取单弹用）
var playback = null               ## BrgPlayback（读压制数用于提示）
## 自机：PlayHost 持有 player_pos，播放层发射自机狙时读取它。
var play_host = null
var show_player := true
var _dragging_player := false
var _hover_slot := -1
var snap := false                 ## 按住 Shift 时角度吸附 15°
var snap_grid := false            ## 移动发射器时吸附到 GRID_SNAP_STEP 网格
var _hover := -1
var _hover_handle := -1
var _drag_index := -1
var _drag_mode: int = DragMode.NONE
var _drag_offset := Vector2.ZERO
var _drag_handle := -1
## 范围拖拽用**相对**方式：记录按下瞬间的范围与角差，之后只施加增量。
## 这样满环（Range=360）时手柄重合也不会一跳到底。
var _range_start := 0.0
var _range_delta_start := 0.0
var _boxing := false
var _box_from := Vector2.ZERO
var _box_to := Vector2.ZERO

## 发射器在画布上的位置。
## EmitPoint = 自身哨兵时跟随宿主（编辑器用 host_origin 表示），否则用 EmitPoint 绝对坐标。
var host_origin := Vector2(FIELD_W * 0.5, 240.0)

# 调色板
const C_BG := Color(0.055, 0.05, 0.09)
const C_GRID := Color(1, 1, 1, 0.055)
const C_GRID_MAJOR := Color(1, 1, 1, 0.11)
const C_BORDER := Color(0.55, 0.45, 0.75, 0.85)
const C_EMIT := Color(0.95, 0.78, 0.35)
const C_EMIT_DISABLED := Color(0.5, 0.5, 0.55)
const C_SEL := Color(0.4, 1.0, 0.6)
const C_HOVER := Color(1, 1, 1, 0.7)
const C_RANGE := Color(0.45, 0.75, 1.0, 0.16)
const C_RANGE_EDGE := Color(0.5, 0.8, 1.0, 0.55)
const C_AIM := Color(1.0, 0.35, 0.45)
const C_HANDLE := Color(0.75, 1.0, 0.85)
const C_HANDLE_HOT := Color(1.0, 1.0, 0.5)

func _ready() -> void:
	custom_minimum_size = Vector2(FIELD_W, FIELD_H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL

func set_document(p_doc: BrgDocument) -> void:
	doc = p_doc
	selected.clear()
	queue_redraw()

func set_selected(p_indices: Array) -> void:
	selected = p_indices.duplicate()
	queue_redraw()

# ------------------------------------------------------------------ 绘制

func _draw() -> void:
	# 注意：**不要在这里填充不透明底色**。本控件 z_index=20，在子弹（z_index=10）之上，
	# 一旦填充就会把真实预览整块盖住。场地底色由 BrgEditor 在 field_root 下放一个
	# z_index=-10 的 ColorRect 提供，这里只画网格 / 手柄 / 标签等叠层。
	if show_grid:
		_draw_grid()
	draw_rect(Rect2(0, 0, FIELD_W, FIELD_H), C_BORDER, false, 2.0)
	if doc != null and show_gizmos:
		_draw_emitters()
	if show_player:
		_draw_player()
	if _boxing:
		var r := Rect2(_box_from, _box_to - _box_from).abs()
		draw_rect(r, Color(0.4, 1.0, 0.6, 0.12))
		draw_rect(r, C_SEL, false, 1.0)
	if pick_bullet_mode:
		_draw_pick_overlay()

## 可操纵自机小球：位置由 PlayHost 持有（播放层发射「自机狙」时读取）。
## 拖动小球或按方向键/WASD 移动，新发射的自机狙会实时朝它。
func _player_pos() -> Vector2:
	if play_host != null:
		return play_host.player_pos
	return Vector2(FIELD_W * 0.5, FIELD_H * 0.833)

func _apply_player(target: Vector2) -> void:
	var m := Sanctity.HIT_R_CORRUPTION          # 让整个判定圈留在场地内
	var p := Vector2(
		clampf(target.x, m, FIELD_W - m),
		clampf(target.y, m, FIELD_H - m))
	if play_host != null:
		play_host.player_pos = p
	queue_redraw()

## 供外部（键盘移动 / 测试）设置自机位置
func set_player_pos(p: Vector2) -> void:
	_apply_player(p)

func _draw_player() -> void:
	var p := _player_pos()
	var holy_r := Sanctity.HIT_R_SANCTITY        # 2.0
	var corr_r := Sanctity.HIT_R_CORRUPTION      # 3.0
	# 拖动/悬停时给个抓取提示圈（非判定，仅方便点中）
	if _dragging_player:
		draw_arc(p, PLAYER_HIT, 0.0, TAU, 32, Color(0.5, 0.95, 1.0, 0.7), 1.0)
	# 判定点：外圈 = 污染态（最大），内芯 = 圣洁态。黑描边保证在亮弹上也可辨。
	draw_circle(p, corr_r + 1.0, Color(0, 0, 0, 0.85))
	draw_circle(p, corr_r, Color(1.0, 0.45, 0.45, 0.95))
	draw_circle(p, holy_r + 0.8, Color(0, 0, 0, 0.85))
	draw_circle(p, holy_r, Color(0.5, 0.95, 1.0, 1.0))
	draw_circle(p, 0.8, Color(1, 1, 1))
	draw_string(ThemeDB.fallback_font, p + Vector2(11, -9),
		"自机 判定 r%.1f/%.1f" % [holy_r, corr_r],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.55, 0.9, 1.0, 0.9))

## 单弹拾取模式的叠层：高亮光标下最近的弹，并给出提示
func _draw_pick_overlay() -> void:
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(0, 0, FIELD_W, FIELD_H), Color(1.0, 0.45, 0.35, 0.05))
	draw_rect(Rect2(0, 0, FIELD_W, FIELD_H), Color(1.0, 0.45, 0.35, 0.6), false, 2.0)
	var sup := 0
	if playback != null:
		sup = (playback.suppressed as Dictionary).size()
	draw_string(font, Vector2(10, 20),
		"单弹拾取模式：点击最近的一颗弹即压制（不生成）　已压制 %d 发　Esc 退出" % sup,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.6, 0.5))
	if _hover_slot >= 0 and bullets != null:
		var info: Dictionary = bullets.slot_info(_hover_slot)
		if not info.is_empty():
			# slot_info 是世界坐标/尺寸 → ÷SCALE 转回设计空间绘制（2026-09-17）
			var p := Vector2(float(info["x"]), float(info["y"])) / Playfield.SCALE
			var rr: float = maxf(float(info.get("size", 16.0)) * 0.5 / Playfield.SCALE + 6.0, 14.0)
			draw_arc(p, rr, 0, TAU, 32, Color(1.0, 0.45, 0.35), 2.0)
			draw_line(p - Vector2(rr + 6, 0), p - Vector2(rr, 0), Color(1.0, 0.45, 0.35), 2.0)
			draw_line(p + Vector2(rr, 0), p + Vector2(rr + 6, 0), Color(1.0, 0.45, 0.35), 2.0)
			var ident: Array = bullets.identity_of(_hover_slot)
			if ident.size() == 3:
				draw_string(font, p + Vector2(rr + 8, -4),
					"发射器 %d · 第 %d 帧 · 第 %d 发" % [ident[0], ident[1], ident[2]],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.75, 0.7))

func _draw_grid() -> void:
	var step := 60
	var i := step
	while i < int(FIELD_W):
		var major: bool = (i % 240) == 0
		draw_line(Vector2(i, 0), Vector2(i, FIELD_H), C_GRID_MAJOR if major else C_GRID, 1.0)
		i += step
	i = step
	while i < int(FIELD_H):
		var major: bool = (i % 240) == 0
		draw_line(Vector2(0, i), Vector2(FIELD_W, i), C_GRID_MAJOR if major else C_GRID, 1.0)
		i += step
	draw_line(Vector2(FIELD_W * 0.5, 0), Vector2(FIELD_W * 0.5, FIELD_H),
		Color(1, 1, 1, 0.14), 1.0)

func _draw_emitters() -> void:
	var ems := doc.emitter_nodes()
	# 第一遍：画 gizmo（按序号，保证层次稳定）
	for idx in ems.size():
		_draw_emitter_gizmo(ems, idx)
	# 第二遍：标签（优先级贪心避让）
	if show_labels:
		_draw_emitter_labels(ems)
	# 第三遍：手柄 —— **必须最后画**。
	# 标签底板是不透明深色块，先画手柄的话选中的发射器自己的标签
	# 会把它的手柄盖住（看不见就拖不到），所以手柄永远压在最上层。
	for idx in selected:
		if idx >= 0 and idx < ems.size():
			_draw_handles(ems, idx)

func _draw_emitter_gizmo(ems: Array, idx: int) -> void:
	var n: BrgDocument.XNode = ems[idx]
	var pos := _emitter_canvas_pos(n)
	var is_sel: bool = selected.has(idx)
	var is_hov: bool = _hover == idx
	var disabled := doc.get_b(n, "Disabled", false)
	var col := C_EMIT_DISABLED if disabled else C_EMIT

	var way := maxi(1, doc.get_i(n, "Way", 1))
	var rng := doc.get_f(n, "Range", 0.0)
	var base := _base_dir_deg(n)
	var aim := _is_aim(n, "EmitDirection")
	if rng > 0.001:
		_draw_range_fan(pos, base, rng)

	var er := doc.get_f(n, "EmitRadius", 0.0)
	if er > 0.5:
		draw_arc(pos, er, 0, TAU, 64, Color(0.6, 0.85, 1.0, 0.35), 1.0)
		draw_line(pos, pos + _deg_vec(doc.get_f(n, "RadiusDirection", 0.0)) * er,
			Color(0.6, 0.85, 1.0, 0.25), 1.0)

	_draw_direction(pos, base, aim, way, rng, col)

	var r := HANDLE_R + (3.0 if is_sel else 0.0)
	draw_circle(pos, r + 2.0, Color(0, 0, 0, 0.55))
	draw_circle(pos, r, C_SEL if is_sel else col)
	if is_hov and not is_sel:
		draw_arc(pos, r + 5.0, 0, TAU, 32, C_HOVER, 2.0)
	if is_sel:
		draw_line(pos + Vector2(-r - 8, 0), pos + Vector2(-r - 2, 0), C_SEL, 2.0)
		draw_line(pos + Vector2(r + 2, 0), pos + Vector2(r + 8, 0), C_SEL, 2.0)
		draw_line(pos + Vector2(0, -r - 8), pos + Vector2(0, -r - 2), C_SEL, 2.0)
		draw_line(pos + Vector2(0, r + 2), pos + Vector2(0, r + 8), C_SEL, 2.0)

## 画发射器的手柄（仅选中项）
func _draw_handles(ems: Array, idx: int) -> void:
	var n: BrgDocument.XNode = ems[idx]
	var pos := _emitter_canvas_pos(n)
	for hid in [H_DIR, H_RANGE_LO, H_RANGE_HI, H_RADIUS, H_WAY]:
		if not _handle_available(n, hid):
			continue
		var hp := _handle_pos(n, pos, hid)
		var hot: bool = _hover == idx and _hover_handle == hid
		if hid == H_WAY:
			# 菱形手柄 = 改条数（离中心的距离映射为 Way）
			var d := 6.0
			var dia := PackedVector2Array([
				hp + Vector2(0, -d), hp + Vector2(d, 0), hp + Vector2(0, d), hp + Vector2(-d, 0)])
			draw_colored_polygon(dia, Color(0, 0, 0, 0.6))
			var d2 := 4.5
			draw_colored_polygon(PackedVector2Array([
				hp + Vector2(0, -d2), hp + Vector2(d2, 0), hp + Vector2(0, d2), hp + Vector2(-d2, 0)]),
				C_HANDLE_HOT if hot else C_HANDLE)
			draw_string(ThemeDB.fallback_font, hp + Vector2(d + 4, 4),
				"Way %d" % maxi(WAY_MIN, doc.get_i(n, "Way", 1)),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 1.0, 0.85, 0.9))
		elif hid == H_DIR or hid == H_RADIUS:
			# 方形手柄 = 改角度/半径
			var s := 5.0
			var rr := Rect2(hp - Vector2(s, s), Vector2(s * 2, s * 2))
			draw_rect(rr, Color(0, 0, 0, 0.6))
			draw_rect(rr.grow(-1.5), C_HANDLE_HOT if hot else C_HANDLE)
		else:
			# 圆形手柄 = 改范围
			draw_circle(hp, 5.5, Color(0, 0, 0, 0.6))
			draw_circle(hp, 4.0, C_HANDLE_HOT if hot else C_HANDLE)

## 手柄是否对该发射器可用
func _handle_available(n: BrgDocument.XNode, hid: int) -> bool:
	match hid:
		H_DIR:
			# 「指向自机」是运行时动态角度，不给静态拖拽手柄
			return not _is_aim(n, "EmitDirection")
		H_RANGE_LO, H_RANGE_HI:
			# 范围手柄对「自机狙」发射器也可用：Range 只是一个对称张角，
			# 张角的中心方向才是运行时动态的。
			return true
		H_RADIUS:
			return true
		H_WAY:
			# 条数手柄始终可用：Way=1 时也能拖大
			return true
	return false

## 范围手柄离基准方向的半张角。
## 上限 90°：满环（Range=360）时两个手柄本来会重合在正后方、无法分辨，
## 放到 ±90° 后既可见又能区分是拖哪一侧。
func _range_handle_half(n: BrgDocument.XNode) -> float:
	var rng := doc.get_f(n, "Range", 0.0)
	if rng <= 0.001:
		return GHOST_RANGE_HALF
	return clampf(rng * 0.5, GHOST_RANGE_HALF, 90.0)

## 手柄位置
func _handle_pos(n: BrgDocument.XNode, pos: Vector2, hid: int) -> Vector2:
	var base := _base_dir_deg(n)
	var half := _range_handle_half(n)
	match hid:
		H_DIR:
			return pos + _deg_vec(base) * ARROW_LEN
		H_RANGE_LO:
			return pos + _deg_vec(base - half) * RANGE_FAN_LEN
		H_RANGE_HI:
			return pos + _deg_vec(base + half) * RANGE_FAN_LEN
		H_RADIUS:
			var er := doc.get_f(n, "EmitRadius", 0.0)
			var d: float = er if er > 0.5 else GHOST_RADIUS
			var rd := doc.get_f(n, "RadiusDirection", 0.0)
			if _is_aim(n, "RadiusDirection"):
				rd = base
			return pos + _deg_vec(rd) * d
		H_WAY:
			# 垂直于基准方向，避免与方向/半径手柄重合
			return pos + _deg_vec(base + 90.0) * _way_handle_r(n)
	return pos

## Way 手柄离发射器中心的距离（随条数增大）
func _way_handle_r(n: BrgDocument.XNode) -> float:
	return WAY_R_BASE + float(maxi(WAY_MIN, doc.get_i(n, "Way", 1)) - 1) * WAY_R_STEP

## 手柄距离 → Way 条数（与 _way_handle_r 互逆）
func _way_from_dist(dist: float) -> int:
	return clampi(WAY_MIN + int(roundf((dist - WAY_R_BASE) / WAY_R_STEP)), WAY_MIN, WAY_MAX)

func _draw_range_fan(pos: Vector2, base: float, rng: float) -> void:
	var pts := PackedVector2Array([pos])
	var start := base - rng * 0.5
	var steps := 24
	for i in steps + 1:
		pts.append(pos + _deg_vec(start + rng * float(i) / float(steps)) * RANGE_FAN_LEN)
	draw_colored_polygon(pts, C_RANGE)
	draw_arc(pos, RANGE_FAN_LEN, deg_to_rad(start), deg_to_rad(start + rng),
		32, C_RANGE_EDGE, 1.0)

## 画发射方向与每条弹的方向刻度
func _draw_direction(pos: Vector2, base: float, aim: bool, way: int, rng: float, col: Color) -> void:
	var angles: Array = _spread_angles(base, way, rng)
	var dir_col := C_AIM if aim else col
	for k in angles.size():
		var a := deg_to_rad(float(angles[k]))
		var tip := pos + Vector2(cos(a), sin(a)) * ARROW_LEN
		if k == 0 or way <= 1:
			# 自机狙：虚线示意，因为这个角度运行时才算得出来
			if aim:
				var segs := 6
				for s in segs:
					var t0 := float(s) / float(segs) * ARROW_LEN
					var t1 := (float(s) + 0.55) / float(segs) * ARROW_LEN
					var d := Vector2(cos(a), sin(a))
					if t1 > ARROW_LEN:
						t1 = ARROW_LEN
					draw_line(pos + d * t0, pos + d * t1, dir_col, 2.0)
			else:
				draw_line(pos, tip, dir_col, 2.0)
			_draw_arrow_head(tip, a, dir_col)
		else:
			var dot := pos + Vector2(cos(a), sin(a)) * (ARROW_LEN * 0.55)
			draw_circle(dot, 2.5, Color(dir_col.r, dir_col.g, dir_col.b, 0.75))
	if aim:
		draw_string(ThemeDB.fallback_font, pos + Vector2(ARROW_LEN * 0.62, ARROW_LEN * 0.52),
			"自机狙", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, C_AIM)

func _draw_arrow_head(tip: Vector2, a: float, col: Color) -> void:
	var s := 7.0
	draw_line(tip, tip + Vector2(cos(a + 2.6), sin(a + 2.6)) * s, col, 2.0)
	draw_line(tip, tip + Vector2(cos(a - 2.6), sin(a - 2.6)) * s, col, 2.0)

## Way 条数在范围内的均布角度（与 BrgPlayback 的语义一致，供预览用）
func _spread_angles(base: float, way: int, rng: float) -> Array:
	var out: Array = []
	if way <= 1:
		out.append(base)
	elif rng >= 359.999:
		var step := 360.0 / float(way)
		for i in way:
			out.append(base + step * float(i))
	elif rng > 0.001:
		var step := rng / float(way - 1)
		var st := base - rng * 0.5
		for i in way:
			out.append(st + step * float(i))
	else:
		for i in way:
			out.append(base)
	return out

## 标签避让：选中 → 悬停 → 其余（序号大的先占位，因为它画在上层）。
## 密集工程对策：发射器多于 12 个时，未选中/未悬停的只显示「序号 标签」。
func _draw_emitter_labels(ems: Array) -> void:
	var font := ThemeDB.fallback_font
	var occupied: Array = []
	var compact_mode: bool = ems.size() > 12
	var order: Array = []
	for i in ems.size():
		if selected.has(i):
			order.append(i)
	if _hover >= 0 and not order.has(_hover):
		order.append(_hover)
	for i in range(ems.size() - 1, -1, -1):
		if not order.has(i):
			order.append(i)

	for idx in order:
		var n: BrgDocument.XNode = ems[idx]
		var pos := _emitter_canvas_pos(n)
		var is_sel: bool = selected.has(idx)
		var disabled := doc.get_b(n, "Disabled", false)
		var col := C_SEL if is_sel else Color(1, 1, 1, 0.88)
		var tag := doc.get_field(n, "Tag", "?")
		var title := "%d %s%s" % [idx, tag if tag != "" else "(无标签)",
			" [停用]" if disabled else ""]
		var detail := ""
		if is_sel or _hover == idx or not compact_mode:
			detail = "Way %d · 周期 %d · v%.2f · 生命 %d" % [
				maxi(1, doc.get_i(n, "Way", 1)), doc.get_i(n, "Circle", 1),
				doc.get_f(n, "BulletVelocity", 0.0), doc.get_i(n, "LifeTime", 0)]
		if _place_label(font, pos, title, detail, col, occupied, 12, is_sel):
			continue
		if not _place_label(font, pos, "#%d" % idx, "", col, occupied, 11, is_sel):
			pass

func _place_label(font: Font, anchor: Vector2, title: String, detail: String,
		col: Color, occupied: Array, size: int, is_sel: bool) -> bool:
	var tw := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var dw := 0.0
	if detail != "":
		dw = font.get_string_size(detail, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	var w: float = maxf(tw, dw) + 10.0
	var h: float = 30.0 if detail != "" else 17.0
	var pad := 13.0
	var cands: Array = [
		Vector2(pad, -h - 7.0),
		Vector2(pad, 7.0),
		Vector2(-w - pad, -h - 7.0),
		Vector2(-w - pad, 7.0),
		Vector2(-w * 0.5, -h - 22.0),
		Vector2(-w * 0.5, 22.0),
		Vector2(pad + 26.0, -h - 7.0),
		Vector2(-w - pad - 26.0, -h - 7.0),
	]
	for c in cands:
		var r := Rect2(Vector2(anchor.x + c.x, anchor.y + c.y), Vector2(w, h))
		if r.position.x < 2.0 or r.position.y < 2.0 \
				or r.end.x > FIELD_W - 2.0 or r.end.y > FIELD_H - 2.0:
			continue
		var clash := false
		for o in occupied:
			if (o as Rect2).intersects(r):
				clash = true
				break
		if clash:
			continue
		occupied.append(r)
		if r.position.distance_to(anchor) > 30.0:
			var near := Vector2(
				clampf(anchor.x, r.position.x, r.end.x),
				clampf(anchor.y, r.position.y, r.end.y))
			draw_line(anchor, near, Color(col.r, col.g, col.b, 0.3), 1.0)
		draw_rect(r, Color(0.04, 0.04, 0.07, 0.78 if is_sel else 0.62))
		if is_sel:
			draw_rect(r, Color(col.r, col.g, col.b, 0.55), false, 1.0)
		var base := r.position.y + size + 1.0
		draw_string(font, Vector2(r.position.x + 5, base), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
		if detail != "":
			draw_string(font, Vector2(r.position.x + 5, base + 13.0), detail,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.55))
		return true
	return false

# ------------------------------------------------------------------ 工具

func _is_aim(n: BrgDocument.XNode, p_tag: String) -> bool:
	return doc.angle_is_aim(n, p_tag)

## 显示/计算用的基准方向：自机狙用 90°（正下）示意
func _base_dir_deg(n: BrgDocument.XNode) -> float:
	if _is_aim(n, "EmitDirection"):
		return 90.0
	return doc.get_angle(n, "EmitDirection", 90.0)

static func _deg_vec(deg: float) -> Vector2:
	var r := deg_to_rad(deg)
	return Vector2(cos(r), sin(r))

## 归一化到 (-180, 180]
static func _wrap_deg(d: float) -> float:
	var x := fposmod(d + 180.0, 360.0) - 180.0
	if is_equal_approx(x, -180.0):
		x = 180.0
	return x

## 两个角度之间的最短有符号差（度）
static func _deg_delta(a: float, b: float) -> float:
	return _wrap_deg(a - b)

func _emitter_canvas_pos(n: BrgDocument.XNode) -> Vector2:
	var ep := doc.get_vec(n, "EmitPoint",
		Vector2(BrgDocument.SENTINEL_SELF, BrgDocument.SENTINEL_SELF))
	var self_ref: bool = _is_self_ref(n)
	var base := host_origin if self_ref else ep
	if self_ref:
		base += doc.get_vec(n, "Position", Vector2.ZERO)
	return base

func _is_self_ref(n: BrgDocument.XNode) -> bool:
	var ep := doc.get_vec(n, "EmitPoint",
		Vector2(BrgDocument.SENTINEL_SELF, BrgDocument.SENTINEL_SELF))
	return ep.x <= BrgDocument.SENTINEL_SELF + 1.0 and ep.y <= BrgDocument.SENTINEL_SELF + 1.0

# ------------------------------------------------------------------ 交互

func _gui_input(event: InputEvent) -> void:
	if doc == null:
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_handle_motion(mm)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_handle_press(mb)
			else:
				_handle_release()

func _handle_motion(mm: InputEventMouseMotion) -> void:
	var mp := mm.position
	snap = mm.shift_pressed
	# 单弹拾取模式：不做发射器拖拽/框选，只高亮光标下最近的弹
	if pick_bullet_mode:
		var s := -1
		if bullets != null:
			s = bullets.pick(mp.x * Playfield.SCALE, mp.y * Playfield.SCALE,
				PICK_RADIUS * Playfield.SCALE)
		if s != _hover_slot:
			_hover_slot = s
			queue_redraw()
		return
	if _dragging_player:
		_apply_player(mp)
		return
	if _drag_mode != DragMode.NONE and _drag_index >= 0:
		_apply_drag(mp)
		emitter_changed.emit(_drag_index)
		queue_redraw()
		return
	if _boxing:
		_box_to = mp
		queue_redraw()
		return
	# 悬停：先试手柄（只对选中项），再试本体
	var h := _hit_handle(mp)
	var new_hover := -1
	var new_handle := -1
	if h.is_empty():
		new_hover = _hit_test(mp)
	else:
		new_hover = int(h["index"])
		new_handle = int(h["handle"])
	if new_hover != _hover or new_handle != _hover_handle:
		_hover = new_hover
		_hover_handle = new_handle
		var over_player := show_player and mp.distance_to(_player_pos()) <= PLAYER_HIT
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
			if (new_hover >= 0 or new_handle >= 0 or over_player) else Control.CURSOR_ARROW
		queue_redraw()

## 开始一次拖拽：记录按下位置相关的状态（范围拖拽需要相对基准）。
## 按下时**先抓状态**再改数据，所以调用方应在此之前压撤销栈。
func begin_drag(index: int, mode: int, hid: int, press_pos: Vector2) -> void:
	_drag_index = index
	_drag_mode = mode
	_drag_handle = hid
	var ems := doc.emitter_nodes()
	if index < 0 or index >= ems.size():
		return
	var n: BrgDocument.XNode = ems[index]
	var pos := _emitter_canvas_pos(n)
	match mode:
		DragMode.MOVE:
			_drag_offset = press_pos - pos
		DragMode.RANGE:
			_range_start = doc.get_f(n, "Range", 0.0)
			var a := rad_to_deg((press_pos - pos).angle())
			_range_delta_start = _deg_delta(a, _base_dir_deg(n))
	drag_started.emit()

func _handle_press(mb: InputEventMouseButton) -> void:
	var mp := mb.position
	snap = mb.shift_pressed
	# 单弹拾取模式：只做拾取，不选发射器、不拖拽
	if pick_bullet_mode:
		bullet_pick_requested.emit(mp, mb.ctrl_pressed or mb.shift_pressed)
		return
	# 自机小球优先：拖动它来体验自机狙手感
	if show_player and mp.distance_to(_player_pos()) <= PLAYER_HIT:
		_dragging_player = true
		queue_redraw()
		return
	var h := _hit_handle(mp)
	if not h.is_empty():
		begin_drag(int(h["index"]), int(h["mode"]), int(h["handle"]), mp)
		emitter_clicked.emit(int(h["index"]), mb.ctrl_pressed or mb.shift_pressed)
		return
	var body := _hit_test(mp)
	if body >= 0:
		begin_drag(body, DragMode.MOVE, H_BODY, mp)
		emitter_clicked.emit(body, mb.ctrl_pressed or mb.shift_pressed)
		return
	_boxing = true
	_box_from = mp
	_box_to = mp
	empty_clicked.emit()

func _handle_release() -> void:
	if _dragging_player:
		_dragging_player = false
		queue_redraw()
		return
	var was_dragging: bool = _drag_mode != DragMode.NONE
	if _boxing:
		_boxing = false
		var r := Rect2(_box_from, _box_to - _box_from).abs()
		if r.size.length() > 6.0:
			var hits: Array = []
			var ems := doc.emitter_nodes()
			for i in ems.size():
				if r.has_point(_emitter_canvas_pos(ems[i])):
					hits.append(i)
			box_selected.emit(hits)
		queue_redraw()
	_drag_index = -1
	_drag_mode = DragMode.NONE
	_drag_handle = -1
	queue_redraw()
	if was_dragging:
		drag_finished.emit()

## 命中手柄（只看选中项，因为手柄只画在选中项上）
func _hit_handle(p: Vector2) -> Dictionary:
	var ems := doc.emitter_nodes()
	for idx in selected:
		if idx < 0 or idx >= ems.size():
			continue
		var n: BrgDocument.XNode = ems[idx]
		var pos := _emitter_canvas_pos(n)
		for hid in [H_DIR, H_RANGE_LO, H_RANGE_HI, H_RADIUS, H_WAY]:
			if not _handle_available(n, hid):
				continue
			if p.distance_to(_handle_pos(n, pos, hid)) <= HANDLE_HIT:
				var mode: int = DragMode.DIRECTION
				match hid:
					H_RANGE_LO, H_RANGE_HI:
						mode = DragMode.RANGE
					H_RADIUS:
						mode = DragMode.RADIUS
					H_WAY:
						mode = DragMode.WAY
				return {"index": idx, "handle": hid, "mode": mode}
	return {}

## 拖拽落点 → 写回 XML
func _apply_drag(target: Vector2) -> void:
	var ems := doc.emitter_nodes()
	if _drag_index < 0 or _drag_index >= ems.size():
		return
	var n: BrgDocument.XNode = ems[_drag_index]
	var pos := _emitter_canvas_pos(n)
	match _drag_mode:
		DragMode.MOVE:
			var np := target - _drag_offset
			if snap_grid:
				np = np.snapped(Vector2(GRID_SNAP_STEP, GRID_SNAP_STEP))
			_apply_move(n, np)
		DragMode.WAY:
			doc.set_field(n, "Way", _way_from_dist(target.distance_to(pos)))
		DragMode.DIRECTION:
			var ang := rad_to_deg((target - pos).angle())
			if snap:
				ang = roundf(ang / 15.0) * 15.0
			doc.set_angle(n, "EmitDirection", _wrap_deg(ang))
		DragMode.RANGE:
			# 相对拖拽：只施加「按下 → 现在」的角差增量，满环时也不会跳变
			var a2 := rad_to_deg((target - pos).angle())
			var dnow := _deg_delta(a2, _base_dir_deg(n))
			var diff := dnow - _range_delta_start
			var nr: float = _range_start + (2.0 * diff if _drag_handle == H_RANGE_HI else -2.0 * diff)
			doc.set_field(n, "Range", clampf(nr, 0.0, 360.0))
		DragMode.RADIUS:
			doc.set_field(n, "EmitRadius", maxf(0.0, target.distance_to(pos)))
			# 半径方向也跟随拖动方向（自机狙哨兵不覆盖）
			if not _is_aim(n, "RadiusDirection"):
				var ang3 := rad_to_deg((target - pos).angle())
				if target.distance_to(pos) > 1.0:
					doc.set_angle(n, "RadiusDirection", _wrap_deg(ang3))

## 移动：跟随宿主的发射器改 `Position`（相对偏移）；绝对发射点改 `EmitPoint`
func _apply_move(n: BrgDocument.XNode, target: Vector2) -> void:
	if _is_self_ref(n):
		doc.set_vec(n, "Position", (target - host_origin).round())
	else:
		doc.set_vec(n, "EmitPoint", target.round())

func _hit_test(p: Vector2) -> int:
	var ems := doc.emitter_nodes()
	for i in range(ems.size() - 1, -1, -1):
		if p.distance_to(_emitter_canvas_pos(ems[i])) <= HIT_R:
			return i
	return -1

## 供编辑器状态栏显示拖拽提示
func drag_hint() -> String:
	match _drag_mode:
		DragMode.DIRECTION:
			return "拖拽中：发射角度（按住 Shift 吸附 15°）"
		DragMode.RANGE:
			return "拖拽中：范围（以发射角度为中心对称张开）"
		DragMode.RADIUS:
			return "拖拽中：发射半径 + 半径方向"
		DragMode.MOVE:
			return "拖拽中：位置" + ("（吸附网格）" if snap_grid else "")
		DragMode.WAY:
			return "拖拽中：Way 条数（离中心越远条数越多）"
	return ""
