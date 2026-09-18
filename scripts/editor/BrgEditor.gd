class_name BrgEditor
extends Control
## DanmakuForge「弹幕锻坊」主界面（.brg 可视化弹幕编辑器）
##
## 启动方式：
##   · Godot 编辑器里直接 F6 运行 `res://scenes/DanmakuForge.tscn`
##   · 命令行：`DanmakuForge.exe --open [可选.brg路径]`（旧名 `--brg-editor` 仍兼容）
##
## ================================================================== 设计要点
##
## **双层模型**：画布/属性面板/结构树改的每一处都走 `BrgDocument`（无损 XML 层），
## 只有播放预览用 `BrgLoader` + `BrgPlayback`（语义层）。这样 `BrgLoader`
## 不识别的字段不会因为一次保存而丢失，保持 SlimeStorm 双向兼容。
##
## **删除 = 语义 A**：只删发射器（弹幕团），不删单颗子弹（`.brg` 无单弹实体）。
##
## 画布坐标 == `.brg` 设计坐标（780×960，`Playfield.SCALE = 1`），无需换算。

static var pending_path := ""     ## 由 Cli autoload 在切场景前设置
static var pending_open_events := false   ## --events：打开后自动弹出事件编辑器
static var pending_autoplay := false      ## --play：打开后自动播放（截图/调试用）

const FIELD_W := 780.0
const FIELD_H := 960.0
const MAX_UNDO := 60
## 编辑器预览用的弹池容量。游戏里是 8192；预览缩小是为了让「重放」便宜一些。
## 池满会丢弹，届时帧标签会提示「弹池满」。
const PREVIEW_CAPACITY := 4096
## 拖动 gizmo 时的**预览防抖**（ms）：连续拖动期间**不做重放**，
## 停手/松手后才重放一次。原因（实测分解，37 发射器 / 300 帧）：
##   序列化 27 ms + 解析 28 ms + 模拟 175 ms ≈ 230 ms —— 每帧做一次必然卡死。
## gizmo 本身每帧都跟手（queue_redraw 不受影响），所以手感仍然是 60fps。
const PREVIEW_DRAG_DEBOUNCE_MS := 140

## 自机小球键盘移动速度（设计 px/s）；参考实现在 384 宽场地上用 220
const PLAYER_SPEED := 220.0

# ------------------------------------------------------------------ 字段规格
# {tag, label, type, group, step, min, max}
# type: int / float / bool / string / angle / vec / layer / intlist
# 覆盖 EmitterBullet 的全部 93 个字段（容器 EventGroupList/BulletEventGroupList
# 由事件编辑器负责，不在属性面板里当标量）。保真层已保留全部字段，这里只是放开 UI。
const FIELD_SPECS: Array = [
	# --- 基本 ---
	{"tag": "Tag", "label": "标签", "type": "string", "group": "基本"},
	{"tag": "ID", "label": "编号", "type": "int", "group": "基本", "min": 0, "max": 999999},
	{"tag": "EmitterType", "label": "发射器类型", "type": "string", "group": "基本"},
	{"tag": "StartTime", "label": "起始时间(帧)", "type": "int", "group": "基本", "min": 0, "max": 999999},
	{"tag": "Duration", "label": "持续时间(帧)", "type": "int", "group": "基本", "min": 0, "max": 999999},
	{"tag": "Disabled", "label": "停用", "type": "bool", "group": "基本"},
	{"tag": "HiRes", "label": "2x 贴图", "type": "bool", "group": "基本"},

	# --- 发射器运动（发射器自身，与子弹无关） ---
	{"tag": "Velocity", "label": "自身速度", "type": "float", "group": "发射器运动"},
	{"tag": "Direction", "label": "自身方向(°)", "type": "float", "group": "发射器运动"},
	{"tag": "Accelerate", "label": "自身加速度", "type": "float", "group": "发射器运动"},
	{"tag": "AccDirection", "label": "自身加速度方向(°)", "type": "float", "group": "发射器运动"},

	# --- 发射几何 ---
	{"tag": "EmitPoint", "label": "发射点坐标", "type": "vec", "group": "发射几何"},
	{"tag": "EmitDirection", "label": "发射角度(°)", "type": "angle", "group": "发射几何"},
	{"tag": "Way", "label": "条数", "type": "int", "group": "发射几何", "min": 1, "max": 512},
	{"tag": "Range", "label": "范围(°)", "type": "float", "group": "发射几何", "min": 0, "max": 360},
	{"tag": "Circle", "label": "周期(帧)", "type": "int", "group": "发射几何", "min": 1, "max": 9999},
	{"tag": "Count", "label": "层数", "type": "int", "group": "发射几何", "min": 1, "max": 64},
	{"tag": "DeltaV", "label": "层差速度", "type": "float", "group": "发射几何"},
	{"tag": "DeltaA", "label": "层差角度(°)", "type": "float", "group": "发射几何"},
	{"tag": "EmitRadius", "label": "发射半径", "type": "float", "group": "发射几何", "min": 0},
	{"tag": "RadiusDirection", "label": "半径方向(°)", "type": "angle", "group": "发射几何"},
	{"tag": "RDirectionFollowsEDirection", "label": "半径方向=发射角度", "type": "bool", "group": "发射几何"},
	{"tag": "Layer", "label": "渲染层", "type": "layer", "group": "发射几何"},
	{"tag": "EmitTimeList", "label": "额外发射时间点", "type": "intlist", "group": "发射几何"},
	{"tag": "SpecifySE", "label": "指定音效", "type": "bool", "group": "发射几何"},

	# --- 随机（发射器） ---
	{"tag": "RanVelocity", "label": "随机 自身速度", "type": "float", "group": "随机"},
	{"tag": "RanDirection", "label": "随机 自身方向", "type": "float", "group": "随机"},
	{"tag": "RanAccelerate", "label": "随机 自身加速度", "type": "float", "group": "随机"},
	{"tag": "RanAccDirection", "label": "随机 自身加速度方向", "type": "float", "group": "随机"},
	{"tag": "RanX", "label": "随机 X 偏移", "type": "float", "group": "随机"},
	{"tag": "RanY", "label": "随机 Y 偏移", "type": "float", "group": "随机"},
	{"tag": "RanRadius", "label": "随机 半径", "type": "float", "group": "随机"},
	{"tag": "RanRadiusDirection", "label": "随机 半径方向", "type": "float", "group": "随机"},
	{"tag": "RanWay", "label": "随机 条数", "type": "int", "group": "随机", "min": 0},
	{"tag": "RanCircle", "label": "随机 周期", "type": "int", "group": "随机", "min": 0},
	{"tag": "RanEmitDirection", "label": "随机 发射角度", "type": "float", "group": "随机"},
	{"tag": "RanRange", "label": "随机 范围", "type": "float", "group": "随机"},

	# --- 粒子 ---
	{"tag": "TextureName", "label": "贴图名", "type": "string", "group": "粒子"},
	{"tag": "LifeTime", "label": "生命(帧)", "type": "int", "group": "粒子", "min": 1, "max": 999999},
	{"tag": "BulletVelocity", "label": "粒子速度(px/帧)", "type": "float", "group": "粒子"},
	{"tag": "BulletDirection", "label": "粒子方向(°)", "type": "float", "group": "粒子"},
	{"tag": "BulletAccelerate", "label": "粒子加速度", "type": "float", "group": "粒子"},
	{"tag": "BulletAccDirection", "label": "粒子加速度方向(°)", "type": "float", "group": "粒子"},
	{"tag": "ScaleWidth", "label": "宽度缩放", "type": "float", "group": "粒子", "min": 0},
	{"tag": "ScaleHeight", "label": "高度缩放", "type": "float", "group": "粒子", "min": 0},
	{"tag": "ScaleWidthEqualsScaleHeight", "label": "宽高缩放相等", "type": "bool", "group": "粒子"},
	{"tag": "ScaleX", "label": "ScaleX", "type": "float", "group": "粒子"},
	{"tag": "ScaleY", "label": "ScaleY", "type": "float", "group": "粒子"},
	{"tag": "Transparent", "label": "透明度", "type": "int", "group": "粒子", "min": 0, "max": 255},
	{"tag": "ColorValue", "label": "颜色(ARGBColor:a:r:g:b)", "type": "string", "group": "粒子"},
	{"tag": "Angle", "label": "贴图旋转(°)", "type": "float", "group": "粒子"},
	{"tag": "AngleFollowsDirection", "label": "贴图跟随速度方向", "type": "bool", "group": "粒子"},
	{"tag": "AngularVelocity", "label": "角速度(°/帧)", "type": "float", "group": "粒子"},
	{"tag": "ColorType", "label": "颜色类型", "type": "string", "group": "粒子"},
	{"tag": "ParaA", "label": "参数 A", "type": "float", "group": "粒子"},
	{"tag": "ParaB", "label": "参数 B", "type": "float", "group": "粒子"},

	# --- 随机（粒子） ---
	{"tag": "RanBulletAngle", "label": "随机 贴图旋转", "type": "float", "group": "粒子随机"},
	{"tag": "RanBulletVelocity", "label": "随机 粒子速度", "type": "float", "group": "粒子随机"},
	{"tag": "RanBulletDirection", "label": "随机 粒子方向", "type": "float", "group": "粒子随机"},
	{"tag": "RanBulletAccelerate", "label": "随机 粒子加速度", "type": "float", "group": "粒子随机"},
	{"tag": "RanBulletAccDirection", "label": "随机 粒子加速度方向", "type": "float", "group": "粒子随机"},

	# --- 行为 ---
	{"tag": "Blend", "label": "混合模式", "type": "string", "group": "行为"},
	{"tag": "BeginningEffect", "label": "出弹特效", "type": "string", "group": "行为"},
	{"tag": "BeginMode", "label": "出弹模式", "type": "string", "group": "行为"},
	{"tag": "EndingEffect", "label": "消弹特效", "type": "string", "group": "行为"},
	{"tag": "Ghosting", "label": "残影", "type": "bool", "group": "行为"},
	{"tag": "GhostingCount", "label": "残影数量", "type": "int", "group": "行为", "min": 0, "max": 64},
	{"tag": "OutBound", "label": "出屏即消", "type": "bool", "group": "行为"},
	{"tag": "Protect100", "label": "前100帧不出屏销毁", "type": "bool", "group": "行为"},
	{"tag": "UnRemoveable", "label": "不可被消除", "type": "bool", "group": "行为"},
	{"tag": "Reflect", "label": "反弹次数", "type": "int", "group": "行为", "min": 0},
	{"tag": "ReflectEdges", "label": "反弹边", "type": "string", "group": "行为"},
	{"tag": "Region", "label": "判定区域", "type": "float", "group": "行为", "min": 0},
	{"tag": "VisualSize", "label": "视觉判定尺寸", "type": "float", "group": "行为", "min": 0},
	{"tag": "Affect", "label": "受影响器", "type": "bool", "group": "行为"},
	{"tag": "MotionLink", "label": "运动链接", "type": "bool", "group": "行为"},

	# --- 闪烁 ---
	{"tag": "TwinkleCycle", "label": "闪烁周期", "type": "int", "group": "闪烁", "min": 0},
	{"tag": "TwinkleDestColor", "label": "闪烁目标色", "type": "string", "group": "闪烁"},
	{"tag": "TwinkleMode", "label": "闪烁模式", "type": "string", "group": "闪烁"},

	# --- 背图 ---
	{"tag": "BackImageBlendMode", "label": "背图混合模式", "type": "string", "group": "背图"},
	{"tag": "BackImageColor", "label": "背图颜色", "type": "string", "group": "背图"},
	{"tag": "BackImageTransparent", "label": "背图透明度", "type": "int", "group": "背图", "min": 0, "max": 255},
	{"tag": "BackImageScale", "label": "背图缩放", "type": "float", "group": "背图", "min": 0},
	{"tag": "BackImageTwinkleCycle", "label": "背图闪烁周期", "type": "int", "group": "背图", "min": 0},
	{"tag": "BackImageTwinkleDestTrans", "label": "背图闪烁目标透明", "type": "int", "group": "背图", "min": 0, "max": 255},
	{"tag": "BackImageTwinkleMode", "label": "背图闪烁模式", "type": "string", "group": "背图"},

	# --- 绑定 / 宿主 ---
	{"tag": "Position", "label": "宿主偏移", "type": "vec", "group": "绑定"},
	{"tag": "BindingID", "label": "绑定 ID(-1=无)", "type": "int", "group": "绑定", "min": -1},
	{"tag": "DeepBinding", "label": "深度绑定", "type": "bool", "group": "绑定"},
	{"tag": "BindWithDirection", "label": "随方向绑定", "type": "bool", "group": "绑定"},
	{"tag": "DeathBinding", "label": "宿主死亡解绑", "type": "bool", "group": "绑定"},
]

