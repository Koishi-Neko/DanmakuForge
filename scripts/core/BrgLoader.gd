class_name BrgLoader
extends RefCounted
## SlimeStorm `.brg`（弹幕工程，纯 XML ver 1.02）导入器：XML → 数据类。
##
## 只做解析、不做运行；运行时播放见 `BrgPlayback.gd`。格式细节见 `docs/BRG_FORMAT.md`。
## 关键约定：事件属性按 `ChangeNameEmitter` / `ChangeNameBullet` **字符串**读取，
## 不依赖 `changename` 数字 ID（数字 ID 仅实验性确认到 4/6）。

## EmitPoint 的「自身」哨兵（跟随发射器）
const SENTINEL_SELF := -99998.0
## EmitDirection / RadiusDirection 的「指向自机」哨兵
const SENTINEL_AIM := -99999.0

## 单条事件：条件 + 变化
class Event:
	extends RefCounted
	var mode := "Emitter"          # Emitter / Bullet
	var contype := "Time"          # 条件量
	var op := "Equal"              # Equal / Greater / Less / GreaterEqual / LessEqual / NotEqual
	var cond_value := 0.0
	var change_mode := "Increase"  # Increase / Decrease
	var change_type := "Step"      # Step / Linear
	var change_name := ""          # 属性名（ChangeNameEmitter / ChangeNameBullet）
	var res := 1.0                 # 变化量
	var change_time := 1           # Linear 的时长（帧）

## 事件组：若干事件 + 是否循环
class EventGroup:
	extends RefCounted
	var loop := false
	var loop_circle := 0
	var events: Array = []         # Array[Event]

## 子弹发射器（EmitterBullet）。命名用 Brg 前缀，避免与全局类 `Emitter` 冲突。
class BrgEmitter:
	extends RefCounted
	var index := 0
	var tag := ""
	var start_time := 0
	var duration := 0
	var disabled := false
	var position := Vector2.ZERO       # 相对宿主的偏移（设计像素）
	var texture_name := ""
	var hi_res := false
	# --- 可变发射几何（事件会改）---
	var emit_point := Vector2(SENTINEL_SELF, SENTINEL_SELF)
	var emit_radius := 0.0
	var radius_direction := 0.0
	var rd_follows_ed := false
	var way := 1
	var circle := 1
	var emit_direction := 0.0
	var range_deg := 0.0
	var count := 1
	var delta_v := 0.0
	var delta_a := 0.0
	var layer := "Middle"
	var emit_time_list: Array = []     # int 帧
	var groups: Array = []             # Array[EventGroup]（发射器事件）
	var bullet_groups: Array = []      # Array[EventGroup]（子弹自身事件 BulletEventGroupList）
	# --- 粒子参数 ---
	var life_time := 60.0
	var scale_w := 1.0
	var scale_h := 1.0
	var color := Color.WHITE
	var angle := 0.0
	var angle_follows_dir := false
	var bullet_velocity := 0.0
	var bullet_direction := 0.0
	var bullet_accel := 0.0
	var bullet_acc_dir := 0.0
	var angular_velocity := 0.0
	# --- 本工程扩展（复用 SlimeStorm 保留字段）---
	## ParaA > 0：该发射器的子弹为追踪弹，转向速率（度/帧），见 BulletManager._home
	var para_a := 0.0
	var para_b := 0.0
	# --- 发射器自身运动（emitter 本体，不是子弹） ---
	var self_velocity := 0.0        # px/帧（设计单位）
	var self_direction := 0.0       # 度，0=右
	var self_accelerate := 0.0      # px/帧²
	var self_acc_dir := 0.0         # 度
	var out_bound := false
	var protect100 := false
	var unremoveable := false
	# --- 随机量 ---
	var ran_x := 0.0
	var ran_y := 0.0
	var ran_radius := 0.0
	var ran_radius_dir := 0.0
	var ran_way := 0.0
	var ran_circle := 0.0
	var ran_emit_dir := 0.0
	var ran_range := 0.0
	var ran_bullet_velocity := 0.0
	var ran_bullet_direction := 0.0
	var ran_bullet_accel := 0.0
	var ran_bullet_acc_dir := 0.0

## 整个弹幕工程
class Barrage:
	extends RefCounted
	var version := ""
	var beat := 0.0
	var offset := 0
	var max_time := 0
	var loop := false
	var emitters: Array = []           # Array[Emitter]

# ------------------------------------------------------------------ 入口

## 解析缓存：`.brg` 是只读数据，同一个文件只该解析一次。
## 符卡反复播放 / 换回同一张符卡时，XMLParser 全量解析 300KB 级 XML 是可见卡顿，
## 这里按路径缓存解析结果（BrgPlayback 只读，不改 Barrage 内部状态）。
static var _file_cache: Dictionary = {}

