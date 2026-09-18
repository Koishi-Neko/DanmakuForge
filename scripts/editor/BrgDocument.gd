class_name BrgDocument
extends RefCounted
## `.brg`（SlimeStorm 弹幕工程，纯 XML ver 1.02）**无损文档层**。
##
## ================================================================== 为什么需要它
##
## `BrgLoader` 只解析 146 种标签里的 72 种，**74 种完全没读**（发射器自身
## `Velocity/Direction/Accelerate/AccDirection`、`BindingID/DeepBinding`、`Blend`、
## `Ghosting*`、`Twinkle*`、`BackImage*`、`Region/VisualSize`、`Reflect*`、
## `ParaA/ParaB`、`ScaleX/ScaleY`、`Affect`、`MotionLink` …，每个发射器都有）。
## 拿 `BrgLoader` 的数据类当模型再存回 XML，会**静默抹掉近一半字段**。
##
## 所以编辑器用**双层模型**：
##   · `BrgDocument`（本文件）= 唯一真相源，完整保留 XML 树，**不认识的标签也原样留着**
##   · `BrgLoader` + `BrgPlayback` = 语义层，只用来播放/预览
## 编辑器改属性一律走本文件，绝不经由 `BrgLoader` 的数据类。
##
## ================================================================== 保真规格
##
## 规格由 `tools/proto_brg_roundtrip.py` 在全部 139 个真实 `.brg` 上反推并验证
## **逐字节一致**，写回必须严格满足：
##   1. UTF-8 **无 BOM**
##   2. **CRLF** 换行；**结尾无换行符**
##   3. **2 空格**缩进；根元素（`<Barrage>`）**无缩进**
##   4. 头部 `<?xml version="1.0"?>` 与 `<Barrage xmlns:xsi=… xmlns:xsd=…>`
##      **原样保留**（ElementTree / XMLParser 都会丢弃未被引用的 xmlns 声明，
##      所以根元素开标签按原文提取，不重建）
##   5. **固定元素顺序**：`EmitterBullet` 93 个字段、`EventData` 20 个字段。
##      顺序在全部 684 个发射器 / 2687 个事件中完全一致（C# XmlSerializer 语义；
##      顺序错 SlimeStorm 报「XML 文档(N,C)中有错误」）
##   6. 空元素写**自闭合**形式 `<X />`（斜杠前有一个空格）
##
## 校验：`godot --headless --path . -- --brg-roundtrip <目录>` 必须全部 OK。

# ------------------------------------------------------------------ 权威顺序表

## `EmitterBullet` 子元素顺序（93 项，139 文件 / 684 发射器完全一致）
const EMITTER_ORDER: PackedStringArray = [
	"EmitterType", "ID", "Tag", "StartTime", "Duration", "Position",
	"Velocity", "Direction", "Accelerate", "AccDirection", "TextureName",
	"RanVelocity", "RanDirection", "RanAccelerate", "RanAccDirection",
	"BindingID", "DeepBinding", "Disabled", "HiRes",
	"EventGroupList", "BulletEventGroupList", "BindWithDirection", "DeathBinding",
	"EmitPoint", "EmitRadius", "RadiusDirection", "RDirectionFollowsEDirection",
	"Way", "Circle", "EmitDirection", "Range", "Count", "DeltaV", "DeltaA",
	"Layer", "EmitTimeList", "SpecifySE",
	"RanX", "RanY", "RanRadius", "RanRadiusDirection", "RanWay", "RanCircle",
	"RanEmitDirection", "RanRange",
	"LifeTime", "ScaleWidth", "ScaleHeight", "ScaleWidthEqualsScaleHeight",
	"ColorValue", "Transparent", "Angle", "AngleFollowsDirection",
	"BulletVelocity", "BulletDirection", "BulletAccelerate", "BulletAccDirection",
	"ScaleX", "ScaleY", "BeginningEffect", "BeginMode", "EndingEffect",
	"Blend", "Ghosting", "GhostingCount", "OutBound", "Protect100", "UnRemoveable",
	"Affect", "MotionLink", "Reflect", "ReflectEdges", "Region", "VisualSize",
	"ColorType", "ParaA", "ParaB",
	"RanBulletAngle", "RanBulletVelocity", "RanBulletDirection",
	"RanBulletAccelerate", "RanBulletAccDirection", "AngularVelocity",
	"TwinkleCycle", "TwinkleDestColor", "TwinkleMode",
	"BackImageBlendMode", "BackImageColor", "BackImageTransparent",
	"BackImageTwinkleCycle", "BackImageTwinkleDestTrans", "BackImageTwinkleMode",
	"BackImageScale",
]