# ------------------------------------------------------------------ 状态

var doc: BrgDocument = null
var bullets: Node = null
var playback = null
var canvas: BrgCanvas = null
var timeline: BrgTimeline = null
var event_editor: BrgEventEditor = null
var _sup_history: Array = []       ## 压制操作的撤销历史（键字符串）
var _clipboard: Array = []         ## 复制/粘贴：深拷贝的发射器节点（XNode）
var canvas_split: VSplitContainer = null
var tree: Tree = null
var tree_title: Label = null
var prop_box: VBoxContainer = null
var status: Label = null
var frame_label: Label = null

var selected: Array = []          # Array[int]
var playing := false
var frame := 0
var fixed_seed := 20260911
## 播放用**真实时间累加器**：编辑器 `_process` 是每渲染帧一次，而本工程关了 vsync
## （`window/vsync/vsync_mode=0`）→ 不累加就会以渲染帧率推进（远超 60，看起来「极快」）。
## 按 1/60 s 累加，卡顿后最多补 30 帧，保证观感就是设计的 60fps。
var _play_accum := 0.0
var host_origin := Vector2(FIELD_W * 0.5, 240.0)
var _undo: Array = []
var _redo: Array = []
var _pending_undo := ""            ## 拖拽开始时抓的快照；真发生改动才提交进撤销栈
var _needs_reload := false
var _drag_active := false
var _reload_due_ms := 0            ## 最后一次改动的时间（防抖基准）
var _last_reload_ms := 0
var _preview_dropped := 0          ## 上次重放因弹池满丢掉的弹数
var _suspend_widgets := false
var _field_widgets: Array = []     # [{tag, type, node, extra}]

class PlayHost:
	extends Node2D
	var origin := Vector2(390, 240)
	## 自机位置：画布叠层可拖动，方向键/WASD 可移动；播放层发射「自机狙」时读取。
	## 2026-09-17：内部按设计坐标存（gizmo 用），对外返回世界坐标（BrgPlayback 瞄准用）。
	var player_pos := Vector2(390.0, 800.0)
	func get_player_pos() -> Vector2:
		return player_pos * Playfield.SCALE

var _play_host: PlayHost = null

# ------------------------------------------------------------------ 生命周期

func _ready() -> void:
	_configure_window()
	_build_ui()
	if pending_path != "":
		_open_path(pending_path)
		pending_path = ""
		if pending_open_events:
			pending_open_events = false
			_open_event_editor()
	else:
		_update_status()
	if pending_autoplay:
		pending_autoplay = false
		if playback != null:
			playing = true

## 编辑器要真实像素排版，但**本机可用工作区只有 1600×952**（实测），
## 780×960 的战场 + 结构树 + 属性栏 + 时间轴必然放不下。
## 解法：逻辑排版尺寸固定为 `LOGICAL_W × LOGICAL_H`，交给 Godot 的
## canvas_items 拉伸整体缩放 —— 这样**输入坐标由引擎自动换算**，
## 不需要自己处理缩放后的鼠标映射（自己缩放 SubViewport 很容易搞错）。
const LOGICAL_W := 1580
const LOGICAL_H := 1240

