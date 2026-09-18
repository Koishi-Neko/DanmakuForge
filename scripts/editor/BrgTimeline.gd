class_name BrgTimeline
extends Control
## 时间轴轨道编辑器（P1）：一个发射器一条轨，拖拽改 StartTime / Duration。
##
## 对齐 SlimeStorm 手册 §5.8 的交互习惯：
##   · 拖轨道片段本体        → 改 `StartTime`
##   · 拖片段右边缘的红色把手 → 改 `Duration`
##   · 点片段                → 选中该发射器（与结构树、画布联动）
##   · 在标尺上点击/拖动      → 移动播放头（scrub）
##   · `Ctrl` + 滚轮          → 缩放；`Shift` + 滚轮 → 横向平移；滚轮 → 纵向滚动
##   · 中键拖动              → 横向平移
##
## 说明：`Duration = 0` 在 `.brg` 里表示「不限时长」（见 BrgPlayback：`duration > 0`
## 才判结束），所以片段会一直画到右端并标注「∞」。

signal emitter_selected(index: int, additive: bool)
signal scrub(frame: int)
signal drag_started()
signal drag_finished()
signal edited(index: int)
signal copy_requested()            ## 右键菜单：复制选中发射器
signal paste_requested()           ## 右键菜单：粘贴

const GUTTER := 150.0          ## 左侧标签栏宽度
const RULER_H := 20.0          ## 顶部标尺高度
const TRACK_H := 22.0
const BAR_H := 15.0
const EDGE_GRAB := 6.0         ## 右边缘把手命中宽度
const MIN_PPF := 0.02          ## 最小 每帧像素数
const MAX_PPF := 8.0

enum Drag { NONE, MOVE, RESIZE, SCRUB, PAN }

var doc: BrgDocument = null
var selected: Array = []
var playhead := 0
var max_time := 1200

var px_per_frame := 0.35
var scroll_frames := 0.0
var scroll_y := 0.0
var snap_frames := true        ## 拖拽吸附整帧

var _hover := -1
var _drag: int = Drag.NONE
var _menu: PopupMenu = null
var _drag_index := -1
var _grab_off_frames := 0.0    ## MOVE：按下点相对 StartTime 的帧偏移
## 多选拖拽：一起移动/改时长的发射器序号，及其拖拽开始时的原始值。
## 单选时这两张表只含被拖的那一个；`_apply_move/_apply_resize` 在表为空时
## 回退到「只改 _drag_index」，兼容直接驱动内部状态的测试。
var _group: Array = []
var _group_starts: Dictionary = {}
var _group_durs: Dictionary = {}
var _pan_from := Vector2.ZERO
var _pan_scroll := 0.0
var _pan_scroll_y := 0.0
## 用户还没手动缩放/平移时为 true：只要控件尺寸变化就自动重新适配整段。
## 必须这样做的原因：`fit()` 在布局跑完之前调用会拿到**控件最小尺寸**而不是真实宽度
## （实测拿到 400 而非 780，算出 0.43 px/帧，轨道片段只有十几像素宽）。
## 光靠「布局没好就记待办」不够——那次调用「成功」了，就再也不会重试。
var _auto_fit := true

const C_BG := Color(0.04, 0.04, 0.065)
const C_GUTTER := Color(0.07, 0.065, 0.1)
const C_RULER := Color(0.09, 0.085, 0.13)
const C_GRID := Color(1, 1, 1, 0.07)
const C_GRID_MAJOR := Color(1, 1, 1, 0.14)
const C_TEXT := Color(1, 1, 1, 0.8)
const C_TEXT_DIM := Color(1, 1, 1, 0.45)
const C_BAR := Color(0.36, 0.52, 0.85, 0.85)
const C_BAR_SEL := Color(0.3, 0.95, 0.55, 0.9)
const C_BAR_HOVER := Color(0.5, 0.66, 1.0, 0.95)
const C_EDGE := Color(1.0, 0.4, 0.4, 0.95)
const C_PLAYHEAD := Color(1.0, 0.85, 0.3, 0.95)
const C_BORDER := Color(0.55, 0.45, 0.75, 0.7)