## `EventData` 子元素顺序（20 项，2687 个事件完全一致）
const EVENT_ORDER: PackedStringArray = [
	"Mode", "rand", "special", "conditionValue", "conditionSource",
	"conditionValue2", "conditionSource2", "contype", "contype2",
	"opreator", "opreator2", "collector", "changemode", "changetype",
	"changename", "ChangeNameEmitter", "ChangeNameBullet", "ChangeNameAffecter",
	"res", "changetime",
]

## 需要按权威顺序排序的元素类型（其余元素保持原始顺序）
const ORDER_MAP := {
	"EmitterBullet": EMITTER_ORDER,
	"EmitterEnemy": EMITTER_ORDER,   # 敌机发射器：字段是超集且同序
	"EventData": EVENT_ORDER,
}

## 顶层集合的规范顺序（新增集合时按此插入；已存在的不重排）
const TOP_LISTS: PackedStringArray = [
	"BulletEmitterList", "LaserEmitterList", "EnemyEmitterList",
	"EffectEmitterList", "AffecterList", "LinkCopyList",
]

# ------------------------------------------------------------------ 字段默认值
# 取自 BrgLoader 的默认值与样例工程实测值，供属性面板在字段缺失时显示。

const DEFAULTS := {
	"EmitterType": "Bullet", "ID": "0", "Tag": "Bullet0",
	"StartTime": "1", "Duration": "1200", "Disabled": "false", "HiRes": "false",
	"Velocity": "0", "Direction": "0", "Accelerate": "0", "AccDirection": "0",
	"BindingID": "-1", "DeepBinding": "true", "BindWithDirection": "false",
	"DeathBinding": "false",
	"TextureName": "",
	"RanVelocity": "0", "RanDirection": "0", "RanAccelerate": "0", "RanAccDirection": "0",
	"EmitRadius": "0", "RadiusDirection": "0", "RDirectionFollowsEDirection": "false",
	"Way": "4", "Circle": "5", "EmitDirection": "90", "Range": "0", "Count": "1",
	"DeltaV": "0", "DeltaA": "0", "Layer": "Middle",
	"SpecifySE": "-1", "MotionLink": "false", "Affect": "false",
	"RanX": "0", "RanY": "0", "RanRadius": "0", "RanRadiusDirection": "0",
	"RanWay": "0", "RanCircle": "0", "RanEmitDirection": "0", "RanRange": "0",
	"LifeTime": "500", "ScaleWidth": "1", "ScaleHeight": "1",
	"ScaleWidthEqualsScaleHeight": "true",
	"ColorValue": "ARGBColor:255:255:255:255", "Transparent": "255",
	"Angle": "0", "AngleFollowsDirection": "false",
	"BulletVelocity": "2", "BulletDirection": "0",
	"BulletAccelerate": "0", "BulletAccDirection": "0",
	"ScaleX": "1", "ScaleY": "1",
	"BeginningEffect": "Null", "BeginMode": "Null", "EndingEffect": "Null",
	"Blend": "AlphaBlend", "Ghosting": "false", "GhostingCount": "0",
	"OutBound": "false", "Protect100": "false", "UnRemoveable": "false",
	"Reflect": "0", "ReflectEdges": "0", "Region": "0", "VisualSize": "0",
	"ColorType": "0", "ParaA": "0", "ParaB": "0",
	"RanBulletAngle": "0", "RanBulletVelocity": "0", "RanBulletDirection": "0",
	"RanBulletAccelerate": "0", "RanBulletAccDirection": "0",
	"AngularVelocity": "0",
	"TwinkleCycle": "0", "TwinkleDestColor": "ARGBColor:255:255:255:255",
	"TwinkleMode": "Null",
	"BackImageBlendMode": "AlphaBlend",
	"BackImageColor": "ARGBColor:255:255:255:255", "BackImageTransparent": "255",
	"BackImageTwinkleCycle": "0",
	"BackImageTwinkleDestTrans": "255", "BackImageTwinkleMode": "Null",
	"BackImageScale": "1",
	# 嵌套结构
	"X": "0", "Y": "0", "Value": "0", "mode": "Normal",
}

## 哨兵值（见 BRG_FORMAT.md §4）
const SENTINEL_SELF := -99998.0   ## EmitPoint：跟随发射器自身
const SENTINEL_AIM := -99999.0    ## 角度：指向自机