func _configure_window() -> void:
	if DisplayServer.get_name() == "headless":
		return                       # 无头自检时不动窗口
	var w := get_window()
	if w == null:
		return
	# 子窗口内嵌：事件编辑器等 Window 画在主窗口里，而不是另开一个系统窗口。
	# 工具类应用这样更顺手，也让截图能拍到（否则截主视口拍不到独立窗口）。
	get_tree().root.gui_embed_subwindows = true
	w.title = "DanmakuForge 弹幕锻坊 — .brg 可视化弹幕编辑器"
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	w.content_scale_size = Vector2i(LOGICAL_W, LOGICAL_H)
	# KEEP：等比缩放并居中，逻辑排版尺寸恒定 —— 版面可预测，
	# 不会因为屏幕变宽就把属性栏拉得很难看。代价是屏幕比例不匹配时左右有黑边。
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	# 物理窗口贴合屏幕可用区域（留一点边距给标题栏/任务栏）
	var wa := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var want := Vector2i(LOGICAL_W, LOGICAL_H)
	var margin := 40
	want.x = mini(want.x, maxi(640, wa.size.x - margin))
	want.y = mini(want.y, maxi(480, wa.size.y - margin))
	w.size = want
	w.position = wa.position + Vector2i(
		maxi(0, (wa.size.x - want.x) / 2), maxi(0, (wa.size.y - want.y) / 2))
	# 让分辨率不匹配这件事是可见的，而不是让用户觉得「字怎么这么小」
	var eff: float = minf(float(want.x) / float(LOGICAL_W), float(want.y) / float(LOGICAL_H))
	print("[BrgEditor] 逻辑 %dx%d → 物理 %dx%d（屏幕可用 %dx%d，缩放 %.2f×）" % [
		LOGICAL_W, LOGICAL_H, want.x, want.y, wa.size.x, wa.size.y, eff])

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# 工具栏控件很多，逻辑宽度 1580 放不下。若直接把 HBox 塞进 VBox，它的最小宽度
	# 会把整个根布局撑宽到 1900+，导致右半屏（属性栏控件、叠层开关）被裁掉。
	# 用横向 ScrollContainer 包住：工具栏可横向滚动，最小宽度不再向上传播。
	var bar_wrap := ScrollContainer.new()
	bar_wrap.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	bar_wrap.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bar_wrap.custom_minimum_size = Vector2(0, 38)
	bar_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(bar_wrap)
	bar_wrap.add_child(_build_topbar())

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)

	# 左：结构树
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(330, 0)
	var lt := Label.new()
	lt.text = "结构树"
	tree_title = lt                 # 保存引用：不要用 get_node_or_null 猜路径
	left.add_child(lt)
	tree = Tree.new()
	tree.columns = 2
	tree.set_column_title(0, "发射器")
	tree.set_column_title(1, "几何")
	tree.hide_root = true
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.item_selected.connect(_on_tree_selected)
	tree.multi_selected.connect(_on_tree_multi_selected)
	left.add_child(tree)
	split.add_child(left)

	# 中：战场（SubViewport 便于裁剪子弹）+ 时间轴
	var center := VSplitContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var svc := SubViewportContainer.new()
	svc.stretch = false
	svc.custom_minimum_size = Vector2(FIELD_W, FIELD_H)
	svc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER   # 战场保持 780×960，不被拉宽
	var sv := SubViewport.new()
	sv.size = Vector2i(int(FIELD_W), int(FIELD_H))
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svc.add_child(sv)
	center.add_child(svc)
	split.add_child(center)

	var field_root := Node2D.new()
	field_root.name = "FieldRoot"
	sv.add_child(field_root)

	# 场地底色放在最底层（z_index=-10，低于子弹的 10）。BrgCanvas 只画叠层，
	# 不能再自己填不透明底色——否则会把子弹（z_index=10 < 20）整块盖住。
	var field_bg := ColorRect.new()
	field_bg.color = BrgCanvas.C_BG
	field_bg.size = Vector2(FIELD_W, FIELD_H)
	field_bg.z_index = -10
	field_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	field_root.add_child(field_bg)

	_play_host = PlayHost.new()
	field_root.add_child(_play_host)

	# 2026-09-17（390×480 改造）：BrgPlayback 输出世界坐标/尺寸（390×480），画布与文档
	# 仍是 780×960 设计空间 → 这里用 **Node2D** 承载 BulletManager 并 scale = 1/SCALE（=2×）。
	# 注意不能再用 load(...).new()（那是纯 Node：CanvasItem 父链断裂，MultiMesh 不继承变换，
	# 子弹会缩在左上角且尺寸不变）。
	var bm_script: GDScript = load("res://scripts/core/BulletManager.gd")
	bullets = Node2D.new()
	bullets.set_script(bm_script)
	bullets.name = "BulletManager"
	bullets.capacity = PREVIEW_CAPACITY   # 必须在 add_child 之前设置：_ready() 按它建数组
	bullets.collision_enabled = false     # 编辑器不跑碰撞：省掉每帧一次全池扫描
	bullets.scale = Vector2.ONE / Playfield.SCALE   # 世界 → 设计空间（显示与游戏内一致）
	field_root.add_child(bullets)

	canvas = BrgCanvas.new()
	canvas.name = "Canvas"
	canvas.z_index = 20          # 叠层必须盖过子弹（子弹 z_index = 10）
	canvas.host_origin = host_origin
	canvas.bullets = bullets
	canvas.play_host = _play_host
	canvas.bullet_pick_requested.connect(_on_bullet_pick)
	canvas.emitter_clicked.connect(_on_canvas_click)
	canvas.empty_clicked.connect(_on_canvas_empty)
	canvas.box_selected.connect(_on_canvas_box)
	canvas.drag_started.connect(_on_canvas_drag_started)
	canvas.drag_finished.connect(_on_canvas_drag_finished)
	canvas.emitter_changed.connect(_on_canvas_emitter_changed)
	sv.add_child(canvas)

	# 时间轴（P1）：一个发射器一条轨
	canvas_split = center
	timeline = BrgTimeline.new()
	timeline.name = "Timeline"
	timeline.custom_minimum_size = Vector2(400, 170)
	timeline.emitter_selected.connect(_on_timeline_selected)
	timeline.scrub.connect(_on_timeline_scrub)
	timeline.drag_started.connect(_on_canvas_drag_started)
	timeline.drag_finished.connect(_on_canvas_drag_finished)
	timeline.edited.connect(_on_timeline_edited)
	timeline.copy_requested.connect(_on_copy_pressed)
	timeline.paste_requested.connect(_on_paste_pressed)
	center.add_child(timeline)

	# 右：属性
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(440, 0)
	var rt := Label.new()
	rt.text = "属性"
	right.add_child(rt)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(scroll)
	prop_box = VBoxContainer.new()
	prop_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(prop_box)
	split.add_child(right)

	status = Label.new()
	status.clip_text = true
	root.add_child(status)

	_build_property_panel()