func _ready() -> void:
	custom_minimum_size = Vector2(400, 150)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	resized.connect(_on_resized)
	_menu = PopupMenu.new()
	_menu.add_item("复制选中 (Ctrl+C)", 0)
	_menu.add_item("粘贴 (Ctrl+V)", 1)
	_menu.id_pressed.connect(func(id: int):
		if id == 0:
			copy_requested.emit()
		else:
			paste_requested.emit())
	add_child(_menu)

func _on_resized() -> void:
	if _auto_fit:
		_apply_fit()
	queue_redraw()

func set_document(p_doc: BrgDocument) -> void:
	doc = p_doc
	selected.clear()
	scroll_frames = 0.0
	scroll_y = 0.0
	_refresh_extent()
	fit()                 # 布局没好就记为待办，等 resized 补上
	queue_redraw()

func set_selected(p_indices: Array) -> void:
	selected = p_indices.duplicate()
	queue_redraw()

## 文档内容变了（改字段/增删发射器）后调用：重算长度并重绘，**不重置滚动位置**
func refresh() -> void:
	_refresh_extent()
	queue_redraw()

## 让整段弹幕刚好铺满可视宽度，并恢复「跟随尺寸自动适配」。
## 布局未完成时 `size.x` 是控件最小宽度，此时先不算；`resized` 会再调一次。
func fit() -> void:
	_auto_fit = true
	_apply_fit()

func _apply_fit() -> void:
	if doc == null:
		return
	var w := size.x - GUTTER
	if w <= 10.0:
		return
	scroll_frames = 0.0
	px_per_frame = clampf(w / maxf(1.0, float(_extent())), MIN_PPF, MAX_PPF)
	queue_redraw()

func _refresh_extent() -> void:
	if doc == null:
		return
	max_time = maxi(1, doc.get_i(doc.root, "MaxTime", 1200))
	for n in doc.emitter_nodes():
		var end: int = doc.get_i(n, "StartTime", 0) + doc.get_i(n, "Duration", 0)
		if end > max_time:
			max_time = end

func _extent() -> int:
	return maxi(1, max_time)

# ------------------------------------------------------------------ 坐标换算

func frame_to_x(f: float) -> float:
	return GUTTER + (f - scroll_frames) * px_per_frame

func x_to_frame(x: float) -> float:
	return scroll_frames + (x - GUTTER) / px_per_frame

func _track_y(i: int) -> float:
	return RULER_H + float(i) * TRACK_H - scroll_y

func _track_at(y: float) -> int:
	if doc == null or y < RULER_H:
		return -1
	var i := int(floor((y - RULER_H + scroll_y) / TRACK_H))
	if i < 0 or i >= doc.emitter_count():
		return -1
	return i

# ------------------------------------------------------------------ 绘制

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), C_BG)
	if doc == null:
		draw_string(ThemeDB.fallback_font, Vector2(12, 24), "（未打开 .brg）",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, C_TEXT_DIM)
		return
	var font := ThemeDB.fallback_font
	var tracks_h := float(doc.emitter_count()) * TRACK_H
	var body := Rect2(GUTTER, RULER_H, maxf(0.0, size.x - GUTTER),
		maxf(0.0, size.y - RULER_H))

	_draw_grid(font, body)
	_draw_tracks(font, body, tracks_h)
	_draw_ruler(font)
	_draw_playhead(body)

	draw_rect(Rect2(0, 0, GUTTER, size.y), C_GUTTER)
	draw_line(Vector2(GUTTER, 0), Vector2(GUTTER, size.y), C_BORDER, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size), C_BORDER, false, 1.0)

func _tick_step() -> int:
	# 让刻度大致每 70px 一个
	var cands := [1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 1200, 3000, 6000]
	for c in cands:
		if float(c) * px_per_frame >= 70.0:
			return c
	return 12000

func _draw_grid(font: Font, body: Rect2) -> void:
	var f0 := int(floor(scroll_frames))
	var f1 := int(ceil(x_to_frame(size.x)))
	var step := _tick_step()
	var major := step * 5
	var f := int(floor(float(f0) / float(step))) * step
	while f <= f1:
		var x := frame_to_x(float(f))
		if x >= GUTTER:
			var is_major: bool = (f % major) == 0
			draw_line(Vector2(x, RULER_H), Vector2(x, size.y),
				C_GRID_MAJOR if is_major else C_GRID, 1.0)
			if is_major:
				draw_string(font, Vector2(x + 3, size.y - 4), str(f),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, C_TEXT_DIM)
		f += step