# ------------------------------------------------------------------ 事件结果枚举
# 序号即 `changename` 数字 ID（见 BRG_FORMAT.md §3，2026-09-11 从 Barrage.dll 反射取得）。
# **`changename` 必须与其对应的 `ChangeName*` 字符串一致**，否则事件等于没生效，
# 且 SlimeStorm 打开会报「XML 文档(N,C)中有错误」。

const RESULT_EMITTER: PackedStringArray = [
	"PositionX", "PositionY", "Radius", "RadiusDirection", "Way", "Circle",
	"EmitterDirection", "Range", "Velocity", "Direction", "Acceleration",
	"AccDirection", "LifeTime", "ScaleWidth", "ScaleHeight", "R", "G", "B",
	"Transparent", "Angle", "BulletVelocity", "BulletDirection",
	"BulletAcceleration", "BulletAccDirection", "ScaleX", "ScaleY",
	"BeginEffect", "EndEffect", "BlendMode", "Ghosting", "OutBound",
	"Unremoveable", "TextureName", "ParaA", "ParaB", "Count", "DeltaV", "DeltaA",
]

const RESULT_BULLET: PackedStringArray = [
	"LifeTime", "ScaleWidth", "ScaleHeight", "R", "G", "B", "Transparent",
	"Angle", "Velocity", "Direction", "Acceleration", "AccDirection",
	"ScaleX", "ScaleY", "BeginEffect", "EndEffect", "BlendMode", "Ghosting",
	"OutBound", "Unremoverable", "TextureName", "PositionX", "PositionY",
	"Cover", "AngularVelocity",
]

const RESULT_AFFECTER: PackedStringArray = [
	"PositionX", "PositionY",
]

## 权威枚举（写错 SlimeStorm 直接报错）
const EVENT_MODES: PackedStringArray = ["None", "Emitter", "Bullet", "Affecter"]
const EVENT_CONDTYPES: PackedStringArray = ["Time", "TimeMain", "PositionX", "PositionY"]
## 注意：**没有 `GreaterEqual` / `LessEqual`**（BRG_FORMAT.md §3 已确认）
const EVENT_OPERATORS: PackedStringArray = ["Equal", "Greater", "Less"]
const EVENT_CHANGEMODES: PackedStringArray = ["ChangeTo", "Increase", "Decrease"]
const EVENT_CHANGETYPES: PackedStringArray = [
	"Linear", "Step", "Sin", "Cos", "EaseIn", "EaseOut", "EaseInOut",
]

## 事件结果的属性名表（按作用对象）
static func result_names(mode: String) -> PackedStringArray:
	match mode:
		"Bullet":
			return RESULT_BULLET
		"Affecter":
			return RESULT_AFFECTER
		_:
			return RESULT_EMITTER

## 某个 Mode 下「结果属性」写进哪个字段
static func change_name_field(mode: String) -> String:
	match mode:
		"Bullet":
			return "ChangeNameBullet"
		"Affecter":
			return "ChangeNameAffecter"
		_:
			return "ChangeNameEmitter"

# ------------------------------------------------------------------ XML 节点

class XNode:
	extends RefCounted
	var tag := ""
	var attrs: Dictionary = {}        # 属性名 -> 值
	var attr_order: PackedStringArray = []
	var children: Array = []          # Array[XNode]
	var text := ""
	var parent: XNode = null

	func child(p_tag: String) -> XNode:
		for c in children:
			if c.tag == p_tag:
				return c
		return null

	func children_of(p_tag: String) -> Array:
		var out: Array = []
		for c in children:
			if c.tag == p_tag:
				out.append(c)
		return out

	func has_child(p_tag: String) -> bool:
		return child(p_tag) != null

	func remove_child(p_node: XNode) -> void:
		var i := children.find(p_node)
		if i >= 0:
			children.remove_at(i)
			p_node.parent = null

	## 在父节点下新建子元素
	func add_child_named(p_tag: String, p_text := "") -> XNode:
		var n := XNode.new()
		n.tag = p_tag
		n.text = p_text
		n.parent = self
		children.append(n)
		return n

# ------------------------------------------------------------------ 实例状态

var root: XNode = null
var source_path := ""              # 来源文件（绝对或 res://）
var dirty := false                 # 是否有未保存改动

var _decl := '<?xml version="1.0"?>'   # 原样保留的 XML 声明行
var _root_open := "<Barrage>"          # 原样保留的根元素开标签（含 xmlns 属性）

# ------------------------------------------------------------------ 读取