func _build_topbar() -> Control:
	var bar := HBoxContainer.new()
	var file_lbl := Label.new()
	file_lbl.text = "文件"
	bar.add_child(file_lbl)
	bar.add_child(_btn("打开", _on_open_pressed))
	bar.add_child(_btn("保存", _on_save_pressed))
	bar.add_child(_btn("另存为", _on_save_as_pressed))

	bar.add_child(VSeparator.new())
	var em_lbl := Label.new()
	em_lbl.text = "发射器"
	bar.add_child(em_lbl)
	bar.add_child(_btn("新建", _on_add_pressed))
	bar.add_child(_btn("删除", _on_delete_pressed))
	bar.add_child(_btn("克隆", _on_clone_pressed))

	bar.add_child(VSeparator.new())
	var ed_lbl := Label.new()
	ed_lbl.text = "编辑"
	bar.add_child(ed_lbl)
	bar.add_child(_btn("撤销", _on_undo_pressed))
	bar.add_child(_btn("重做", _on_redo_pressed))

	bar.add_child(VSeparator.new())
	bar.add_child(_btn("▶ 播放", _on_play_pressed))
	bar.add_child(_btn("⏸ 暂停", _on_pause_pressed))
	bar.add_child(_btn("⏭ 单帧", _on_step_pressed))
	bar.add_child(_btn("⏮ 复位", _on_restart_pressed))
	frame_label = Label.new()
	frame_label.text = "帧 0"
	bar.add_child(frame_label)

	bar.add_child(VSeparator.new())
	bar.add_child(_btn("时间轴", _toggle_timeline))
	bar.add_child(_btn("适配", _on_fit_timeline))
	bar.add_child(_btn("事件…", _open_event_editor))
	bar.add_child(VSeparator.new())
	bar.add_child(_btn("删除单弹", _toggle_pick_bullet))
	bar.add_child(_btn("撤销压制", _undo_last_suppress))
	bar.add_child(_btn("清空压制", _clear_suppress))
	bar.add_child(_btn("存压制", _save_suppress_patch))

	bar.add_child(VSeparator.new())
	var hl := Label.new()
	hl.text = "宿主"
	bar.add_child(hl)
	bar.add_child(_spin_host("X", true))
	bar.add_child(_spin_host("Y", false))

	bar.add_child(VSeparator.new())
	var cl := Label.new()
	cl.text = "叠层"
	bar.add_child(cl)
	var cb_g := CheckBox.new()
	cb_g.text = "网格"
	cb_g.button_pressed = true
	cb_g.toggled.connect(func(v): canvas.show_grid = v; canvas.queue_redraw())
	bar.add_child(cb_g)
	var cb_l := CheckBox.new()
	cb_l.text = "标签"
	cb_l.button_pressed = true
	cb_l.toggled.connect(func(v): canvas.show_labels = v; canvas.queue_redraw())
	bar.add_child(cb_l)
	var cb_s := CheckBox.new()
	cb_s.text = "吸附"
	cb_s.tooltip_text = "移动发射器时吸附到 60px 网格"
	cb_s.button_pressed = false
	cb_s.toggled.connect(func(v): canvas.snap_grid = v)
	bar.add_child(cb_s)
	return bar

func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	return b

func _spin_host(axis: String, is_x: bool) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = -2000
	s.max_value = 3000
	s.step = 1
	s.value = host_origin.x if is_x else host_origin.y
	s.custom_minimum_size = Vector2(80, 0)
	s.value_changed.connect(func(v):
		if is_x:
			host_origin.x = v
		else:
			host_origin.y = v
		canvas.host_origin = host_origin
		canvas.queue_redraw()
		_reload_playback(frame))
	return s

# ------------------------------------------------------------------ 打开 / 保存

