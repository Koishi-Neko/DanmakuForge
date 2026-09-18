class_name BrgEventEditor
extends Window
## 事件组编辑器（P1）：编辑发射器事件 `EventGroupList` 与子弹事件 `BulletEventGroupList`。
##
## ================================================================== 关键正确性
##
## `.brg` 的事件有两条容易踩的坑（见 `BRG_FORMAT.md` §3）：
##  1. **`changename` 数字 ID 必须与 `ChangeName*` 字符串一致**，否则事件空转，
##     且 SlimeStorm 打开会报「XML 文档(N,C)中有错误」。
##     本编辑器一律通过 `BrgDocument.set_event_result()` 同时写两者。
##  2. **即便 `Mode=Bullet`，`ChangeNameEmitter` / `ChangeNameAffecter` 也必须填合法成员**，
##     所以新建事件时三个字段都会写成各自枚举的第 0 项。
##
## 事件语义：**每帧检测条件，满足就执行**（BRG_FORMAT.md §3「事件执行语义」）。
##   `Equal` → 只在那一帧成立（一次性）；`Greater`/`Less` → 之后每帧都成立（每帧重放，
##   `Increase` 会逐帧累积）。界面里对此有显式提示。

signal changed()          ## 事件被改动（编辑器据此标记预览需重放）

const SIDE_EMITTER := 0
const SIDE_BULLET := 1

var doc: BrgDocument = null
var emitter: BrgDocument.XNode = null
var side := SIDE_EMITTER

var _group_list: ItemList = null
var _event_list: ItemList = null
var _group_info: Label = null
var _loop_cb: CheckBox = null
var _loop_circle: SpinBox = null
var _fields_box: VBoxContainer = null
var _hint: Label = null
var _suspend := false
var _side_opt: OptionButton = null

class FieldRow:
	var tag: String
	var kind: String      ## option / spin / int
	var node: Control
	func _init(t: String, k: String, n: Control) -> void:
		tag = t
		kind = k
		node = n

var _rows: Array = []

func _init() -> void:
	title = "事件编辑器"
	size = Vector2i(1060, 780)
	transient = true
	close_requested.connect(func(): hide())
	unresizable = false

func _ready() -> void:
	_build()

func open(p_doc: BrgDocument, p_emitter: BrgDocument.XNode) -> void:
	doc = p_doc
	emitter = p_emitter
	title = "事件编辑器 — %s" % doc.get_field(emitter, "Tag", "?")
	# 默认展示**有事件的那一侧**，否则一打开就是空列表，看不出这个发射器有什么行为
	if doc.event_groups(emitter, false).is_empty() \
			and not doc.event_groups(emitter, true).is_empty():
		side = SIDE_BULLET
	else:
		side = SIDE_EMITTER
	if not visible and DisplayServer.get_name() != "headless":
		popup_centered(size)
		# 内嵌子窗口时 popup_centered 会贴到左上角，手动居中到编辑器里
		var p := get_parent() as Control
		if p != null:
			position = Vector2i(
				maxi(0, int((p.size.x - float(size.x)) * 0.5)),
				maxi(0, int((p.size.y - float(size.y)) * 0.5)))
	_refresh_all()

# ------------------------------------------------------------------ 构建