static func load_file(path: String) -> BrgDocument:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[BrgDocument] 打不开：%s" % path)
		return null
	# 按字节读再自行 UTF-8 解码：`get_as_text()` 会吃掉 \r，而 CRLF 必须原样保留
	var text := f.get_buffer(f.get_length()).get_string_from_utf8()
	f.close()
	var doc := parse_text(text)
	if doc == null:
		push_error("[BrgDocument] 解析失败：%s" % path)
		return null
	doc.source_path = path
	return doc

static func parse_text(text: String) -> BrgDocument:
	var parser := XMLParser.new()
	if parser.open_buffer(text.to_utf8_buffer()) != OK:
		push_error("[BrgDocument] XML 打开失败")
		return null

	var doc := BrgDocument.new()
	doc._capture_header(text)

	var stack: Array = []
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var n := XNode.new()
				n.tag = parser.get_node_name()
				for i in parser.get_attribute_count():
					var an := parser.get_attribute_name(i)
					n.attrs[an] = parser.get_attribute_value(i)
					n.attr_order.append(an)
				if stack.is_empty():
					if doc.root == null:
						doc.root = n
					else:
						# 出现第二个根元素：非法，但按兄弟处理避免崩溃
						doc.root.children.append(n)
						n.parent = doc.root
				else:
					var p: XNode = stack.back()
					p.children.append(n)
					n.parent = p
				if not parser.is_empty():
					stack.append(n)
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if not stack.is_empty():
					# 不 strip：叶子元素的文本就是原值。
					# 有子元素者的文本只是缩进空白，序列化时会走 children 分支而被忽略。
					var s: XNode = stack.back()
					s.text += parser.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				if not stack.is_empty():
					stack.pop_back()

	if doc.root == null:
		push_error("[BrgDocument] 没有根元素")
		return null
	return doc

## 原样提取前两行，避免重建时丢失 xmlns 声明
func _capture_header(text: String) -> void:
	for raw in text.split("\n"):
		var t := raw.strip_edges()
		if t == "":
			continue
		if t.begins_with("<?xml"):
			_decl = t
		elif t.begins_with("<Barrage"):
			_root_open = t
			break

# ------------------------------------------------------------------ 写出

## 序列化为 .brg 文本（严格按保真规格）
func to_text() -> String:
	if root == null:
		return ""
	# 根元素无缩进 → 从 0 级开始，丢掉根自己的开/闭标签行，只取子树
	var body: Array = []
	_serialize(root, 0, body)
	var lines: Array = [_decl, _root_open]
	lines.append_array(body.slice(1, body.size() - 1))
	lines.append("</Barrage>")
	return "\r\n".join(PackedStringArray(lines))   # 结尾不加换行

func save(path := "") -> bool:
	var target := path if path != "" else source_path
	if target == "":
		push_error("[BrgDocument] 没有保存路径")
		return false
	var f := FileAccess.open(target, FileAccess.WRITE)
	if f == null:
		push_error("[BrgDocument] 写不了：%s" % target)
		return false
	f.store_string(to_text())    # UTF-8 无 BOM
	f.close()
	source_path = target
	dirty = false
	return true

func _serialize(node: XNode, indent: int, out: Array) -> void:
	var pad := "  ".repeat(indent)
	var attr_str := ""
	for a in node.attr_order:
		attr_str += ' %s="%s"' % [a, _escape(String(node.attrs[a]))]

	var kids: Array = node.children
	if ORDER_MAP.has(node.tag):
		kids = _sorted_by_order(node)
	if kids.is_empty():
		if node.text == "" and attr_str == "":
			out.append("%s<%s />" % [pad, node.tag])   # 自闭合，斜杠前有空格
		else:
			out.append("%s<%s%s>%s</%s>" % [pad, node.tag, attr_str, _escape(node.text), node.tag])
		return
	out.append("%s<%s%s>" % [pad, node.tag, attr_str])
	for c in kids:
		_serialize(c, indent + 1, out)
	out.append("%s</%s>" % [pad, node.tag])

## 按权威顺序稳定排序；未列入权威表的标签排在末尾（保持它们的相对顺序）
func _sorted_by_order(node: XNode) -> Array:
	var order: PackedStringArray = ORDER_MAP[node.tag]
	var keyed: Array = []
	for i in node.children.size():
		var c: XNode = node.children[i]
		var k := order.find(c.tag)
		keyed.append({"k": k if k >= 0 else order.size(), "i": i, "n": c})
	keyed.sort_custom(func(a, b):
		return a["k"] < b["k"] if a["k"] != b["k"] else a["i"] < b["i"])
	var out: Array = []
	for e in keyed:
		out.append(e["n"])
	return out