static func load_file(path: String):
	if _file_cache.has(path):
		return _file_cache[path]
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[BrgLoader] 打不开：%s" % path)
		return null
	var bar = load_text(f.get_as_text())
	if bar != null:
		_file_cache[path] = bar
	return bar

## 清空解析缓存（编辑器改了 `.brg` 内容后调用）
static func clear_cache() -> void:
	_file_cache.clear()

static func load_text(text: String):
	var parser := XMLParser.new()
	if parser.open_buffer(text.to_utf8_buffer()) != OK:
		push_error("[BrgLoader] XML 解析失败")
		return null
	var root: Dictionary = {}
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			root = _read_element(parser)
			break
	if root.is_empty():
		return null
	var b := Barrage.new()
	b.version = _str(root, "version", "")
	b.beat = _f(_str(root, "Beat", "0"))
	b.offset = int(_f(_str(root, "Offset", "0")))
	b.max_time = int(_f(_str(root, "MaxTime", "0")))
	b.loop = _str(root, "Loop", "false") == "true"
	var list := _child(root, "BulletEmitterList")
	var idx := 0
	for eb in _children(list, "EmitterBullet"):
		b.emitters.append(_parse_emitter(eb, idx))
		idx += 1
	return b

# ------------------------------------------------------------------ XML → 通用树

static func _read_element(parser: XMLParser) -> Dictionary:
	var node := {"name": parser.get_node_name(), "children": [], "text": ""}
	if parser.is_empty():
		return node
	while parser.read() == OK:
		var t := parser.get_node_type()
		if t == XMLParser.NODE_ELEMENT:
			(node["children"] as Array).append(_read_element(parser))
		elif t == XMLParser.NODE_TEXT:
			node["text"] = String(node["text"]) + parser.get_node_data().strip_edges()
		elif t == XMLParser.NODE_ELEMENT_END:
			break
	return node

static func _child(node: Dictionary, name: String) -> Dictionary:
	for c in node.get("children", []):
		if c["name"] == name:
			return c
	return {}

static func _children(node: Dictionary, name: String) -> Array:
	var out: Array = []
	for c in node.get("children", []):
		if c["name"] == name:
			out.append(c)
	return out

static func _str(node: Dictionary, name: String, def: String) -> String:
	var c := _child(node, name)
	if c.is_empty():
		return def
	var s := String(c.get("text", ""))
	return s if s != "" else def

static func _f(s: String) -> float:
	return float(s) if s.is_valid_float() else 0.0

static func _i(s: String) -> int:
	return int(s) if s.is_valid_int() else 0

## 形如 <Position><X>..</X><Y>..</Y></Position>
static func _vec(node: Dictionary, name: String, def := Vector2.ZERO) -> Vector2:
	var c := _child(node, name)
	if c.is_empty():
		return def
	return Vector2(_f(_str(c, "X", "0")), _f(_str(c, "Y", "0")))

## 形如 <EmitDirection><Value>90</Value><mode>Normal</mode></EmitDirection>
static func _angle(node: Dictionary, name: String, def: float) -> float:
	var c := _child(node, name)
	if c.is_empty():
		return def
	return _f(_str(c, "Value", str(def)))

## 形如 <EmitTimeList><int>10</int>...</EmitTimeList>
static func _int_list(node: Dictionary, name: String) -> Array:
	var c := _child(node, name)
	if c.is_empty():
		return []
	var out: Array = []
	for ch in c.get("children", []):
		var s := String(ch.get("text", ""))
		if s != "":
			out.append(_i(s))
	return out

## ARGBColor:a:r:g:b
static func _color(s: String) -> Color:
	if not s.begins_with("ARGBColor"):
		return Color.WHITE
	var p := s.split(":")
	if p.size() < 5:
		return Color.WHITE
	return Color(_f(p[2]) / 255.0, _f(p[3]) / 255.0, _f(p[4]) / 255.0, _f(p[1]) / 255.0)

# ------------------------------------------------------------------ EmitterBullet