func _build() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 8
	root.offset_top = 8
	root.offset_right = -8
	root.offset_bottom = -8
	add_child(root)

	# 顶部：发射器事件 / 子弹事件 切换
	var top := HBoxContainer.new()
	var lab := Label.new()
	lab.text = "事件类型"
	top.add_child(lab)
	_side_opt = OptionButton.new()
	_side_opt.add_item("发射器事件（EventGroupList）", SIDE_EMITTER)
	_side_opt.add_item("子弹自身事件（BulletEventGroupList）", SIDE_BULLET)
	_side_opt.item_selected.connect(func(i):
		side = i
		_refresh_all())
	top.add_child(_side_opt)
	_hint = Label.new()
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.clip_text = true
	_hint.modulate = Color(1, 1, 1, 0.65)
	top.add_child(_hint)
	root.add_child(top)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	# 左：事件组列表
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(230, 0)
	var gl := Label.new()
	gl.text = "事件组"
	left.add_child(gl)
	_group_list = ItemList.new()
	_group_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_group_list.item_selected.connect(func(i): _on_group_selected(i))
	left.add_child(_group_list)
	var gbtns := HBoxContainer.new()
	gbtns.add_child(_btn("+ 组", _on_add_group))
	gbtns.add_child(_btn("- 组", _on_del_group))
	left.add_child(gbtns)
	split.add_child(left)

	# 中：事件列表（要够宽，否则「0) TimeMain = 42 → Velocity ChangeTo 0」会被截断）
	var mid := VBoxContainer.new()
	mid.custom_minimum_size = Vector2(400, 0)
	var el := Label.new()
	el.text = "事件列表"
	mid.add_child(el)
	_event_list = ItemList.new()
	_event_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_event_list.item_selected.connect(func(i): _on_event_selected(i))
	mid.add_child(_event_list)
	var ebtns := HBoxContainer.new()
	ebtns.add_child(_btn("+ 事件", _on_add_event))
	ebtns.add_child(_btn("删除", _on_del_event))
	ebtns.add_child(_btn("↑", func(): _move_event(-1)))
	ebtns.add_child(_btn("↓", func(): _move_event(1)))
	mid.add_child(ebtns)

	_group_info = Label.new()
	_group_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mid.add_child(_group_info)
	var loop_row := HBoxContainer.new()
	_loop_cb = CheckBox.new()
	_loop_cb.text = "条件循环"
	_loop_cb.toggled.connect(func(v):
		if not _suspend and _cur_group() != null:
			doc.set_field(_cur_group(), "Loop", v)
			_emit_changed())
	loop_row.add_child(_loop_cb)
	var lcl := Label.new()
	lcl.text = "LoopCircle"
	loop_row.add_child(lcl)
	_loop_circle = SpinBox.new()
	_loop_circle.min_value = 0
	_loop_circle.max_value = 999999
	_loop_circle.value_changed.connect(func(v):
		if not _suspend and _cur_group() != null:
			doc.set_field(_cur_group(), "LoopCircle", int(v))
			_emit_changed())
	loop_row.add_child(_loop_circle)
	mid.add_child(loop_row)
	split.add_child(mid)

	# 右：事件字段
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fields_box = VBoxContainer.new()
	_fields_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_fields_box)
	split.add_child(scroll)

	_build_fields()

func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b

## 只建一次控件，之后靠 `_refresh_fields()` 就地改值（避免每次选中都重建）
func _build_fields() -> void:
	var font := ThemeDB.fallback_font
	_add_hint("条件：**每帧检测，满足就执行**。`Equal` 只在那一帧成立（一次性）；"
		+ "`Greater`/`Less` 之后每帧都成立（`Increase` 会逐帧累积）。")
	_add_row("Mode", "option", "作用对象", BrgDocument.EVENT_MODES)
	_add_row("contype", "option", "条件量", BrgDocument.EVENT_CONDTYPES)
	_add_row("opreator", "option", "比较", BrgDocument.EVENT_OPERATORS)
	_add_row("conditionValue", "int", "条件值", [])
	_add_row("changemode", "option", "变化方式", BrgDocument.EVENT_CHANGEMODES)
	_add_row("changetype", "option", "变化规律", BrgDocument.EVENT_CHANGETYPES)
	_add_result_row()
	_add_row("res", "int", "变化量", [])
	_add_row("changetime", "int", "变化时长(帧)", [])