static func _escape(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

# ------------------------------------------------------------------ 顶层访问

func bullet_list() -> XNode:
	if root == null:
		return null
	return root.child("BulletEmitterList")

## 全部子弹发射器节点（不含敌机/激光/特效）
func emitter_nodes() -> Array:
	var lst := bullet_list()
	if lst == null:
		return []
	return lst.children_of("EmitterBullet")

func emitter_count() -> int:
	return emitter_nodes().size()

func top_field(p_tag: String, p_default := "") -> String:
	if root == null:
		return p_default
	var c := root.child(p_tag)
	if c == null or c.text.strip_edges() == "":
		return p_default
	return c.text

func set_top_field(p_tag: String, p_value: String) -> void:
	if root == null:
		return
	var c := root.child(p_tag)
	if c == null:
		c = root.add_child_named(p_tag)
		# 顶层字段位置：插到第一个集合之前（保持 version..Loop 在前）
		root.children.erase(c)
		var ins := 0
		for i in root.children.size():
			if TOP_LISTS.has(root.children[i].tag):
				ins = i
				break
			ins = i + 1
		root.children.insert(ins, c)
		c.parent = root
	c.text = p_value
	dirty = true

# ------------------------------------------------------------------ 字段读写

## 读子字段文本；缺失时返回 defaultValue（含 DEFAULTS 兜底）
##
## 注意：`Position` / `EmitPoint` / `EmitDirection` / `RadiusDirection` /
## `EmitTimeList` / `EventGroupList` 这类**容器元素**的 `text` 只是子元素之间的
## 缩进空白，没有语义。必须返回默认值——否则会把换行/空格当数值用
## （用 `get_vec` / `get_angle` / `get_int_list` 读它们）。
func get_field(node: XNode, p_tag: String, p_default := "") -> String:
	if node == null:
		return p_default
	var c := node.child(p_tag)
	if c == null:
		if p_default != "":
			return p_default
		return String(DEFAULTS.get(p_tag, ""))
	if not c.children.is_empty():
		return p_default
	return c.text

func get_f(node: XNode, p_tag: String, p_default := 0.0) -> float:
	var s := get_field(node, p_tag, "")
	return float(s) if s.is_valid_float() else p_default

func get_i(node: XNode, p_tag: String, p_default := 0) -> int:
	var s := get_field(node, p_tag, "")
	return int(s) if s.is_valid_int() else p_default

func get_b(node: XNode, p_tag: String, p_default := false) -> bool:
	var s := get_field(node, p_tag, "")
	if s == "":
		return p_default
	return s == "true"

## 写子字段；字段不存在则新建（序列化时按权威顺序就位）。数值一律整型友好输出。
func set_field(node: XNode, p_tag: String, p_value: Variant) -> void:
	if node == null:
		return
	var s := _to_xml_scalar(p_value)
	var c := node.child(p_tag)
	if c == null:
		c = node.add_child_named(p_tag, s)
	elif not c.children.is_empty():
		# 目标是容器元素（本该有子元素）：往里写 text 会把结构弄坏（例如把
		# <EmitDirection> 的 <Value>/<mode> 挤掉）。拒绝并告警，交由
		# set_vec / set_angle / set_int_list 去改它的子元素。
		push_warning("[BrgDocument] 拒绝把文本写入容器元素 <%s>（请用 set_vec/set_angle）" % p_tag)
		return
	elif c.text != s:
		c.text = s
	dirty = true

## 数值 → XML 文本：整数不写小数点，浮点去掉多余尾零（贴近 C# 输出）
static func _to_xml_scalar(v: Variant) -> String:
	if v is bool:
		return "true" if v else "false"
	if v is int:
		return str(v)
	if v is float:
		var f: float = v
		if is_equal_approx(f, roundf(f)) and absf(f) < 1e15:
			return str(int(roundf(f)))
		return String.num(f, 6).rstrip("0").rstrip(".")
	return String(v)

## `<Position><X>..</X><Y>..</Y></Position>` 形式
func get_vec(node: XNode, p_tag: String, p_default := Vector2.ZERO) -> Vector2:
	var c := node.child(p_tag)
	if c == null:
		return p_default
	return Vector2(get_f(c, "X", p_default.x), get_f(c, "Y", p_default.y))

func set_vec(node: XNode, p_tag: String, v: Vector2) -> void:
	if node == null:
		return
	var c := node.child(p_tag)
	if c == null:
		c = node.add_child_named(p_tag)
		c.add_child_named("X", "0")
		c.add_child_named("Y", "0")
	set_field(c, "X", v.x)
	set_field(c, "Y", v.y)

## `<EmitDirection><Value>90</Value><mode>Normal</mode></EmitDirection>` 形式
func get_angle(node: XNode, p_tag: String, p_default := 0.0) -> float:
	var c := node.child(p_tag)
	if c == null:
		return p_default
	return get_f(c, "Value", p_default)

func angle_is_aim(node: XNode, p_tag: String) -> bool:
	return get_angle(node, p_tag, 0.0) <= SENTINEL_AIM + 1.0

func set_angle(node: XNode, p_tag: String, p_value: float) -> void:
	if node == null:
		return
	var c := node.child(p_tag)
	if c == null:
		c = node.add_child_named(p_tag)
		c.add_child_named("Value", "0")
		c.add_child_named("mode", "Normal")
	set_field(c, "Value", p_value)

## `<EmitTimeList><int>10</int>…</EmitTimeList>`
func get_int_list(node: XNode, p_tag: String) -> Array:
	var out: Array = []
	var c := node.child(p_tag)
	if c == null:
		return out
	for k in c.children:
		if k.tag == "int" and k.text.strip_edges() != "":
			out.append(int(k.text))
	return out

func set_int_list(node: XNode, p_tag: String, values: Array) -> void:
	var c := node.child(p_tag)
	if c == null:
		c = node.add_child_named(p_tag)
	c.children.clear()
	for v in values:
		c.add_child_named("int", str(int(v)))
	dirty = true

# ------------------------------------------------------------------ 增删发射器（语义 A）

## 删除一个发射器节点。返回受影响的绑定引用信息（不自动改，交调用方提示）。
func delete_emitter(node: XNode) -> Dictionary:
	var lst := bullet_list()
	if lst == null or node == null:
		return {}
	var removed_id := get_i(node, "ID", -1)
	lst.remove_child(node)
	dirty = true
	var referencing: Array = []
	if removed_id >= 0:
		for e in emitter_nodes():
			if get_i(e, "BindingID", -1) == removed_id:
				referencing.append(get_field(e, "Tag", "?"))
	return {"removed_id": removed_id, "referencing": referencing}

## 在 BulletEmitterList 末尾追加一个新的子弹发射器
func add_emitter(p_tag := "Bullet0") -> XNode:
	if root == null:
		return null
	var lst := bullet_list()
	if lst == null:
		lst = root.add_child_named("BulletEmitterList")
	lst = bullet_list()
	var n := lst.add_child_named("EmitterBullet")
	var used: Array = []
	for e in emitter_nodes():
		used.append(get_i(e, "ID", -1))
	var nid := 0
	while used.has(nid):
		nid += 1
	# 填一套完整可用的默认字段（顺序由序列化保证）
	for t in ["EmitterType", "ID", "Tag", "StartTime", "Duration",
			"Velocity", "Direction", "Accelerate", "AccDirection", "TextureName",
			"RanVelocity", "RanDirection", "RanAccelerate", "RanAccDirection",
			"BindingID", "DeepBinding", "Disabled", "HiRes"]:
		var v := String(DEFAULTS.get(t, "0"))
		if t == "ID":
			v = str(nid)
		elif t == "Tag":
			v = p_tag
		n.add_child_named(t, v)
	n.add_child_named("EventGroupList")
	n.add_child_named("BulletEventGroupList")
	for t in ["BindWithDirection", "DeathBinding", "EmitRadius", "RadiusDirection",
			"RDirectionFollowsEDirection", "Way", "Circle", "EmitDirection", "Range",
			"Count", "DeltaV", "DeltaA", "Layer", "EmitTimeList", "SpecifySE",
			"RanX", "RanY", "RanRadius", "RanRadiusDirection", "RanWay", "RanCircle",
			"RanEmitDirection", "RanRange", "LifeTime", "ScaleWidth", "ScaleHeight",
			"ScaleWidthEqualsScaleHeight", "ColorValue", "Transparent", "Angle",
			"AngleFollowsDirection", "BulletVelocity", "BulletDirection",
			"BulletAccelerate", "BulletAccDirection", "ScaleX", "ScaleY",
			"BeginningEffect", "BeginMode", "EndingEffect", "Blend", "Ghosting",
			"GhostingCount", "OutBound", "Protect100", "UnRemoveable", "Affect",
			"MotionLink", "Reflect", "ReflectEdges", "Region", "VisualSize",
			"ColorType", "ParaA", "ParaB", "RanBulletAngle", "RanBulletVelocity",
			"RanBulletDirection", "RanBulletAccelerate", "RanBulletAccDirection",
			"AngularVelocity", "TwinkleCycle", "TwinkleDestColor", "TwinkleMode",
			"BackImageBlendMode", "BackImageColor", "BackImageTransparent",
			"BackImageTwinkleCycle", "BackImageTwinkleDestTrans",
			"BackImageTwinkleMode", "BackImageScale"]:
		# Position / EmitPoint / EmitDirection / RadiusDirection 都是容器元素，
		# 由下面单独创建；若在此也当标量写一遍会产生重复元素（SlimeStorm 会报错）。
		if t in ["EmitPoint", "Position", "EmitDirection", "RadiusDirection"]:
			continue
		n.add_child_named(t, String(DEFAULTS.get(t, "0")))
	var pos := n.add_child_named("Position")
	pos.add_child_named("X", "0")
	pos.add_child_named("Y", "0")
	var ep := n.add_child_named("EmitPoint")
	ep.add_child_named("X", str(int(SENTINEL_SELF)))
	ep.add_child_named("Y", str(int(SENTINEL_SELF)))
	for t in ["EmitDirection", "RadiusDirection"]:
		var a := n.add_child_named(t)
		a.add_child_named("Value", String(DEFAULTS.get(t, "0")))
		a.add_child_named("mode", "Normal")
	dirty = true
	return n

# ------------------------------------------------------------------ 复制 / 粘贴

## 深拷贝一个 XNode 子树（`parent` 指向新树内的父节点）
static func clone_node(src: XNode, parent: XNode = null) -> XNode:
	var n := XNode.new()
	n.tag = src.tag
	n.text = src.text
	n.attrs = src.attrs.duplicate()
	n.attr_order = src.attr_order.duplicate()
	n.parent = parent
	for c in src.children:
		n.children.append(clone_node(c, n))
	return n

## 把一份（深拷贝的）发射器节点插入 `BulletEmitterList` 末尾，分配新的 ID。
## 用于时间轴的复制/粘贴；源节点不被改动（可反复粘贴）。
func copy_emitter_into(src: XNode) -> XNode:
	if src == null or root == null:
		return null
	var lst := bullet_list()
	if lst == null:
		lst = root.add_child_named("BulletEmitterList")
	lst = bullet_list()
	var n := XNode.new()
	n.tag = "EmitterBullet"
	n.parent = lst
	for c in src.children:
		n.children.append(clone_node(c, n))
	lst.children.append(n)
	# 新 ID：避开现有全部 ID（BindingID 引用靠 ID，重复会串绑）
	var used: Array = []
	for e in emitter_nodes():
		if e != n:
			used.append(get_i(e, "ID", -1))
	var nid := 0
	while used.has(nid):
		nid += 1
	set_field(n, "ID", nid)
	var tag := get_field(n, "Tag", "")
	if tag != "":
		set_field(n, "Tag", tag + "_copy")
	dirty = true
	return n

# ------------------------------------------------------------------ 事件读写

## 事件组容器名：发射器事件用 `EventGroupList`，子弹事件用 `BulletEventGroupList`
static func group_list_name(is_bullet_event: bool) -> String:
	return "BulletEventGroupList" if is_bullet_event else "EventGroupList"

## 事件组的子元素名（SlimeStorm 用 `EventGroup_Emitter` / `EventGroup_Bullet`）
static func group_node_name(is_bullet_event: bool) -> String:
	return "EventGroup_Bullet" if is_bullet_event else "EventGroup_Emitter"

func event_groups(node: XNode, is_bullet_event: bool) -> Array:
	if node == null:
		return []
	var lst := node.child(group_list_name(is_bullet_event))
	if lst == null:
		return []
	var want := group_node_name(is_bullet_event)
	var out: Array = []
	for c in lst.children:
		if c.tag == want or c.tag.begins_with("EventGroup"):
			out.append(c)
	return out

func group_events(group: XNode) -> Array:
	if group == null:
		return []
	var el := group.child("EventList")
	if el == null:
		return []
	return el.children_of("EventData")

## 新建一个**完全合法**的 EventData（所有 20 个字段都填上）。
## 三个 `ChangeName*` 都必须填合法成员——即便 `Mode=Bullet`，`ChangeNameEmitter`
## 也不能空着，否则 SlimeStorm 照样报错。
func new_event(mode := "Emitter") -> XNode:
	var ev := XNode.new()
	ev.tag = "EventData"
	ev.text = ""
	for t in EVENT_ORDER:
		ev.add_child_named(t, "0")
	set_field(ev, "Mode", mode)
	set_field(ev, "rand", "0")
	set_field(ev, "special", "Null")
	set_field(ev, "conditionValue", "0")
	set_field(ev, "conditionSource", "Constant")
	set_field(ev, "conditionValue2", "0")
	set_field(ev, "conditionSource2", "Constant")
	set_field(ev, "contype", "Time")
	set_field(ev, "contype2", "Time")
	set_field(ev, "opreator", "Equal")
	set_field(ev, "opreator2", "Equal")
	set_field(ev, "collector", "NULL")
	set_field(ev, "changemode", "Increase")
	set_field(ev, "changetype", "Step")
	set_field(ev, "ChangeNameEmitter", RESULT_EMITTER[0])
	set_field(ev, "ChangeNameBullet", RESULT_BULLET[0])
	set_field(ev, "ChangeNameAffecter", RESULT_AFFECTER[0])
	set_field(ev, "res", "1")
	set_field(ev, "changetime", "1")
	set_event_result(ev, mode, result_names(mode)[0])
	return ev

## 设置事件结果属性：同时写 `ChangeName*` 字符串与 `changename` 数字 ID。
## 这两者必须一致，否则事件空转 / SlimeStorm 报错。
func set_event_result(ev: XNode, mode: String, result_name: String) -> void:
	if ev == null:
		return
	set_field(ev, "Mode", mode)
	var fld := change_name_field(mode)
	set_field(ev, fld, result_name)
	# 另外两个 ChangeName* 也保持合法（SlimeStorm 会校验）
	if fld != "ChangeNameEmitter":
		_ensure_valid_member(ev, "ChangeNameEmitter", RESULT_EMITTER)
	if fld != "ChangeNameBullet":
		_ensure_valid_member(ev, "ChangeNameBullet", RESULT_BULLET)
	if fld != "ChangeNameAffecter":
		_ensure_valid_member(ev, "ChangeNameAffecter", RESULT_AFFECTER)
	var idx: int = result_names(mode).find(result_name)
	set_field(ev, "changename", str(maxi(0, idx)))

func _ensure_valid_member(ev: XNode, field: String, allowed: PackedStringArray) -> void:
	var cur := get_field(ev, field, "")
	if allowed.has(cur):
		return
	set_field(ev, field, allowed[0])

## 事件结果属性名（按 Mode 从对应字段读）
func event_result_name(ev: XNode) -> String:
	var mode := get_field(ev, "Mode", "Emitter")
	return get_field(ev, change_name_field(mode), result_names(mode)[0])

func add_event_group(node: XNode, is_bullet_event: bool) -> XNode:
	if node == null:
		return null
	var lst_name := group_list_name(is_bullet_event)
	var lst := node.child(lst_name)
	if lst == null:
		lst = node.add_child_named(lst_name)
	var g := lst.add_child_named(group_node_name(is_bullet_event))
	g.add_child_named("Loop", "false")
	g.add_child_named("LoopCircle", "0")
	g.add_child_named("EventList")
	dirty = true
	return g

func add_event(group: XNode, is_bullet_event: bool) -> XNode:
	if group == null:
		return null
	var el := group.child("EventList")
	if el == null:
		el = group.add_child_named("EventList")
	var ev := new_event("Bullet" if is_bullet_event else "Emitter")
	el.children.append(ev)
	ev.parent = el
	dirty = true
	return ev

func delete_event(group: XNode, ev: XNode) -> void:
	if group == null or ev == null:
		return
	var el := group.child("EventList")
	if el != null:
		el.remove_child(ev)
	dirty = true

func delete_group(node: XNode, is_bullet_event: bool, group: XNode) -> void:
	if node == null or group == null:
		return
	var lst := node.child(group_list_name(is_bullet_event))
	if lst != null:
		lst.remove_child(group)
	dirty = true

# ------------------------------------------------------------------ 统计

func summary() -> Dictionary:
	return {
		"path": source_path,
		"version": top_field("version", "?"),
		"max_time": get_i(root, "MaxTime", 0) if root != null else 0,
		"loop": top_field("Loop", "false") == "true",
		"emitters": emitter_count(),
		"dirty": dirty,
	}