func _on_open_pressed() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.brg ; SlimeStorm 弹幕工程"])
	fd.size = Vector2i(900, 600)
	fd.file_selected.connect(func(p): _open_path(p); fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	add_child(fd)
	fd.popup_centered()

func _open_path(path: String) -> void:
	var d := BrgDocument.load_file(path)
	if d == null:
		_set_status("❌ 打不开：%s" % path)
		return
	doc = d
	_undo.clear()
	_redo.clear()
	canvas.set_document(doc)
	timeline.set_document(doc)      # 内部会 fit()；布局没完则靠 resized 自动补上
	# 默认选中第一个发射器：一打开属性面板就有东西可改，而不是空着
	selected = [0] if doc.emitter_count() > 0 else []
	_refresh_tree()
	canvas.set_selected(selected)
	_build_property_panel()
	_reload_playback(0)
	# 载入单弹压制补丁（sidecar，不改 .brg）
	var sup_loaded := 0
	if playback != null and doc.source_path != "":
		if playback.load_patch(doc.source_path):
			sup_loaded = _sup_count()
	if sup_loaded > 0:
		_reload_playback(0)
	if not selected.is_empty():
		_set_status(_selection_description())
	else:
		_set_status("已打开 %s — 没有子弹发射器" % path.get_file())
	if sup_loaded > 0:
		_set_status("已载入压制补丁：%d 发单弹被压制（.brg 未被改动）" % sup_loaded)
	print("[BrgEditor] 打开 %s：%d 发射器，初始选中 %s，时间轴 %.4f px/帧" % [
		path.get_file(), doc.emitter_count(), str(selected), timeline.px_per_frame])

func _on_save_pressed() -> void:
	if doc == null:
		return
	if doc.source_path == "" or doc.source_path.begins_with("res://"):
		_on_save_as_pressed()
		return
	if doc.save():
		var extra := ""
		if playback != null and _sup_count() > 0:
			if playback.save_patch(doc.source_path):
				extra = "；压制补丁 %d 发" % _sup_count()
		_set_status("✅ 已保存 %s（无损保留未编辑字段）%s" % [
			doc.source_path.get_file(), extra])
	else:
		_set_status("❌ 保存失败")

func _on_save_as_pressed() -> void:
	if doc == null:
		return
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = PackedStringArray(["*.brg ; SlimeStorm 弹幕工程"])
	fd.current_file = "new_barrage.brg"
	fd.size = Vector2i(900, 600)
	fd.file_selected.connect(func(p):
		if not p.to_lower().ends_with(".brg"):
			p += ".brg"
		if doc.save(p):
			_set_status("✅ 已另存为 %s" % p)
		else:
			_set_status("❌ 另存失败")
		fd.queue_free())
	fd.canceled.connect(func(): fd.queue_free())
	add_child(fd)
	fd.popup_centered()

# ------------------------------------------------------------------ 结构树

func _refresh_tree() -> void:
	tree.clear()
	var root_item := tree.create_item()
	if tree_title != null:
		tree_title.text = "结构树（%d 个发射器）" % (
			0 if doc == null else doc.emitter_count())
	if doc == null:
		return
	for i in doc.emitter_nodes().size():
		var n: BrgDocument.XNode = doc.emitter_nodes()[i]
		var it := tree.create_item(root_item)
		var tag := doc.get_field(n, "Tag", "")
		var disabled := doc.get_b(n, "Disabled", false)
		it.set_text(0, "%d  %s%s" % [i, tag if tag != "" else "(无标签)",
			"  [停用]" if disabled else ""])
		it.set_text(1, "Way %d · 周期 %d" % [
			doc.get_i(n, "Way", 1), doc.get_i(n, "Circle", 1)])
		it.set_metadata(0, i)
		if selected.has(i):
			it.select(0)
	tree.set_column_expand(0, true)
	tree.set_column_expand(1, false)
	tree.set_column_custom_minimum_width(1, 130)

func _on_tree_selected() -> void:
	var it := tree.get_selected()
	if it == null:
		return
	var i: int = it.get_metadata(0)
	selected = [i]
	_after_selection_changed()

func _on_tree_multi_selected(_item: TreeItem, _col: int, _sel: bool) -> void:
	var sel: Array = []
	var it := tree.get_next_selected(null)
	while it != null:
		sel.append(it.get_metadata(0))
		it = tree.get_next_selected(it)
	if not sel.is_empty():
		selected = sel
		_after_selection_changed()

func _on_canvas_click(index: int, additive: bool) -> void:
	if additive:
		if selected.has(index):
			selected.erase(index)
		else:
			selected.append(index)
	else:
		selected = [index]
	_sync_tree_selection()
	_after_selection_changed()

func _on_canvas_empty() -> void:
	selected.clear()
	_sync_tree_selection()
	_after_selection_changed()

func _on_canvas_box(indices: Array) -> void:
	selected = indices
	_sync_tree_selection()
	_after_selection_changed()

## 拖拽开始：先抓一份快照。**真正发生改动时**才提交进撤销栈，
## 这样「只点一下不拖」不会产生一个什么都不做的撤销步骤。
func _on_canvas_drag_started() -> void:
	_pending_undo = doc.to_text() if doc != null else ""
	_drag_active = true

## 松手：做一次**精确**重放（拖动中是防抖的，可能还是旧画面）
func _on_canvas_drag_finished() -> void:
	_drag_active = false
	_mark_dirty()

## 拖拽中改了属性：同步属性面板数值 + 结构树该行 + 触发预览重放
func _on_canvas_emitter_changed(index: int) -> void:
	if _pending_undo != "":
		_undo.append(_pending_undo)
		if _undo.size() > MAX_UNDO:
			_undo.pop_front()
		_redo.clear()
		_pending_undo = ""
	_needs_reload = true
	refresh_property_values()
	_update_tree_row(index)
	_reload_due_ms = Time.get_ticks_msec()
	_set_status("%s → %s" % [canvas.drag_hint(), _selection_description()])

func _sync_tree_selection() -> void:
	var root_item := tree.get_root()
	if root_item == null:
		return
	var it := root_item.get_first_child()
	while it != null:
		var i: int = it.get_metadata(0)
		if selected.has(i) and not it.is_selected(0):
			it.select(0)
		elif not selected.has(i) and it.is_selected(0):
			it.deselect(0)
		it = it.get_next()

func _after_selection_changed() -> void:
	canvas.set_selected(selected)
	if timeline != null:
		timeline.set_selected(selected)
		if not selected.is_empty():
			timeline.reveal(selected[0])
	_build_property_panel()
	_set_status(_selection_description())

func _selection_description() -> String:
	if selected.is_empty():
		return "未选中。点画布上的黄色手柄或结构树选中；Del 删除；拖拽手柄改位置。"
	if selected.size() == 1:
		var n: BrgDocument.XNode = doc.emitter_nodes()[selected[0]]
		var pos := canvas._emitter_canvas_pos(n)
		return "选中 #%d 「%s」 画布位置 (%.0f, %.0f) — %s" % [
			selected[0], doc.get_field(n, "Tag", "?"), pos.x, pos.y,
			"跟随宿主（改 Position）" if _is_self_ref(n) else "绝对发射点（改 EmitPoint）"]
	return "已选中 %d 个发射器（批量修改属性会同时写入全部）" % selected.size()

func _is_self_ref(n: BrgDocument.XNode) -> bool:
	var ep := doc.get_vec(n, "EmitPoint",
		Vector2(BrgDocument.SENTINEL_SELF, BrgDocument.SENTINEL_SELF))
	return ep.x <= BrgDocument.SENTINEL_SELF + 1.0 and ep.y <= BrgDocument.SENTINEL_SELF + 1.0

# ------------------------------------------------------------------ 属性面板

func _build_property_panel() -> void:
	for c in prop_box.get_children():
		c.queue_free()
	_field_widgets.clear()
	if doc == null or selected.is_empty():
		var l := Label.new()
		l.text = "（未选中发射器）" if doc != null else "（未打开 .brg）"
		prop_box.add_child(l)
		return

	var first: BrgDocument.XNode = doc.emitter_nodes()[selected[0]]
	var multi := selected.size() > 1
	var cur_group := ""
	for spec in FIELD_SPECS:
		if spec["group"] != cur_group:
			cur_group = spec["group"]
			var h := HSeparator.new()
			prop_box.add_child(h)
			var gl := Label.new()
			gl.text = "▍" + cur_group
			prop_box.add_child(gl)
		prop_box.add_child(_make_row(spec, first, multi))

func _make_row(spec: Dictionary, node: BrgDocument.XNode, multi: bool) -> Control:
	var row := HBoxContainer.new()
	var lab := Label.new()
	lab.text = spec["label"]
	lab.custom_minimum_size = Vector2(128, 0)
	row.add_child(lab)
	var tag: String = spec["tag"]
	var typ: String = spec["type"]
	_suspend_widgets = true

	match typ:
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = doc.get_b(node, tag, String(BrgDocument.DEFAULTS.get(tag, "false")) == "true")
			cb.toggled.connect(func(v): _apply_field(tag, v))
			row.add_child(cb)
			_field_widgets.append({"tag": tag, "type": typ, "node": cb})
		"string":
			var le := LineEdit.new()
			le.text = doc.get_field(node, tag, "")
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_submitted.connect(func(v): _apply_field(tag, v))
			le.focus_exited.connect(func(): _apply_field(tag, le.text))
			row.add_child(le)
			_field_widgets.append({"tag": tag, "type": typ, "node": le})
		"layer":
			var opt := OptionButton.new()
			var layers := ["Top", "Middle", "Bottom"]
			for i in layers.size():
				opt.add_item(layers[i], i)
			var cur := doc.get_field(node, tag, "Middle")
			opt.selected = maxi(0, layers.find(cur))
			opt.item_selected.connect(func(i): _apply_field(tag, layers[i]))
			row.add_child(opt)
			_field_widgets.append({"tag": tag, "type": typ, "node": opt})
		"intlist":
			# `<EmitTimeList><int>10</int>…</EmitTimeList>`：逗号/空格分隔的帧号
			var le := LineEdit.new()
			le.text = _int_list_text(node, tag)
			le.tooltip_text = "逗号或空格分隔的帧号，例如 1,25,50（清空=删除全部）"
			le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			le.text_submitted.connect(func(v): _apply_int_list(tag, v))
			le.focus_exited.connect(func(): _apply_int_list(tag, le.text))
			row.add_child(le)
			_field_widgets.append({"tag": tag, "type": "intlist", "node": le})
		"vec":
			# 注意：EmitPoint 的「自身」哨兵是 -99998，SpinBox 的 min_value 若不是
			# 足够小就会把它夹成 -3000（显示错误，且一转就写坏数据）。故放开范围。
			var sp := SpinBox.new()
			sp.min_value = -100000
			sp.max_value = 100000
			sp.step = 1
			sp.custom_minimum_size = Vector2(92, 0)
			var v := doc.get_vec(node, tag, Vector2.ZERO)
			sp.value = v.x
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp.value_changed.connect(func(val):
				var nv := doc.get_vec(node, tag, Vector2.ZERO)
				nv.x = val
				_apply_vec(tag, nv))
			row.add_child(sp)
			var sp2 := SpinBox.new()
			sp2.min_value = -100000
			sp2.max_value = 100000
			sp2.step = 1
			sp2.custom_minimum_size = Vector2(92, 0)
			sp2.value = v.y
			sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp2.value_changed.connect(func(val):
				var nv := doc.get_vec(node, tag, Vector2.ZERO)
				nv.y = val
				_apply_vec(tag, nv))
			row.add_child(sp2)
			if tag == "EmitPoint":
				var self_ref := _is_self_ref(node)
				# 跟随自身时锁住数字框：哨兵值不应被手改成普通坐标
				sp.editable = not self_ref
				sp2.editable = not self_ref
				sp.tooltip_text = "哨兵 -99998 = 跟随发射器自身" if self_ref else ""
				sp2.tooltip_text = sp.tooltip_text
				var self_cb := CheckBox.new()
				self_cb.text = "跟随自身"
				self_cb.tooltip_text = "勾选写 EmitPoint=-99998（跟随发射器）；取消写绝对坐标"
				self_cb.button_pressed = self_ref
				self_cb.toggled.connect(func(on):
					_apply_vec("EmitPoint",
						Vector2(BrgDocument.SENTINEL_SELF, BrgDocument.SENTINEL_SELF)
						if on else Vector2(FIELD_W * 0.5, 240.0)))
				row.add_child(self_cb)
				_field_widgets.append({"tag": tag, "type": typ, "node": self_cb, "extra": "selfref"})
			_field_widgets.append({"tag": tag, "type": "vecx", "node": sp})
			_field_widgets.append({"tag": tag, "type": "vecy", "node": sp2})
		"angle":
			var sp := SpinBox.new()
			sp.min_value = -100000
			sp.max_value = 100000
			sp.step = 1
			sp.value = doc.get_angle(node, tag, 0.0)
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp.value_changed.connect(func(val):
				if doc.angle_is_aim(node, tag):
					return          # 自机狙状态下不写数值
				_apply_angle(tag, val))
			row.add_child(sp)
			var aim_cb := CheckBox.new()
			aim_cb.text = "指向自机"
			aim_cb.button_pressed = doc.angle_is_aim(node, tag)
			aim_cb.toggled.connect(func(on):
				_apply_angle(tag,
					BrgDocument.SENTINEL_AIM if on else 90.0))
			row.add_child(aim_cb)
			_field_widgets.append({"tag": tag, "type": typ, "node": sp})
			_field_widgets.append({"tag": tag, "type": "aim", "node": aim_cb})
		_:
			var sp := SpinBox.new()
			sp.min_value = float(spec.get("min", -100000))
			sp.max_value = float(spec.get("max", 100000))
			sp.step = 1.0 if typ == "int" else 0.01
			if typ == "int":
				sp.value = doc.get_i(node, tag, 0)
			else:
				sp.value = doc.get_f(node, tag, 0.0)
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp.value_changed.connect(func(val):
				_apply_field(tag, int(val) if typ == "int" else val))
			row.add_child(sp)
			_field_widgets.append({"tag": tag, "type": typ, "node": sp})

	_suspend_widgets = false
	if multi:
		lab.modulate = Color(1, 1, 1, 0.75)
	return row

## 把一次编辑落到「全部选中项」上（批量修改）
func _apply_field(tag: String, value: Variant) -> void:
	if doc == null or _suspend_widgets:
		return
	_push_undo()
	for i in selected:
		doc.set_field(doc.emitter_nodes()[i], tag, value)
	_after_edit()

func _apply_vec(tag: String, v: Vector2) -> void:
	if doc == null or _suspend_widgets:
		return
	_push_undo()
	for i in selected:
		doc.set_vec(doc.emitter_nodes()[i], tag, v)
	_after_edit()

func _apply_angle(tag: String, v: float) -> void:
	if doc == null or _suspend_widgets:
		return
	_push_undo()
	for i in selected:
		doc.set_angle(doc.emitter_nodes()[i], tag, v)
	_after_edit()

func _int_list_text(node: BrgDocument.XNode, tag: String) -> String:
	var arr := doc.get_int_list(node, tag)
	var parts: Array[String] = []
	for v in arr:
		parts.append(str(v))
	return ", ".join(parts)

## 逗号/空格分隔的帧号 → EmitTimeList（对全部选中项写入同一份列表）
func _apply_int_list(tag: String, text: String) -> void:
	if doc == null or _suspend_widgets:
		return
	var norm := text.replace("，", ",").replace(" ", "").replace("\t", "")
	var vals: Array = []
	for p in norm.split(",", false):
		var s := p.strip_edges()
		if s.is_valid_int():
			vals.append(int(s))
	_push_undo()
	for i in selected:
		doc.set_int_list(doc.emitter_nodes()[i], tag, vals)
	_after_edit()

## 标记「预览需要重放」，并记录时间作为防抖基准
func _mark_dirty() -> void:
	_needs_reload = true
	_reload_due_ms = Time.get_ticks_msec()

func _after_edit() -> void:
	_mark_dirty()
	_refresh_tree()
	canvas.queue_redraw()
	if timeline != null:
		timeline.refresh()
	_update_status()

# ------------------------------------------------------------------ 数值就地刷新

## 拖拽 gizmo 时把属性面板的数值同步过来。
## 注意：**不重建控件**（重建会打断正在编辑的输入框/滚动位置），只就地改 value；
## 期间用 `_suspend_widgets` 抑制回写，避免把「面板刷新」误当成用户编辑。
func refresh_property_values() -> void:
	if doc == null or selected.is_empty():
		return
	var ems := doc.emitter_nodes()
	if selected[0] >= ems.size():
		return
	var node: BrgDocument.XNode = ems[selected[0]]
	_suspend_widgets = true
	for w in _field_widgets:
		var tag: String = w["tag"]
		var typ: String = w["type"]
		var ctrl = w["node"]
		if ctrl == null:
			continue
		match typ:
			"int":
				(ctrl as SpinBox).value = doc.get_i(node, tag, 0)
			"float":
				(ctrl as SpinBox).value = doc.get_f(node, tag, 0.0)
			"angle":
				(ctrl as SpinBox).value = doc.get_angle(node, tag, 0.0)
			"vecx":
				(ctrl as SpinBox).value = doc.get_vec(node, tag, Vector2.ZERO).x
			"vecy":
				(ctrl as SpinBox).value = doc.get_vec(node, tag, Vector2.ZERO).y
			"bool":
				(ctrl as CheckBox).button_pressed = doc.get_b(node, tag, false)
			"aim":
				(ctrl as CheckBox).button_pressed = doc.angle_is_aim(node, tag)
			"selfref":
				(ctrl as CheckBox).button_pressed = _is_self_ref(node)
			"string":
				var le := ctrl as LineEdit
				if not le.has_focus():        # 正在输入就别抢
					le.text = doc.get_field(node, tag, "")
			"intlist":
				var le2 := ctrl as LineEdit
				if not le2.has_focus():
					le2.text = _int_list_text(node, tag)
			"layer":
				var layers := ["Top", "Middle", "Bottom"]
				(ctrl as OptionButton).selected = maxi(0,
					layers.find(doc.get_field(node, tag, "Middle")))
	_suspend_widgets = false
	_refresh_emitpoint_lock(node)

## 「跟随自身」时锁住 EmitPoint 的数字框：
## 哨兵是 -99998，一旦被普通坐标覆盖，语义就没了。
func _refresh_emitpoint_lock(node: BrgDocument.XNode) -> void:
	var self_ref := _is_self_ref(node)
	for w in _field_widgets:
		if String(w["tag"]) != "EmitPoint":
			continue
		var t := String(w["type"])
		if t != "vecx" and t != "vecy":
			continue
		var sb := w["node"] as SpinBox
		if sb != null:
			sb.editable = not self_ref

## 只更新结构树里某一行的文字（拖拽时每帧调用，不能整棵树重建）
func _update_tree_row(index: int) -> void:
	if doc == null or tree == null:
		return
	var root_item := tree.get_root()
	if root_item == null:
		return
	var it := root_item.get_first_child()
	var i := 0
	while it != null:
		if i == index:
			var ems := doc.emitter_nodes()
			if index < ems.size():
				var n: BrgDocument.XNode = ems[index]
				var tag := doc.get_field(n, "Tag", "")
				it.set_text(0, "%d  %s%s" % [index, tag if tag != "" else "(无标签)",
					"  [停用]" if doc.get_b(n, "Disabled", false) else ""])
				it.set_text(1, "Way %d · 周期 %d" % [
					doc.get_i(n, "Way", 1), doc.get_i(n, "Circle", 1)])
			return
		i += 1
		it = it.get_next()

# ------------------------------------------------------------------ 时间轴

func _on_timeline_selected(index: int, additive: bool) -> void:
	if additive:
		if selected.has(index):
			selected.erase(index)
		else:
			selected.append(index)
	else:
		selected = [index]
	_sync_tree_selection()
	canvas.set_selected(selected)
	_build_property_panel()
	canvas.queue_redraw()
	_set_status(_selection_description())

func _on_timeline_scrub(f: int) -> void:
	playing = false
	_reload_playback(f)
	_set_status("已定位到第 %d 帧（时间轴）" % f)

func _on_timeline_edited(index: int) -> void:
	_needs_reload = true
	_reload_due_ms = Time.get_ticks_msec()
	_update_tree_row(index)
	canvas.queue_redraw()
	if index >= 0 and index < doc.emitter_count():
		var n: BrgDocument.XNode = doc.emitter_nodes()[index]
		_set_status("发射器 #%d：起始 %d 帧 · 持续 %d 帧%s" % [
			index, doc.get_i(n, "StartTime", 0), doc.get_i(n, "Duration", 0),
			"（不限时长）" if doc.get_i(n, "Duration", 0) <= 0 else ""])

func _on_fit_timeline() -> void:
	timeline.fit()
	_set_status("时间轴已适配整段长度（%d 帧）" % timeline.max_time)

func _toggle_timeline() -> void:
	timeline.visible = not timeline.visible
	_set_status("时间轴已%s（拖片段改起始时间，拖右边缘红线改持续时间，Ctrl+滚轮缩放）" % (
		"显示" if timeline.visible else "隐藏"))

# ------------------------------------------------------------------ 事件编辑器

func _open_event_editor() -> void:
	if doc == null or selected.is_empty():
		_set_status("先在结构树/画布选中一个发射器，再打开事件编辑器")
		return
	if event_editor == null:
		event_editor = BrgEventEditor.new()
		add_child(event_editor)
		event_editor.changed.connect(_on_events_changed)
	var ems := doc.emitter_nodes()
	var idx: int = selected[0]
	if idx < 0 or idx >= ems.size():
		return
	event_editor.open(doc, ems[idx])
	_set_status("事件编辑器：%s — 改事件会自动同步 changename 数字 ID" % (
		doc.get_field(ems[idx], "Tag", "?")))

func _on_events_changed() -> void:
	_mark_dirty()               # 事件改了 → 预览需要重放
	canvas.queue_redraw()
	if timeline != null:
		timeline.refresh()
	_update_status()

# ------------------------------------------------------------------ 单弹压制（P2 语义 B）

## 切换单弹拾取模式
func _toggle_pick_bullet() -> void:
	if doc == null:
		_set_status("先打开一个 .brg")
		return
	canvas.pick_bullet_mode = not canvas.pick_bullet_mode
	canvas._hover_slot = -1
	canvas.queue_redraw()
	if canvas.pick_bullet_mode:
		playing = false
		_set_status("单弹拾取：点画布上最近的一颗弹即压制它（不生成）。已压制 %d 发；"\
			% _sup_count() + "Ctrl+点击 = 撤销该弹的压制；Esc 退出")
	else:
		_set_status("已退出单弹拾取（已压制 %d 发）" % _sup_count())

func _sup_count() -> int:
	return (playback.suppressed as Dictionary).size() if playback != null else 0

## 画布点击 → 压制 / 取消压制最近的一颗弹
func _on_bullet_pick(pos: Vector2, additive: bool) -> void:
	if playback == null or bullets == null:
		_set_status("还没有预览播放器（先让弹幕跑起来）")
		return
	var s := Playfield.SCALE
	var slot: int = bullets.pick(pos.x * s, pos.y * s, BrgCanvas.PICK_RADIUS * s)
	if slot < 0:
		_set_status("这里没有可拾取的子弹（把鼠标靠近弹体再点）")
		return
	var ident: Array = bullets.identity_of(slot)
	if ident.size() != 3:
		_set_status("这颗弹不是 .brg 发射的（没有身份），无法压制")
		return
	var key := BrgPlayback.make_key(int(ident[0]), int(ident[1]), int(ident[2]))
	if additive or (playback.suppressed as Dictionary).has(key):
		# Ctrl/Shift 点击 = 撤销这颗弹的压制（也支持对已压制的直接再点）
		if (playback.suppressed as Dictionary).has(key):
			(playback.suppressed as Dictionary).erase(key)
			_set_status("已取消压制 %s（当前共 %d 发）" % [key, _sup_count()])
		else:
			_set_status("这颗弹本来就没被压制")
	elif additive:
		_set_status("这颗弹本来就没被压制")
	else:
		playback.suppressed[key] = true
		_sup_history.append(key)
		_set_status("已压制发射器 %d 第 %d 帧第 %d 发（共 %d 发）— 重放后它不会出现" % [
			ident[0], ident[1], ident[2], _sup_count()])
	# 重放以立刻看到效果
	_needs_reload = true
	_reload_due_ms = 0
	canvas.queue_redraw()

func _undo_last_suppress() -> void:
	if playback == null or _sup_history.is_empty():
		_set_status("没有可撤销的压制操作")
		return
	var k: String = _sup_history.pop_back()
	(playback.suppressed as Dictionary).erase(k)
	_needs_reload = true
	_reload_due_ms = 0
	canvas.queue_redraw()
	_set_status("已撤销压制 %s（剩余 %d 发）" % [k, _sup_count()])

func _clear_suppress() -> void:
	if playback == null or _sup_count() == 0:
		_set_status("当前没有压制记录")
		return
	playback.clear_suppressed()
	_sup_history.clear()
	_needs_reload = true
	_reload_due_ms = 0
	canvas.queue_redraw()
	_set_status("已清空全部单弹压制")

## 把压制补丁存到 `<xxx.brg>.patch.json`（**不改 .brg 本身**）
func _save_suppress_patch() -> void:
	if doc == null or playback == null:
		return
	if doc.source_path == "":
		_set_status("文档还没有路径，先保存 .brg 再存压制补丁")
		return
	if playback.save_patch(doc.source_path):
		_set_status("✅ 压制补丁已写入 %s（共 %d 发；.brg 本身未被改动）" % [
			BrgPlayback.patch_path_for(doc.source_path).get_file(), _sup_count()])
	else:
		_set_status("❌ 压制补丁写入失败（导出后的构建里 res:// 只读）")

# ------------------------------------------------------------------ 增删（语义 A）

func _on_add_pressed() -> void:
	if doc == null:
		return
	_push_undo()
	var first: BrgDocument.XNode = null
	if not selected.is_empty():
		first = doc.emitter_nodes()[selected[0]]
	# 新发射器继承当前选中项的粒子参数，位置略微偏移，符合「复制一个再改」的习惯
	var n := doc.add_emitter("Bullet%d" % doc.emitter_count())
	if first != null:
		for spec in FIELD_SPECS:
			var t: String = spec["tag"]
			if ["Tag", "ID", "StartTime", "Duration", "BindingID"].has(t):
				continue
			var c := first.child(t)
			if c == null:
				continue
			var dst := n.child(t)
			if dst == null:
				dst = n.add_child_named(t)
			dst.text = c.text
			dst.children.clear()
			for gc in c.children:
				var g2 := dst.add_child_named(gc.tag, gc.text)
				g2.attrs = gc.attrs.duplicate()
		var p := doc.get_vec(first, "Position", Vector2.ZERO)
		doc.set_vec(n, "Position", p + Vector2(60, 0))
	selected = [doc.emitter_count() - 1]
	_after_edit()
	_sync_tree_selection()
	_build_property_panel()
	_set_status("已新建发射器 #%d（继承自原选中项）" % selected[0])

func _on_clone_pressed() -> void:
	_on_add_pressed()

## 复制选中发射器到内部剪贴板（深拷贝，可反复粘贴）
func _on_copy_pressed() -> void:
	if doc == null or selected.is_empty():
		_set_status("没有选中发射器可复制")
		return
	_clipboard.clear()
	var ems := doc.emitter_nodes()
	for i in selected:
		if i >= 0 and i < ems.size():
			_clipboard.append(BrgDocument.clone_node(ems[i]))
	_set_status("已复制 %d 个发射器（Ctrl+V 粘贴）" % _clipboard.size())

## 把剪贴板里的发射器粘贴为新的发射器（新 ID / Tag 加 _copy 后缀）
func _on_paste_pressed() -> void:
	if doc == null:
		_set_status("先打开一个 .brg")
		return
	if _clipboard.is_empty():
		_set_status("剪贴板为空（先 Ctrl+C 复制）")
		return
	_push_undo()
	var made: Array = []
	for src in _clipboard:
		var n := doc.copy_emitter_into(src)
		if n != null:
			made.append(doc.emitter_nodes().find(n))
	selected = made
	_after_edit()
	_sync_tree_selection()
	_build_property_panel()
	_set_status("已粘贴 %d 个发射器（新 ID，已选中）" % made.size())

func _on_delete_pressed() -> void:
	if doc == null or selected.is_empty():
		_set_status("没有选中任何发射器（语义 A：只删发射器，不删单颗子弹）")
		return
	_push_undo()
	var ems := doc.emitter_nodes()
	var names: Array = []
	var all_refs: Array = []
	for i in selected.duplicate():
		if i < 0 or i >= ems.size():
			continue
		var n: BrgDocument.XNode = ems[i]
		names.append("#%d「%s」" % [i, doc.get_field(n, "Tag", "?")])
		var info := doc.delete_emitter(n)
		all_refs.append_array(info.get("referencing", []))
	selected.clear()
	_after_edit()
	_sync_tree_selection()
	_build_property_panel()
	var msg := "已删除 %d 个发射器：%s" % [names.size(), ", ".join(PackedStringArray(names))]
	if not all_refs.is_empty():
		msg += "  ⚠ 这些发射器的 BindingID 指向了被删的 ID，建议检查：" + ", ".join(PackedStringArray(all_refs))
	_set_status(msg)

# ------------------------------------------------------------------ 撤销 / 重做

func _push_undo() -> void:
	if doc == null:
		return
	_undo.append(doc.to_text())
	if _undo.size() > MAX_UNDO:
		_undo.pop_front()
	_redo.clear()

func _on_undo_pressed() -> void:
	if doc == null or _undo.is_empty():
		_set_status("没有可撤销的操作")
		return
	_redo.append(doc.to_text())
	_restore(_undo.pop_back())

func _on_redo_pressed() -> void:
	if doc == null or _redo.is_empty():
		_set_status("没有可重做的操作")
		return
	_undo.append(doc.to_text())
	_restore(_redo.pop_back())

func _restore(text: String) -> void:
	var path := doc.source_path
	var d := BrgDocument.parse_text(text)
	if d == null:
		return
	d.source_path = path
	d.dirty = true
	doc = d
	selected.clear()
	canvas.set_document(doc)
	# 撤销/重做会**整体替换** doc 对象：所有持有它的视图都必须重新指向新对象，
	# 否则时间轴会继续编辑那个已经被丢弃的旧文档（静默无效）。
	if timeline != null:
		timeline.set_document(doc)
		canvas_split.size = canvas_split.size          # 触发布局，保证时间轴拿到新尺寸
	_refresh_tree()
	_build_property_panel()
	_reload_playback(frame)
	_set_status("已恢复（撤销栈 %d / 重做栈 %d）" % [_undo.size(), _redo.size()])

# ------------------------------------------------------------------ 播放预览

func _reload_playback(at_frame: int) -> void:
	if doc == null or bullets == null:
		return
	# ⚠️ 重建播放器会丢掉压制列表，必须搬运过来（**先存再置 null**，
	# 否则下面的 if 永远为假，压制的弹会在重放后复活）：
	var old_suppressed: Dictionary = {}
	if playback != null:
		old_suppressed = (playback.suppressed as Dictionary).duplicate()
		playback = null
	bullets.clear()
	var dropped_before: int = bullets.dropped_total
	var brg = BrgLoader.load_text(doc.to_text())
	if brg == null:
		_set_status("⚠ 预览失败：当前 XML 无法被 BrgLoader 解析（不影响保存）")
		return
	seed(fixed_seed)                     # 固定种子 → 逐帧可复现（Replay 同款做法）
	var _pb = BrgPlayback.new(brg, bullets, _play_host)
	# 宿主位置：编辑器内 host_origin 是设计坐标 → ×SCALE 转世界喂给播放层
	_pb.origin_callable = func() -> Vector2: return Playfield.vec(host_origin)
	_pb.suppressed = old_suppressed
	playback = _pb
	canvas.playback = _pb
	var steps := maxi(0, at_frame)
	for i in steps:
		playback.step()
		bullets.step(1.0 / 60.0)
	frame = steps
	_play_accum = 0.0
	_needs_reload = false          # 已重建到当前帧，没有待处理的重放了
	_last_reload_ms = Time.get_ticks_msec()
	_preview_dropped = bullets.dropped_total - dropped_before
	_update_frame_label()

func _on_play_pressed() -> void:
	playing = true
	_play_accum = 0.0
	_set_status("播放中（60fps 固定步长 · 固定种子 %d，可复现）" % fixed_seed)

func _on_pause_pressed() -> void:
	playing = false
	_play_accum = 0.0
	_set_status("已暂停于第 %d 帧" % frame)

func _on_step_pressed() -> void:
	playing = false
	_advance(1)

func _on_restart_pressed() -> void:
	playing = false
	_play_accum = 0.0
	_reload_playback(0)
	_set_status("已复位到第 0 帧")

func _advance(steps: int) -> void:
	if playback == null:
		return
	for i in steps:
		playback.step()
		bullets.step(1.0 / 60.0)
		frame += 1
	_update_frame_label()

## 方向键 / WASD 移动自机小球（仅在画布持有焦点时生效，避免在属性输入框打字时误动）。
## 移动**不触发重放**：播放层每帧发射自机狙时实时读取小球位置，所以新弹会追着小球走。
func _update_player_input(dt: float) -> void:
	if doc == null or _play_host == null or canvas == null or not canvas.has_focus():
		return
	var dir := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT) or Input.is_physical_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT) or Input.is_physical_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_UP) or Input.is_physical_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_physical_key_pressed(KEY_DOWN) or Input.is_physical_key_pressed(KEY_S):
		dir.y += 1.0
	if dir == Vector2.ZERO:
		return
	canvas.set_player_pos(_play_host.player_pos + dir.normalized() * PLAYER_SPEED * dt)