func _add_hint(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = Color(1, 1, 1, 0.6)
	_fields_box.add_child(l)

func _add_row(tag: String, kind: String, label: String, options: Array) -> void:
	var row := HBoxContainer.new()
	var lab := Label.new()
	lab.text = label
	lab.custom_minimum_size = Vector2(120, 0)
	row.add_child(lab)
	_suspend = true
	match kind:
		"option":
			var opt := OptionButton.new()
			for i in options.size():
				opt.add_item(String(options[i]), i)
			opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			opt.item_selected.connect(func(i):
				if _suspend:
					return
				var ev := _cur_event()
				if ev == null:
					return
				doc.set_field(ev, tag, String(options[i]))
				# 改 Mode 时结果属性表的取值范围也变了，要重新校准
				if tag == "Mode":
					doc.set_event_result(ev, String(options[i]), doc.event_result_name(ev))
					_refresh_event_list()
					_refresh_fields()
				_emit_changed())
			row.add_child(opt)
			_rows.append(FieldRow.new(tag, kind, opt))
		_:
			var sp := SpinBox.new()
			sp.min_value = -1000000
			sp.max_value = 1000000
			sp.step = 1
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp.value_changed.connect(func(v):
				if _suspend:
					return
				var ev := _cur_event()
				if ev != null:
					doc.set_field(ev, tag, int(v))
					if tag == "res" or tag == "conditionValue":
						_refresh_event_list()
					_emit_changed())
			row.add_child(sp)
			_rows.append(FieldRow.new(tag, "int", sp))
	_suspend = false
	_fields_box.add_child(row)

## 「结果属性」这一行的选项依赖当前 Mode，所以单独建、单独刷新
var _result_opt: OptionButton = null

func _add_result_row() -> void:
	var row := HBoxContainer.new()
	var lab := Label.new()
	lab.text = "结果属性"
	lab.custom_minimum_size = Vector2(120, 0)
	row.add_child(lab)
	_result_opt = OptionButton.new()
	_result_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_result_opt.item_selected.connect(func(i):
		if _suspend:
			return
		var ev := _cur_event()
		if ev == null:
			return
		var mode := doc.get_field(ev, "Mode", "Emitter")
		var names := BrgDocument.result_names(mode)
		if i >= 0 and i < names.size():
			doc.set_event_result(ev, mode, names[i])
			_refresh_event_list()
			_emit_changed())
	row.add_child(_result_opt)
	_rows.append(FieldRow.new("__result", "result", _result_opt))
	_fields_box.add_child(row)
	var note := Label.new()
	note.text = "（写入时自动同步 changename 数字 ID）"
	note.modulate = Color(1, 1, 1, 0.5)
	_fields_box.add_child(note)

# ------------------------------------------------------------------ 数据访问

func _cur_group() -> BrgDocument.XNode:
	var gs := _groups()
	var i := _group_list.get_selected_items()
	if i.is_empty() or i[0] >= gs.size():
		return null
	return gs[i[0]]

func _cur_event() -> BrgDocument.XNode:
	var g := _cur_group()
	if g == null:
		return null
	var evs := doc.group_events(g)
	var i := _event_list.get_selected_items()
	if i.is_empty() or i[0] >= evs.size():
		return null
	return evs[i[0]]

func _groups() -> Array:
	return doc.event_groups(emitter, side == SIDE_BULLET)

func _is_bullet_side() -> bool:
	return side == SIDE_BULLET

func _emit_changed() -> void:
	changed.emit()

# ------------------------------------------------------------------ 刷新

func _refresh_all() -> void:
	if _side_opt != null:
		_side_opt.selected = side
	_refresh_group_list()
	_refresh_event_list()
	_refresh_fields()

func _refresh_group_list() -> void:
	_suspend = true
	var keep := _group_list.get_selected_items()
	_group_list.clear()
	var gs := _groups()
	for i in gs.size():
		var g: BrgDocument.XNode = gs[i]
		var n: int = doc.group_events(g).size()
		_group_list.add_item("组 %d（%d 个事件）%s" % [i, n,
			"  ↻循环" if doc.get_b(g, "Loop", false) else ""])
	_hint.text = "%s：%d 组。%s" % [
		"子弹自身事件" if _is_bullet_side() else "发射器事件",
		gs.size(),
		"（子弹事件 contype=Time 按子弹年龄，TimeMain 按全局帧）" if _is_bullet_side() else ""]
	if not gs.is_empty():
		var sel: int = keep[0] if (not keep.is_empty() and keep[0] < gs.size()) else 0
		_group_list.select(sel)
	_suspend = false

func _refresh_event_list() -> void:
	_suspend = true
	var keep := _event_list.get_selected_items()
	_event_list.clear()
	var g := _cur_group()
	if g == null:
		_group_info.text = "（没有事件组，点「+ 组」新建）"
		_suspend = false
		return
	_loop_cb.button_pressed = doc.get_b(g, "Loop", false)
	_loop_circle.value = doc.get_i(g, "LoopCircle", 0)
	var evs := doc.group_events(g)
	for i in evs.size():
		var ev: BrgDocument.XNode = evs[i]
		var cond := "%s %s %s" % [
			doc.get_field(ev, "contype", "Time"),
			_short_op(doc.get_field(ev, "opreator", "Equal")),
			_num(doc.get_field(ev, "conditionValue", "0"))]
		_event_list.add_item("%d) %s → %s %s %s" % [
			i, cond, doc.event_result_name(ev),
			doc.get_field(ev, "changemode", "Increase"),
			_num(doc.get_field(ev, "res", "1"))])
	var n := evs.size()
	_group_info.text = "本组 %d 个事件%s" % [n, "（循环）" if doc.get_b(g, "Loop", false) else ""]
	if n > 0:
		var sel: int = keep[0] if (not keep.is_empty() and keep[0] < n) else 0
		_event_list.select(sel)
	_suspend = false

func _refresh_fields() -> void:
	var ev := _cur_event()
	_suspend = true
	for r in _rows:
		var row: FieldRow = r
		if row.kind == "result":
			var mode := doc.get_field(ev, "Mode", "Emitter") if ev != null else "Emitter"
			var names := BrgDocument.result_names(mode)
			var opt := row.node as OptionButton
			opt.clear()
			for i in names.size():
				opt.add_item("%s  (id %d)" % [names[i], i], i)
			if ev != null:
				var cur := doc.event_result_name(ev)
				var k: int = names.find(cur)
				opt.selected = maxi(0, k)
			opt.disabled = ev == null
			continue
		var enabled := ev != null
		# OptionButton 用 disabled（它没有 editable 属性，写错会运行时报错）
		if row.node is SpinBox:
			(row.node as SpinBox).editable = enabled
		elif row.node is OptionButton:
			(row.node as OptionButton).disabled = not enabled
		elif row.node is LineEdit:
			(row.node as LineEdit).editable = enabled
		if not enabled:
			continue
		match row.kind:
			"option":
				var opt2 := row.node as OptionButton
				var arr: PackedStringArray = _option_array_for(row.tag)
				var cur2 := doc.get_field(ev, row.tag, "")
				opt2.selected = maxi(0, arr.find(cur2))
			_:
				(row.node as SpinBox).value = float(doc.get_i(ev, row.tag, 0))
	_suspend = false

func _option_array_for(tag: String) -> PackedStringArray:
	match tag:
		"Mode":
			return BrgDocument.EVENT_MODES
		"contype":
			return BrgDocument.EVENT_CONDTYPES
		"opreator":
			return BrgDocument.EVENT_OPERATORS
		"changemode":
			return BrgDocument.EVENT_CHANGEMODES
		"changetype":
			return BrgDocument.EVENT_CHANGETYPES
	return PackedStringArray()

static func _short_op(op: String) -> String:
	match op:
		"Equal":
			return "="
		"Greater":
			return ">"
		"Less":
			return "<"
	return op

static func _num(s: String) -> String:
	if s.is_valid_float():
		var f := float(s)
		return str(int(f)) if is_equal_approx(f, roundf(f)) else String.num(f, 2)
	return s

# ------------------------------------------------------------------ 操作

func _on_group_selected(_i: int) -> void:
	if _suspend:
		return
	_refresh_event_list()
	_refresh_fields()

func _on_event_selected(_i: int) -> void:
	if _suspend:
		return
	_refresh_fields()

func _on_add_group() -> void:
	if doc == null or emitter == null:
		return
	doc.add_event_group(emitter, _is_bullet_side())
	_refresh_group_list()
	_refresh_event_list()
	_refresh_fields()
	_emit_changed()

func _on_del_group() -> void:
	var g := _cur_group()
	if g == null:
		return
	doc.delete_group(emitter, _is_bullet_side(), g)
	_refresh_group_list()
	_refresh_event_list()
	_refresh_fields()
	_emit_changed()

func _on_add_event() -> void:
	var g := _cur_group()
	if g == null:
		_on_add_group()
		g = _cur_group()
		if g == null:
			return
	doc.add_event(g, _is_bullet_side())
	_refresh_group_list()
	_refresh_event_list()
	_refresh_fields()
	_emit_changed()

func _on_del_event() -> void:
	var g := _cur_group()
	var ev := _cur_event()
	if g == null or ev == null:
		return
	doc.delete_event(g, ev)
	_refresh_group_list()
	_refresh_event_list()
	_refresh_fields()
	_emit_changed()

func _move_event(dir: int) -> void:
	var g := _cur_group()
	var ev := _cur_event()
	if g == null or ev == null:
		return
	var el := g.child("EventList")
	if el == null:
		return
	var i := el.children.find(ev)
	var j := i + dir
	if i < 0 or j < 0 or j >= el.children.size():
		return
	el.children.remove_at(i)
	el.children.insert(j, ev)
	doc.dirty = true
	_refresh_event_list()
	_event_list.select(j)
	_refresh_fields()
	_emit_changed()