func _draw_tracks(font: Font, body: Rect2, tracks_h: float) -> void:
	var ems := doc.emitter_nodes()
	for i in ems.size():
		var y := _track_y(i)
		if y + TRACK_H < RULER_H or y > size.y:
			continue
		var n: BrgDocument.XNode = ems[i]
		var st := doc.get_i(n, "StartTime", 0)
		var du := doc.get_i(n, "Duration", 0)
		var is_sel: bool = selected.has(i)
		var is_hov: bool = _hover == i

		# 交替底色，便于横向对齐阅读
		if i % 2 == 1:
			draw_rect(Rect2(GUTTER, y, body.size.x, TRACK_H), Color(1, 1, 1, 0.022))

		# 标签栏
		var tag := doc.get_field(n, "Tag", "")
		var lab := "%d %s%s" % [i, tag if tag != "" else "(无标签)",
			"  [停用]" if doc.get_b(n, "Disabled", false) else ""]
		draw_string(font, Vector2(6, y + 15), lab,
			HORIZONTAL_ALIGNMENT_LEFT, GUTTER - 10, 11,
			C_BAR_SEL if is_sel else C_TEXT)

		# 片段
		var x0 := frame_to_x(float(st))
		var x1: float = size.x if du <= 0 else frame_to_x(float(st + du))
		x0 = clampf(x0, GUTTER, size.x)
		x1 = clampf(x1, GUTTER, size.x)
		if x1 <= x0:
			# 极短片段也给 2px 可见宽度（SlimeStorm 同样最小化显示）
			x1 = minf(x0 + 2.0, size.x)
		var r := Rect2(x0, y + (TRACK_H - BAR_H) * 0.5, maxf(2.0, x1 - x0), BAR_H)
		var col := C_BAR
		if is_sel:
			col = C_BAR_SEL
		elif is_hov:
			col = C_BAR_HOVER
		draw_rect(r, col)
		draw_rect(r, Color(0, 0, 0, 0.45), false, 1.0)

		# 片段内文字：起始帧
		if r.size.x > 34.0:
			draw_string(font, Vector2(r.position.x + 4, r.position.y + 11),
				"%d" % st, HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
				Color(0.05, 0.05, 0.1, 0.9))

		# 右边缘把手（可拖时长）。Duration=0（不限时长）不画把手。
		if du > 0:
			var ex := frame_to_x(float(st + du))
			if ex > GUTTER and ex < size.x:
				draw_rect(Rect2(ex - 1.5, r.position.y, 3.0, BAR_H), C_EDGE)
		else:
			draw_string(font, Vector2(r.end.x - 16, r.position.y + 11), "∞",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.7))

func _draw_ruler(font: Font) -> void:
	draw_rect(Rect2(0, 0, size.x, RULER_H), C_RULER)
	draw_string(font, Vector2(6, 14), "时间轴（帧 @60fps）",
		HORIZONTAL_ALIGNMENT_LEFT, GUTTER - 10, 11, C_TEXT)
	var f0 := int(floor(scroll_frames))
	var f1 := int(ceil(x_to_frame(size.x)))
	var step := _tick_step()
	var major := step * 5
	var f := int(floor(float(f0) / float(step))) * step
	while f <= f1:
		var x := frame_to_x(float(f))
		if x >= GUTTER:
			var is_major: bool = (f % major) == 0
			draw_line(Vector2(x, RULER_H - (9.0 if is_major else 5.0)),
				Vector2(x, RULER_H), C_TEXT_DIM if is_major else C_GRID, 1.0)
			if is_major:
				draw_string(font, Vector2(x + 3, 13), str(f),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, C_TEXT)
		f += step

func _draw_playhead(body: Rect2) -> void:
	var x := frame_to_x(float(playhead))
	if x < GUTTER or x > size.x:
		return
	draw_line(Vector2(x, 0), Vector2(x, size.y), C_PLAYHEAD, 1.5)
	var d := 5.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(x - d, 0), Vector2(x + d, 0), Vector2(x, d + 3)]), C_PLAYHEAD)

# ------------------------------------------------------------------ 交互