func _process(dt: float) -> void:
	_update_player_input(dt)
	if _needs_reload:
		# 拖动中防抖：连续拖动期间**不做重放**（一次 230 ms 会直接卡死），
		# 停手 140 ms 或松手后才重放。gizmo 一直是每帧跟手的。
		var wait: int = PREVIEW_DRAG_DEBOUNCE_MS if _drag_active else 0
		if Time.get_ticks_msec() - _reload_due_ms >= wait:
			_needs_reload = false
			_reload_playback(frame)
			return
	if playing and playback != null:
		# 固定 60 逻辑帧/秒（与 .brg / 游戏一致），与渲染帧率解耦
		_play_accum += dt
		var step := 1.0 / 60.0
		var n := int(floor(_play_accum / step))
		if n <= 0:
			return
		_play_accum -= float(n) * step
		_advance(mini(n, 30))

func _update_frame_label() -> void:
	if frame_label == null:
		return
	var s := "帧 %d · 场上 %d 弹" % [
		frame, bullets.active_count() if bullets != null else 0]
	if _preview_dropped > 0:
		s += "  ⚠ 弹池满(丢 %d)" % _preview_dropped
	frame_label.text = s
	if timeline != null:
		timeline.playhead = frame
		timeline.queue_redraw()

# ------------------------------------------------------------------ 键盘