static func _parse_emitter(eb: Dictionary, index: int) -> BrgEmitter:
	var e := BrgEmitter.new()
	e.index = index
	e.tag = _str(eb, "Tag", "")
	e.start_time = _i(_str(eb, "StartTime", "0"))
	e.duration = _i(_str(eb, "Duration", "0"))
	e.disabled = _str(eb, "Disabled", "false") == "true"
	e.position = _vec(eb, "Position")
	e.self_velocity = _f(_str(eb, "Velocity", "0"))
	e.self_direction = _f(_str(eb, "Direction", "0"))
	e.self_accelerate = _f(_str(eb, "Accelerate", "0"))
	e.self_acc_dir = _f(_str(eb, "AccDirection", "0"))
	e.texture_name = _str(eb, "TextureName", "")
	e.hi_res = _str(eb, "HiRes", "false") == "true"
	e.emit_point = _vec(eb, "EmitPoint", Vector2(SENTINEL_SELF, SENTINEL_SELF))
	e.emit_radius = _f(_str(eb, "EmitRadius", "0"))
	e.radius_direction = _angle(eb, "RadiusDirection", 0.0)
	e.rd_follows_ed = _str(eb, "RDirectionFollowsEDirection", "false") == "true"
	e.way = _i(_str(eb, "Way", "1"))
	e.circle = _i(_str(eb, "Circle", "1"))
	e.emit_direction = _angle(eb, "EmitDirection", 0.0)
	e.range_deg = _f(_str(eb, "Range", "0"))
	e.count = _i(_str(eb, "Count", "1"))
	e.delta_v = _f(_str(eb, "DeltaV", "0"))
	e.delta_a = _f(_str(eb, "DeltaA", "0"))
	e.layer = _str(eb, "Layer", "Middle")
	e.emit_time_list = _int_list(eb, "EmitTimeList")
	e.life_time = _f(_str(eb, "LifeTime", "60"))
	e.scale_w = _f(_str(eb, "ScaleWidth", "1"))
	e.scale_h = _f(_str(eb, "ScaleHeight", "1"))
	e.color = _color(_str(eb, "ColorValue", "ARGBColor:255:255:255:255"))
	e.color.a *= clampf(_f(_str(eb, "Transparent", "255")) / 255.0, 0.0, 1.0)
	e.angle = _f(_str(eb, "Angle", "0"))
	e.angle_follows_dir = _str(eb, "AngleFollowsDirection", "false") == "true"
	e.bullet_velocity = _f(_str(eb, "BulletVelocity", "0"))
	e.bullet_direction = _f(_str(eb, "BulletDirection", "0"))
	e.bullet_accel = _f(_str(eb, "BulletAccelerate", "0"))
	e.bullet_acc_dir = _f(_str(eb, "BulletAccDirection", "0"))
	e.angular_velocity = _f(_str(eb, "AngularVelocity", "0"))
	e.para_a = _f(_str(eb, "ParaA", "0"))
	e.para_b = _f(_str(eb, "ParaB", "0"))
	e.out_bound = _str(eb, "OutBound", "false") == "true"
	e.protect100 = _str(eb, "Protect100", "false") == "true"
	e.unremoveable = _str(eb, "UnRemoveable", "false") == "true"
	e.ran_x = _f(_str(eb, "RanX", "0"))
	e.ran_y = _f(_str(eb, "RanY", "0"))
	e.ran_radius = _f(_str(eb, "RanRadius", "0"))
	e.ran_radius_dir = _f(_str(eb, "RanRadiusDirection", "0"))
	e.ran_way = _f(_str(eb, "RanWay", "0"))
	e.ran_circle = _f(_str(eb, "RanCircle", "0"))
	e.ran_emit_dir = _f(_str(eb, "RanEmitDirection", "0"))
	e.ran_range = _f(_str(eb, "RanRange", "0"))
	e.ran_bullet_velocity = _f(_str(eb, "RanBulletVelocity", "0"))
	e.ran_bullet_direction = _f(_str(eb, "RanBulletDirection", "0"))
	e.ran_bullet_accel = _f(_str(eb, "RanBulletAccelerate", "0"))
	e.ran_bullet_acc_dir = _f(_str(eb, "RanBulletAccDirection", "0"))
	var gl := _child(eb, "EventGroupList")
	for g in gl.get("children", []):
		if String(g["name"]).begins_with("EventGroup"):
			e.groups.append(_parse_group(g))
	var bgl := _child(eb, "BulletEventGroupList")
	for g in bgl.get("children", []):
		if String(g["name"]).begins_with("EventGroup"):
			e.bullet_groups.append(_parse_group(g))
	return e

static func _parse_group(g: Dictionary) -> EventGroup:
	var grp := EventGroup.new()
	grp.loop = _str(g, "Loop", "false") == "true"
	grp.loop_circle = _i(_str(g, "LoopCircle", "0"))
	var el := _child(g, "EventList")
	for ed in _children(el, "EventData"):
		var ev := Event.new()
		ev.mode = _str(ed, "Mode", "Emitter")
		ev.contype = _str(ed, "contype", "Time")
		ev.op = _str(ed, "opreator", "Equal")
		ev.cond_value = _f(_str(ed, "conditionValue", "0"))
		ev.change_mode = _str(ed, "changemode", "Increase")
		ev.change_type = _str(ed, "changetype", "Step")
		var cne := _str(ed, "ChangeNameEmitter", "")
		var cnb := _str(ed, "ChangeNameBullet", "")
		# 按作用对象取属性名：Emitter 事件读 ChangeNameEmitter，Bullet 事件读 ChangeNameBullet
		if ev.mode == "Bullet":
			ev.change_name = cnb if cnb != "" else cne
		else:
			ev.change_name = cne if cne != "" else cnb
		ev.res = _f(_str(ed, "res", "1"))
		ev.change_time = maxi(1, _i(_str(ed, "changetime", "1")))
		grp.events.append(ev)
	return grp