func _gui_input(event: InputEvent) -> void:
	if doc == null:
		return
	if event is InputEventMouseButton:
		_handle_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_motion(event as InputEventMouseMotion)

func _handle_button(mb: InputEventMouseButton) -> void:
	var mp := mb.position
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if mb.pressed and _menu != null:
			var ri := _track_at(mp.y)
			if ri >= 0 and not selected.has(ri):
				emitter_selected.emit(ri, false)
			_menu.position = Vector2i(get_global_position() + mp)
			_menu.popup()
		return
	if mb.button_index == MOUSE_BUTTON_MIDDLE:
		if mb.pressed:
			_drag = Drag.PAN
			_pan_from = mp
			_pan_scroll = scroll_frames
			_pan_scroll_y = scroll_y
		else:
			_drag = Drag.NONE
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		var up: bool = mb.button_index == MOUSE_BUTTON_WHEEL_UP
		if mb.ctrl_pressed:
			# 以鼠标位置为锚点缩放
			var anchor := x_to_frame(mp.x)
			var k: float = 1.25 if up else 0.8
			px_per_frame = clampf(px_per_frame * k, MIN_PPF, MAX_PPF)
			scroll_frames = anchor - (mp.x - GUTTER) / px_per_frame
			scroll_frames = maxf(scroll_frames, 0.0)
			_auto_fit = false          # 用户接管了缩放：不要再自动适配
		elif mb.shift_pressed:
			scroll_frames = maxf(0.0, scroll_frames - (60.0 if up else -60.0) / px_per_frame)
			_auto_fit = false
		else:
			scroll_y = maxf(0.0, scroll_y - (TRACK_H * 3.0 if up else -TRACK_H * 3.0))
		queue_redraw()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return

	if not mb.pressed:
		var was: bool = _drag != Drag.NONE
		_drag = Drag.NONE
		_drag_index = -1
		_group.clear()
		_group_starts.clear()
		_group_durs.clear()
		if was:
			drag_finished.emit()
			queue_redraw()
		return

	# 标尺 → scrub
	if mp.y < RULER_H:
		_drag = Drag.SCRUB
		_apply_scrub(mp)
		drag_started.emit()
		return

	var i := _track_at(mp.y)
	if i < 0:
		return
	var n: BrgDocument.XNode = doc.emitter_nodes()[i]
	var st := doc.get_i(n, "StartTime", 0)
	var du := doc.get_i(n, "Duration", 0)
	var x_end := frame_to_x(float(st + du))
	# 命中右边缘把手 → 改时长（Duration=0 表示不限时长，不给把手）
	if du > 0 and absf(mp.x - x_end) <= EDGE_GRAB:
		_drag = Drag.RESIZE
		_drag_index = i
		if mb.ctrl_pressed or mb.shift_pressed:
			emitter_selected.emit(i, true)
			if not selected.has(i):
				return
		elif not selected.has(i):
			emitter_selected.emit(i, false)
		_begin_group(i)
		drag_started.emit()
		return
	# 命中片段 → 改起始时间
	if mp.x >= frame_to_x(float(st)) - 2.0 and (du <= 0 or mp.x <= x_end + 2.0):
		_drag = Drag.MOVE
		_drag_index = i
		_grab_off_frames = x_to_frame(mp.x) - float(st)
		if mb.ctrl_pressed or mb.shift_pressed:
			emitter_selected.emit(i, true)
			if not selected.has(i):
				return
		elif not selected.has(i):
			emitter_selected.emit(i, false)
		_begin_group(i)
		drag_started.emit()
		return
	# 点空白 → 也当作 scrub
	_drag = Drag.SCRUB
	_apply_scrub(mp)
	drag_started.emit()

func _handle_motion(mm: InputEventMouseMotion) -> void:
	var mp := mm.position
	match _drag:
		Drag.PAN:
			scroll_frames = maxf(0.0, _pan_scroll - (mp.x - _pan_from.x) / px_per_frame)
			scroll_y = maxf(0.0, _pan_scroll_y - (mp.y - _pan_from.y))
			queue_redraw()
		Drag.SCRUB:
			_apply_scrub(mp)
		Drag.MOVE:
			_apply_move(mp)
		Drag.RESIZE:
			_apply_resize(mp)
		_:
			var i := _track_at(mp.y)
			if i != _hover:
				_hover = i
				queue_redraw()