func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	var ctrl := k.ctrl_pressed
	match k.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			_on_delete_pressed()
			get_viewport().set_input_as_handled()
		KEY_S when ctrl:
			_on_save_pressed()
			get_viewport().set_input_as_handled()
		KEY_O when ctrl:
			_on_open_pressed()
			get_viewport().set_input_as_handled()
		KEY_Z when ctrl:
			if k.shift_pressed:
				_on_redo_pressed()
			else:
				_on_undo_pressed()
			get_viewport().set_input_as_handled()
		KEY_Y when ctrl:
			_on_redo_pressed()
			get_viewport().set_input_as_handled()
		KEY_T when ctrl:
			_toggle_timeline()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			if canvas != null and canvas.pick_bullet_mode:
				_toggle_pick_bullet()
				get_viewport().set_input_as_handled()
		KEY_F:
			_on_fit_timeline()
			get_viewport().set_input_as_handled()
		KEY_SPACE:
			playing = not playing
			get_viewport().set_input_as_handled()
		KEY_A when ctrl:
			selected = []
			for i in doc.emitter_count():
				selected.append(i)
			_sync_tree_selection()
			_after_selection_changed()
			get_viewport().set_input_as_handled()
		KEY_C when ctrl:
			_on_copy_pressed()
			get_viewport().set_input_as_handled()
		KEY_V when ctrl:
			_on_paste_pressed()
			get_viewport().set_input_as_handled()

# ------------------------------------------------------------------ 状态栏

func _set_status(msg: String) -> void:
	if status != null:
		status.text = msg

func _update_status() -> void:
	if doc == null:
		_set_status("未打开文件。Ctrl+O 打开 .brg，或用 --open <path> 启动。")
		return
	var s := doc.summary()
	_set_status("%s · ver %s · %d 发射器 · MaxTime %d · Loop %s%s" % [
		String(s["path"]).get_file(), s["version"], s["emitters"], s["max_time"],
		"是" if s["loop"] else "否", "  ● 未保存" if doc.dirty else ""])