func _apply_scrub(mp: Vector2) -> void:
	var f := int(round(x_to_frame(mp.x)))
	f = clampi(f, 0, _extent())
	playhead = f
	queue_redraw()
	scrub.emit(f)

## 记录一次拖拽要一起改的发射器集合与拖拽前的原始值。
## 若被拖的片段本身处于多选里，则整组一起移动/改时长；否则只含它自己。
func _begin_group(ref_index: int) -> void:
	_group.clear()
	_group_starts.clear()
	_group_durs.clear()
	var ems := doc.emitter_nodes()
	var use_multi: bool = selected.has(ref_index) and selected.size() > 1
	var ids: Array = selected.duplicate() if use_multi else [ref_index]
	for i in ids:
		if i < 0 or i >= ems.size():
			continue
		_group.append(i)
		_group_starts[i] = doc.get_i(ems[i], "StartTime", 0)
		_group_durs[i] = doc.get_i(ems[i], "Duration", 0)
	if _group.is_empty() and ref_index >= 0 and ref_index < ems.size():
		_group = [ref_index]
		_group_starts[ref_index] = doc.get_i(ems[ref_index], "StartTime", 0)
		_group_durs[ref_index] = doc.get_i(ems[ref_index], "Duration", 0)

func _apply_move(mp: Vector2) -> void:
	if _drag_index < 0 or _drag_index >= doc.emitter_count():
		return
	var n: BrgDocument.XNode = doc.emitter_nodes()[_drag_index]
	var f := x_to_frame(mp.x) - _grab_off_frames
	if snap_frames:
		f = roundf(f)
	var ref_old: int = int(_group_starts.get(_drag_index, doc.get_i(n, "StartTime", 0)))
	# 整组移动时统一施加同一个 delta，并保证最左片段不越过 0
	var mins: int = ref_old
	for i in _group:
		mins = mini(mins, int(_group_starts.get(i, ref_old)))
	var delta: int = int(roundf(f)) - ref_old
	delta = maxi(delta, -mins)
	var group: Array = _group if not _group.is_empty() else [_drag_index]
	var ems := doc.emitter_nodes()
	for i in group:
		if i < 0 or i >= ems.size():
			continue
		var old: int = int(_group_starts.get(i, doc.get_i(ems[i], "StartTime", 0)))
		doc.set_field(ems[i], "StartTime", maxi(0, old + delta))
	_refresh_extent()
	queue_redraw()
	for i in group:
		edited.emit(i)

func _apply_resize(mp: Vector2) -> void:
	if _drag_index < 0 or _drag_index >= doc.emitter_count():
		return
	var ems := doc.emitter_nodes()
	var n: BrgDocument.XNode = ems[_drag_index]
	var ref_st: int = int(_group_starts.get(_drag_index, doc.get_i(n, "StartTime", 0)))
	var ref_du: int = int(_group_durs.get(_drag_index, doc.get_i(n, "Duration", 0)))
	if ref_du <= 0:
		ref_du = doc.get_i(n, "Duration", 0)
	var end_f := x_to_frame(mp.x)
	if snap_frames:
		end_f = roundf(end_f)
	# 整组统一施加「末端帧」增量；Duration=0（不限时长）的片段跳过
	var delta: int = int(end_f) - (ref_st + ref_du)
	var group: Array = _group if not _group.is_empty() else [_drag_index]
	for i in group:
		if i < 0 or i >= ems.size():
			continue
		var du: int = int(_group_durs.get(i, doc.get_i(ems[i], "Duration", 0)))
		if du <= 0:
			continue
		doc.set_field(ems[i], "Duration", maxi(1, du + delta))
	_refresh_extent()
	queue_redraw()
	for i in group:
		edited.emit(i)

## 让某个发射器的片段进入可视范围（从结构树/画布选中时调用）
func reveal(index: int) -> void:
	if doc == null or index < 0 or index >= doc.emitter_count():
		return
	var y := _track_y(index)
	if y < RULER_H:
		scroll_y = maxf(0.0, float(index) * TRACK_H - TRACK_H)
	elif y + TRACK_H > size.y:
		scroll_y = float(index) * TRACK_H - (size.y - RULER_H) + TRACK_H
	queue_redraw()
