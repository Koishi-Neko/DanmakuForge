extends Node
## 弹幕管理器：结构体数组 + MultiMesh 批量绘制 + 空间网格碰撞
##
## 设计要点（性能关键）：
##  1. 所有子弹存在并列的 PackedFloat32Array / PackedInt32Array 里，不用 Node，
##     避免每发子弹一次节点开销与 GC。
##  2. 用 MultiMeshInstance2D 一次性提交全部实例，1000+ 子弹只有 1 个 draw call。
##  3. 碰撞检测用空间哈希（64px 网格），只查玩家附近格子，复杂度 O(1) 而非 O(n)。
##  4. 子弹回收用空闲栈（free list），不移动数组，避免每帧 memmove。

const MAX_BULLETS := 8192
const CELL := 64.0

## 实际弹池容量。**游戏里恒为 `MAX_BULLETS`**（行为与以前完全一致）。
## 只有编辑器预览会把它调小：拖动 gizmo 时每帧都要从第 0 帧重放，
## 而 `step()`/`_push_to_multimesh()`/`_refresh_grid()` 都要扫满整个池子，
## 8192 × 3 次循环正是重放的主要开销（实测 300 帧 279 ms，拖不动）。
var capacity := MAX_BULLETS

## 是否维护空间哈希（碰撞用）。**游戏里恒为 true**。
## 编辑器预览不跑碰撞，关掉可省掉每帧一次全池扫描（`_refresh_grid`）。
## 关掉后 `_grid_dirty` 一直是 true，`hit_test_player()` 会按需自己重建，仍然正确。
var collision_enabled := true

# --- 子弹状态（结构体数组）---
var _px := PackedFloat32Array()
var _py := PackedFloat32Array()
var _vx := PackedFloat32Array()
var _vy := PackedFloat32Array()
var _r := PackedFloat32Array()
var _life := PackedFloat32Array()
var _age := PackedFloat32Array()
var _drag := PackedFloat32Array()
var _spin := PackedFloat32Array()
var _rot := PackedFloat32Array()
var _acc := PackedFloat32Array()   # 角加速度：>0 逆时针
var _accel := PackedFloat32Array() # 沿速度方向的加速度
var _acc_vec := PackedVector2Array() # 定向加速度单位向量（零 = 沿速度方向）
var _col := PackedColorArray()
var _sx := PackedFloat32Array()    # 视觉尺寸
var _sy := PackedFloat32Array()
var _protect := PackedFloat32Array()  # 前 N 秒不被 OutBound 回收（.brg Protect100）
var _acc_dir := PackedFloat32Array()  # 定向加速度角度（度），供子弹事件改写
var _move_dir := PackedFloat32Array() # 子弹行进方向（度）；速度归零后仍保留，便于重新赋速
var _home := PackedFloat32Array()     # 追踪转向速率（rad/s，0=不追踪；.brg ParaA 扩展）
## 追踪弹的引导目标（自机位置）。游戏内由 BrgPlayback 每帧写入；编辑器预览 = 可拖自机点。
var homing_target := Playfield.pos(390.0, 800.0)
var _prog := PackedInt32Array()       # 子弹事件程序 id（-1 = 无），见 register_program
var _prog_i := PackedInt32Array()     # 程序内下一条待触发事件索引
## ============ 来源追踪（P2：单弹删除用）============
## 身份 = (发射器序号, 出生帧, 该帧内第几发)。因为 BrgPlayback 是**确定性**的
## （固定种子 + 固定发弹顺序），这个身份在每次重放里都稳定可复现 —— 这正是
## 「精准删除某一颗子弹」能被持久化到补丁文件的前提。
var _src_em := PackedInt32Array()     # 发射器序号（-1 = 非 .brg 来源）
var _src_born := PackedInt32Array()   # 出生帧（BrgPlayback.age）
var _src_ord := PackedInt32Array()    # 该 (发射器, 帧) 内的第几发
var _programs: Array = []             # 原始程序表：每项 = [{t, name, delta}, ...]（编辑器/诊断用）
## 编译后的程序（按 program id 索引，并列 packed 数组；见 register_program）
var _prog_op: Array = []
var _prog_cv: Array = []
var _prog_main: Array = []
var _prog_ev: Array = []
var _prog_mode: Array = []
var _prog_val: Array = []
## 条件运算符 / 事件类型 / 变化模式 的整数编码（消掉热循环里的字符串比较）
const OP_EQUAL := 0
const OP_NOT_EQUAL := 1
const OP_GREATER := 2
const OP_LESS := 3
const OP_GREATER_EQUAL := 4
const OP_LESS_EQUAL := 5
const EV_NONE := -1
const EV_ACCEL := 0
const EV_ACC_DIR := 1
const EV_VELOCITY := 2
const EV_DIRECTION := 3
const EV_ANGULAR := 4
const EV_LIFE := 5
const MODE_INCREASE := 0
const MODE_DECREASE := 1
const MODE_CHANGE_TO := 2
var _flags := PackedInt32Array()   # bit0=active bit1=graze bit2=homing
var _free: Array[int] = []
## 活动槽位列表（性能关键）：`step`/`_refresh_grid`/`_push_to_multimesh`/`clear_circle`
## 只遍历活动弹，而不是扫满 8192 槽（实际同屏弹仅数百，池利用率 5~7%）。
## 维护方式：spawn 追加；`_kill` 用 swap-remove（O(1)），`_live_pos` 记录槽位在列表中的下标。
var _live := PackedInt32Array()
var _live_pos := PackedInt32Array()
var _active := 0
var _time := 0.0
var _main_time := 0.0   # 播放器主时间（秒），`.brg` TimeMain 事件用它而非 _time
var spawned_total := 0
var killed_total := 0
## 弹池满导致丢弃的发射次数。游戏里无意义，编辑器预览据此提示「预览可能与实际不同」。
var dropped_total := 0

# --- 空间哈希（扁平 CSR：格 → _cell_items 的一段连续区间）---
## 不用「每格一个 PackedInt32Array」的原因：GDScript 里 Packed 数组是值类型，
## `_grid[key].append(i)` 每次都是「取副本 → 改 → 写回」，每帧新建上百个小数组。
## 现在只有 3 个复用字典 + 1 个扁平数组，重建成本与活动弹数成正比。
const CELL_SHIFT := 6          # 2^6 = 64px
var _cell_count := {}          # Vector2i -> 数量
var _cell_start := {}          # Vector2i -> 在 _cell_items 中的起始下标
var _cell_fill := {}           # Vector2i -> 写入游标（仅重建期间用）
var _cell_items := PackedInt32Array()
var _grid_dirty := true

# --- 渲染：按贴图类型分组，每类一个 MultiMeshInstance2D ---
const TEX_PATHS := {
	"dot": "res://assets/sprites/bullet_dot.png",
	"orb": "res://assets/sprites/bullet_orb.png",
	"holy_arrow": "res://assets/textures/bullet_holy_arrow.png",
	"blood_arrow": "res://assets/textures/bullet_blood_arrow.png",
	"skull": "res://assets/textures/bullet_skull.png",
	"skull_corrupt": "res://assets/textures/bullet_skull_corrupt.png",
	"ember": "res://assets/textures/bullet_ember.png",
	"hellrock_large": "res://assets/textures/bullet_hellrock_large.png",
	"hellrock_small": "res://assets/textures/bullet_hellrock_small.png",
	"hellsword": "res://assets/textures/bullet_hellsword.png",
	"star_red_a": "res://assets/textures/bullet_star_red_a.png",
	"star_red_b": "res://assets/textures/bullet_star_red_b.png",
	"star_red_c": "res://assets/textures/bullet_star_red_c.png",
	"star_red_d": "res://assets/textures/bullet_star_red_d.png",
	"star_red_e": "res://assets/textures/bullet_star_red_e.png",
	"fire_blue": "res://assets/textures/bullet_fire_blue.png",
	"fire_purple": "res://assets/textures/bullet_fire_purple.png",
	"fire_green": "res://assets/textures/bullet_fire_green.png",
	# 蓝色小弹专用（2026-09-17）：纯白内质 + 湛蓝半透明轮廓；调用点实例色用白
	"orb_azure": "res://assets/textures/bullet_orb_azure.png",
	# 一面小怪（幽魂/亡魂）专用「灵魂美术」弹：自机狙 / 散射各一张
	"soul_aim": "res://assets/textures/bullet_soul_aim.png",
	"soul_spread": "res://assets/textures/bullet_soul_spread.png",
	# 一面 BOSS 外区弹幕（位面弹：布在上方/两侧/下角，自机不会去的空域；
	# 现由 `.brg` 发射器直接引用，谱面见 `tools/inject_outer_danmaku.py`）
	"decor_wisp": "res://assets/textures/bullet_decor_wisp.png",
	"decor_lantern": "res://assets/textures/bullet_decor_lantern.png",
	"decor_higanbana": "res://assets/textures/bullet_decor_higanbana.png",
	"decor_ripple": "res://assets/textures/bullet_decor_ripple.png",
	"decor_soul_core": "res://assets/textures/bullet_decor_soul_core.png",
	"decor_grave_dust": "res://assets/textures/bullet_decor_grave_dust.png",
}

## 装饰弹专用贴图：渲染层垫在真实弹之下（z=9），避免盖住读弹（2026-09-15）
const DECOR_TEX := ["decor_wisp", "decor_lantern", "decor_higanbana",
	"decor_ripple", "decor_soul_core", "decor_grave_dust"]
var _mm: Dictionary = {}          # tex_id -> MultiMeshInstance2D
var _tex := PackedInt32Array()    # 每发子弹的贴图 id（索引进 TEX_KEYS）
var _tex_keys: Array[String] = []
## 贴图名 -> id（避免每次 spawn 都做 `_tex_keys.find()` 线性查找）
var _tex_id: Dictionary = {}
## 每张贴图的烘焙边距比（按 id 索引）。2026-09-17 起取消白+黑描边，
## pad_ratio 恒为 1.0；机制保留以便未来需要时扩展。
var _tex_pad_arr := PackedFloat32Array()
## 每张贴图的烘焙边距比（TexLoader.get_bullet_tex 的 pad_ratio）
var _tex_pad: Dictionary = {}

const F_ACTIVE := 1
const F_GRAZE := 2
const F_CORRUPT := 4      # 污染弹：触碰不致死，而是累积污染值（a_k = 3k-1）
const F_OUTBOUND := 8     # .brg OutBound：出画布即消（受 Protect100 保护期约束）
const F_UNREMOVE := 16    # .brg UnRemoveable：不被炸弹消除

## 子弹判定半径的 7 个统一档位（像素）。所有子弹只取这些值之一；
## 图像（含半透明边缘）可大于判定区，判定区可小于图像。
const HIT_TIERS := [2.0, 3.0, 4.5, 5.0, 8.0, 16.0, 24.0]

## 把任意半径吸附到最近的档位（并列时取较大档）。
## 命中缓存：弹幕半径取值高度重复（ATLAS 档位 + 少量代码常量），省掉每次 spawn 的循环。
static var _snap_cache: Dictionary = {}

static func snap_hit(r: float) -> float:
	var c = _snap_cache.get(r)
	if c != null:
		return c
	var best := HIT_TIERS[0]
	var bd := absf(r - best)
	for t in HIT_TIERS:
		var d := absf(r - t)
		if d <= bd:
			bd = d
			best = t
	_snap_cache[r] = best
	return best

## 贴图在游戏里的最大显示边长（弹幕贴图烘焙的目标尺寸用）：从 `BrgPlayback.ATLAS`
## 反查该贴图的显示尺寸；不在 ATLAS 的（dot / soul / 箭 / 骷髅等代码发弹）按 16px 估。
## 2026-09-17：返回值 ×2 —— 390×480 改造后屏幕放大约 2×，烘焙需要 2× 超采样余量
## （配合 T4 的 BAKE_LADDER 扩展；尺寸数值本身冻结不变，只影响贴图锐度）。
func _base_display_size(tex_key: String) -> float:
	for k in BrgPlayback.ATLAS:
		var e: Dictionary = BrgPlayback.ATLAS[k]
		if String(e.get("tex", "")) == tex_key:
			return float(e.get("size", 16.0)) * 2.0
	return 16.0 * 2.0

func _ready() -> void:
	var bake_before := TexLoader.bake_count
	var bake_ms_before := TexLoader.bake_ms_total
	for i in capacity:
		_px.append(0.0); _py.append(0.0)
		_vx.append(0.0); _vy.append(0.0)
		_r.append(0.0)
		_life.append(0.0); _age.append(0.0)
		_drag.append(1.0); _spin.append(0.0); _rot.append(0.0)
		_acc.append(0.0); _accel.append(0.0)
		_acc_vec.append(Vector2.ZERO)
		_col.append(Color.WHITE)
		_sx.append(8.0); _sy.append(8.0)
		_protect.append(0.0)
		_acc_dir.append(0.0)
		_move_dir.append(0.0)
		_home.append(0.0)
		_prog.append(-1)
		_prog_i.append(0)
		_src_em.append(-1)
		_src_born.append(-1)
		_src_ord.append(-1)
		_flags.append(0)
		_tex.append(0)
		_live_pos.append(-1)
		_free.append(capacity - 1 - i)

	for key in TEX_PATHS:
		_tex_id[key] = _tex_keys.size()
		_tex_keys.append(key)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.mesh = QuadMesh.new()
		mm.instance_count = capacity
		mm.visible_instance_count = 0
		var node := MultiMeshInstance2D.new()
		node.multimesh = mm
		if key in DECOR_TEX:
			# 装饰弹保持原贴图（z=9、刻意压暗，不参与可读性烘焙）
			node.texture = TexLoader.get_tex(TEX_PATHS[key])
			_tex_pad[key] = 1.0
		else:
			var baked: Dictionary = TexLoader.get_bullet_tex(TEX_PATHS[key], _base_display_size(key))
			node.texture = baked["tex"]
			_tex_pad[key] = baked["pad_ratio"]
		_tex_pad_arr.append(float(_tex_pad[key]))
		node.name = "BulletLayer_" + key
		node.z_index = 9 if key in DECOR_TEX else 10
		add_child(node)
		_mm[key] = node
	if TexLoader.bake_count > bake_before:
		print("[Bullet] 弹幕贴图烘焙 %d 张，%.1f ms（其余命中磁盘缓存）" % [
			TexLoader.bake_count - bake_before, TexLoader.bake_ms_total - bake_ms_before])
	# 2026-09-17：污染弹核心层（青色实心圆）与 hellrock 红色熔缘层已移除——
	# 用户要求所有弹幕取消硬性描边；污染弹改由 `bullet_skull_corrupt` 新美术
	# （紫色半透明膜包裹骷髅）承担可读性。

# ------------------------------------------------------------------ 生成

func spawn(p: Dictionary) -> void:
	if _free.is_empty():
		dropped_total += 1
		return
	var i: int = _free.pop_back()
	_live_pos[i] = _live.size()
	_live.append(i)
	# 来源追踪（P2）：由 BrgPlayback 填入，供「单弹删除」识别身份
	_src_em[i] = int(p.get("em", -1))
	_src_born[i] = int(p.get("born", -1))
	_src_ord[i] = int(p.get("ord", -1))
	_px[i] = p.get("x", 0.0)
	_py[i] = p.get("y", 0.0)
	_vx[i] = p.get("vx", 0.0)
	_vy[i] = p.get("vy", 0.0)
	_move_dir[i] = rad_to_deg(atan2(_vy[i], _vx[i])) if (absf(_vx[i]) + absf(_vy[i])) > 0.0001 else 0.0
	_r[i] = snap_hit(float(p.get("r", 3.0)))
	_life[i] = p.get("life", 12.0)
	_age[i] = 0.0
	_drag[i] = p.get("drag", 1.0)
	_spin[i] = p.get("spin", 0.0)
	_rot[i] = p.get("rot", 0.0)
	_acc[i] = p.get("acc", 0.0)
	_accel[i] = p.get("accel", 0.0)
	_acc_dir[i] = float(p.get("acc_dir", 0.0))
	if p.has("acc_dir"):
		var ad := deg_to_rad(_acc_dir[i])
		_acc_vec[i] = Vector2(cos(ad), sin(ad))
	else:
		_acc_vec[i] = Vector2.ZERO
	_prog[i] = int(p.get("prog", -1))
	_prog_i[i] = 0
	# 追踪（.brg ParaA 扩展）：入参单位为度/帧 → 存 rad/s
	_home[i] = deg_to_rad(float(p.get("homing", 0.0))) * 60.0
	_col[i] = p.get("color", Color(1, 0.4, 0.8, 1.0))
	_sx[i] = p.get("size", _r[i] * 2.6) * Playfield.ART_SCALE
	_sy[i] = float(p.get("size_y", _sx[i] / Playfield.ART_SCALE)) * Playfield.ART_SCALE
	var tex_name: String = p.get("tex", "dot")
	var ti: int = _tex_id.get(tex_name, -1)
	_tex[i] = ti if ti >= 0 else 0
	# 烘焙边距比（2026-09-17 起恒为 1.0；机制保留）
	var pad := _tex_pad_arr[_tex[i]]
	if pad != 1.0:
		_sx[i] *= pad
		_sy[i] *= pad
	var f := F_ACTIVE
	if p.get("graze", true):
		f |= F_GRAZE
	if p.get("corrupt", false):
		f |= F_CORRUPT
	if p.get("outbound", false):
		f |= F_OUTBOUND
	if p.get("unremoveable", false):
		f |= F_UNREMOVE
	_flags[i] = f
	_protect[i] = p.get("protect", 0.0)
	_active += 1
	spawned_total += 1
	_grid_dirty = true

## 注册子弹事件程序（`.brg` BulletEventGroupList 编译结果）。
## steps = [{t: float(秒), name: String, delta: float}, ...]，按 t 升序；返回程序 id。
## 这里把字符串/字典形式的 steps **再编译成并列 packed 数组**：
## 子弹事件是每帧每弹重估的热路径，消掉 String()/Dictionary 取值后开销降一个数量级。
func register_program(steps: Array) -> int:
	_programs.append(steps)
	var ops := PackedInt32Array()
	var cvs := PackedFloat32Array()
	var mains := PackedByteArray()
	var evs := PackedInt32Array()
	var modes := PackedInt32Array()
	var vals := PackedFloat32Array()
	for s in steps:
		ops.append(_op_id(String(s.get("op", "Greater"))))
		cvs.append(float(s.get("cv", 0.0)))
		mains.append(1 if bool(s.get("main", false)) else 0)
		evs.append(_event_id(String(s.get("name", ""))))
		modes.append(_mode_id(String(s.get("mode", "Increase"))))
		vals.append(float(s.get("value", 0.0)))
	_prog_op.append(ops)
	_prog_cv.append(cvs)
	_prog_main.append(mains)
	_prog_ev.append(evs)
	_prog_mode.append(modes)
	_prog_val.append(vals)
	return _programs.size() - 1

static func _op_id(s: String) -> int:
	match s:
		"Equal": return OP_EQUAL
		"NotEqual": return OP_NOT_EQUAL
		"Greater": return OP_GREATER
		"Less": return OP_LESS
		"GreaterEqual": return OP_GREATER_EQUAL
		"LessEqual": return OP_LESS_EQUAL
	return OP_GREATER

static func _event_id(s: String) -> int:
	match s:
		"Acceleration", "BulletAccelerate", "Accelerate": return EV_ACCEL
		"AccDirection", "BulletAccDirection": return EV_ACC_DIR
		"Velocity", "BulletVelocity": return EV_VELOCITY
		"Direction", "BulletDirection": return EV_DIRECTION
		"AngularVelocity": return EV_ANGULAR
		"LifeTime": return EV_LIFE
	return EV_NONE

static func _mode_id(s: String) -> int:
	match s:
		"Increase": return MODE_INCREASE
		"Decrease": return MODE_DECREASE
		"ChangeTo": return MODE_CHANGE_TO
	return MODE_INCREASE

## 编译版事件应用（与 `_apply_bullet_event` 等价，只是按 int 分派）
func _apply_event_id(i: int, ev: int, mode: int, value: float) -> void:
	var set_abs := mode == MODE_CHANGE_TO
	var d := value * (1.0 if mode != MODE_DECREASE else -1.0)
	match ev:
		EV_ACCEL:
			_accel[i] = value if set_abs else _accel[i] + d
		EV_ACC_DIR:
			_acc_dir[i] = value if set_abs else _acc_dir[i] + d
			var r := deg_to_rad(_acc_dir[i])
			_acc_vec[i] = Vector2(cos(r), sin(r))
		EV_VELOCITY:
			var sp := sqrt(_vx[i] * _vx[i] + _vy[i] * _vy[i])
			var nspeed := value if set_abs else sp + d
			var dir := deg_to_rad(_move_dir[i])
			_vx[i] = cos(dir) * maxf(nspeed, 0.0)
			_vy[i] = sin(dir) * maxf(nspeed, 0.0)
		EV_DIRECTION:
			_move_dir[i] = value if set_abs else _move_dir[i] + d
			var sp2 := sqrt(_vx[i] * _vx[i] + _vy[i] * _vy[i])
			var dir2 := deg_to_rad(_move_dir[i])
			_vx[i] = cos(dir2) * sp2
			_vy[i] = sin(dir2) * sp2
		EV_ANGULAR:
			_spin[i] = deg_to_rad(value) * 60.0 if set_abs else _spin[i] + deg_to_rad(d) * 60.0
		EV_LIFE:
			_life[i] = value / 60.0 if set_abs else _life[i] + d / 60.0

## 编译版条件判定（帧为单位）。Equal 用 0.5 帧容差。
static func _cond_id(op: int, cv: float, t: float) -> bool:
	match op:
		OP_EQUAL:
			return absf(t - cv) < 0.5
		OP_NOT_EQUAL:
			return absf(t - cv) >= 0.5
		OP_GREATER:
			return t > cv
		OP_LESS:
			return t < cv
		OP_GREATER_EQUAL:
			return t >= cv
		OP_LESS_EQUAL:
			return t <= cv
	return t > cv

## 应用一条子弹事件。mode=Increase/Decrease 为相对增减，ChangeTo 为绝对赋值。
## value 已由播放器换算为屏幕单位（速度 px/s、加速度 px/s²、角度仍为度）。
func _apply_bullet_event(i: int, step: Dictionary) -> void:
	var name := String(step.get("name", ""))
	var mode := String(step.get("mode", "Increase"))
	var value := float(step.get("value", 0.0))
	var set_abs := mode == "ChangeTo"
	var d := value * (1.0 if mode != "Decrease" else -1.0)
	match name:
		"Acceleration", "BulletAccelerate", "Accelerate":
			_accel[i] = value if set_abs else _accel[i] + d
		"AccDirection", "BulletAccDirection":
			_acc_dir[i] = value if set_abs else _acc_dir[i] + d
			var r := deg_to_rad(_acc_dir[i])
			_acc_vec[i] = Vector2(cos(r), sin(r))
		"Velocity", "BulletVelocity":
			var sp := sqrt(_vx[i] * _vx[i] + _vy[i] * _vy[i])
			var nspeed := value if set_abs else sp + d
			var dir := deg_to_rad(_move_dir[i])
			_vx[i] = cos(dir) * maxf(nspeed, 0.0)
			_vy[i] = sin(dir) * maxf(nspeed, 0.0)
		"Direction", "BulletDirection":
			_move_dir[i] = value if set_abs else _move_dir[i] + d
			var sp2 := sqrt(_vx[i] * _vx[i] + _vy[i] * _vy[i])
			var dir2 := deg_to_rad(_move_dir[i])
			_vx[i] = cos(dir2) * sp2
			_vy[i] = sin(dir2) * sp2
		"AngularVelocity":
			_spin[i] = deg_to_rad(value) * 60.0 if set_abs else _spin[i] + deg_to_rad(d) * 60.0
		"LifeTime":
			_life[i] = value / 60.0 if set_abs else _life[i] + d / 60.0

## 子弹事件条件判定（帧为单位）。Equal 用 0.5 帧容差。
func _cond_op(op: String, cv: float, t: float) -> bool:
	match op:
		"Equal":
			return absf(t - cv) < 0.5
		"NotEqual":
			return absf(t - cv) >= 0.5
		"Greater":
			return t > cv
		"Less":
			return t < cv
		"GreaterEqual":
			return t >= cv
		"LessEqual":
			return t <= cv
	return t > cv

## 设置 `.brg` 主时间（秒）。由 BrgPlayback 每帧回写；TimeMain 类子弹事件以此为基准。
func set_main_time(t: float) -> void:
	_main_time = t

func clear() -> void:
	for i in capacity:
		_flags[i] = 0
		_live_pos[i] = -1
	_live.clear()
	_free.clear()
	for i in range(capacity - 1, -1, -1):
		_free.append(i)
	_active = 0
	for key in _tex_keys:
		(_mm[key].multimesh as MultiMesh).visible_instance_count = 0
	_grid_dirty = true

func active_count() -> int:
	return _active

# ------------------------------------------------------------------ 每帧推进

func step(delta: float) -> void:
	_time += delta
	# 屏外回收：沿用旧设计边界（w/h=860/1160 设计、外扩 1200/1400）×SCALE ——
	# 必须保留足够余量：外区装饰弹（`bullet_decor_*`）刻意在战场外生成/穿行，
	# 收得太紧会在出生帧就被误杀（2026-09-17 实测：outer_zone_check 密度塌方）。
	var fsc := Playfield.SCALE
	var w := 860.0 * fsc
	var h := 1160.0 * fsc
	# 反向遍历活动列表：`_kill` 的 swap-remove 只会把「已处理过的末尾槽位」换到当前位置
	for li in range(_live.size() - 1, -1, -1):
		var i := _live[li]
		if (_flags[i] & F_ACTIVE) == 0:
			continue
		_age[i] += delta
		if _age[i] >= _life[i]:
			_kill(i)
			continue
		# 子弹事件程序（.brg BulletEventGroupList）：每帧按条件重估（同 SlimeStorm）。
		# `Equal` 条件本帧成立→一次性；`Greater`/`Less` 持续成立→每帧重放（Increase 会累积）。
		var pr := _prog[i]
		if pr >= 0 and pr < _prog_op.size():
			var ops: PackedInt32Array = _prog_op[pr]
			var mains: PackedByteArray = _prog_main[pr]
			var cvs: PackedFloat32Array = _prog_cv[pr]
			var evs: PackedInt32Array = _prog_ev[pr]
			var modes: PackedInt32Array = _prog_mode[pr]
			var vals: PackedFloat32Array = _prog_val[pr]
			var age60 := _age[i] * 60.0
			var main60 := _main_time * 60.0
			for k in ops.size():
				var now: float = main60 if mains[k] == 1 else age60
				if _cond_id(ops[k], cvs[k], now):
					_apply_event_id(i, evs[k], modes[k], vals[k])
		# 加速度：定向（.brg BulletAccDirection）或沿速度方向（形成曲线弹幕）
		var a := _accel[i]
		if a != 0.0:
			var av := _acc_vec[i]
			if av != Vector2.ZERO:
				_vx[i] += av.x * a * delta
				_vy[i] += av.y * a * delta
			else:
				var v := Vector2(_vx[i], _vy[i])
				var sp := v.length()
				if sp > 0.0001:
					var nv := v / sp * maxf(sp + a * delta, 0.0)
					_vx[i] = nv.x; _vy[i] = nv.y
		# 角加速度：绕原点旋转速度向量
		var ac := _acc[i]
		if ac != 0.0:
			_rot[i] += ac * delta
			var c := cos(ac * delta)
			var s := sin(ac * delta)
			var vx := _vx[i]; var vy := _vy[i]
			_vx[i] = vx * c - vy * s
			_vy[i] = vx * s + vy * c
		# 追踪（.brg ParaA 扩展）：逐帧把速度向量朝引导目标拧，速率上限 _home[i] rad/s
		var hm := _home[i]
		if hm != 0.0:
			var hsp := sqrt(_vx[i] * _vx[i] + _vy[i] * _vy[i])
			if hsp > 0.001:
				var cur := atan2(_vy[i], _vx[i])
				var want := atan2(homing_target.y - _py[i], homing_target.x - _px[i])
				var turn := clampf(wrapf(want - cur, -PI, PI), -hm * delta, hm * delta)
				var nd := cur + turn
				_vx[i] = cos(nd) * hsp
				_vy[i] = sin(nd) * hsp
		var d := _drag[i]
		if d != 1.0:
			var f := pow(d, delta * 60.0)
			_vx[i] *= f; _vy[i] *= f
		_px[i] += _vx[i] * delta
		_py[i] += _vy[i] * delta
		var _spd := sqrt(_vx[i] * _vx[i] + _vy[i] * _vy[i])
		if _spd > 0.001:
			_move_dir[i] = rad_to_deg(atan2(_vy[i], _vx[i]))
		if _spin[i] != 0.0:
			_rot[i] += _spin[i] * delta
		# .brg OutBound：出画布即消（Protect100 保护期内豁免）
		if (_flags[i] & F_OUTBOUND) != 0 and _age[i] >= _protect[i]:
			if _px[i] < 0.0 or _px[i] > Playfield.FIELD_W or _py[i] < 0.0 or _py[i] > Playfield.FIELD_H:
				_kill(i)
				continue
		if _px[i] < -w or _px[i] > w + 1200.0 * fsc or _py[i] < -h or _py[i] > h + 1400.0 * fsc:
			_kill(i)
	# 网格改为惰性重建（只由 hit_test_player 触发）：spawn 也会置脏，
	# 原先在 step 里重建 = 每步白重建一次，密集帧等于扫两遍池子
	_grid_dirty = true
	_push_to_multimesh()

func _kill(i: int) -> void:
	if (_flags[i] & F_ACTIVE) != 0:
		_flags[i] = 0
		_active -= 1
		killed_total += 1
		_free.append(i)
		_grid_dirty = true
		# 活动列表 swap-remove（O(1)，不移动数组）
		var idx := _live_pos[i]
		var last := _live.size() - 1
		if idx != last:
			var moved := _live[last]
			_live[idx] = moved
			_live_pos[moved] = idx
		_live.remove_at(last)
		_live_pos[i] = -1

# ------------------------------------------------------------------ 渲染

func _push_to_multimesh() -> void:
	var counts := {}
	for i in _live:
		if (_flags[i] & F_ACTIVE) == 0:
			continue
		var key: String = _tex_keys[_tex[i]]
		var n: int = counts.get(key, 0)
		var mm: MultiMesh = _mm[key].multimesh
		var rot := _rot[i]
		var c := cos(rot)
		var s := sin(rot)
		var sx := _sx[i]
		var sy := _sy[i]
		mm.set_instance_transform_2d(n, Transform2D(
			Vector2(c * sx, s * sx),
			Vector2(-s * sy, c * sy),
			Vector2(_px[i], _py[i])
		))
		mm.set_instance_color(n, _col[i])
		counts[key] = n + 1
	for key in _tex_keys:
		(_mm[key].multimesh as MultiMesh).visible_instance_count = counts.get(key, 0)

# ------------------------------------------------------------------ 碰撞

func _refresh_grid() -> void:
	_cell_count.clear()
	_cell_start.clear()
	_cell_fill.clear()
	# 第 1 遍：每格计数
	for i in _live:
		if (_flags[i] & F_ACTIVE) == 0:
			continue
		var key := _cell_of(_px[i], _py[i])
		_cell_count[key] = int(_cell_count.get(key, 0)) + 1
	# 第 2 遍：前缀和（起始下标 + 写入游标）
	var ofs := 0
	for key in _cell_count:
		var n: int = _cell_count[key]
		_cell_start[key] = ofs
		_cell_fill[key] = ofs
		ofs += n
	if _cell_items.size() < ofs:
		_cell_items.resize(ofs)
	# 第 3 遍：写进扁平数组
	for i in _live:
		if (_flags[i] & F_ACTIVE) == 0:
			continue
		var key2 := _cell_of(_px[i], _py[i])
		var pos: int = _cell_fill[key2]
		_cell_items[pos] = i
		_cell_fill[key2] = pos + 1
	_grid_dirty = false

static func _cell_of(x: float, y: float) -> Vector2i:
	return Vector2i(int(floor(x / CELL)), int(floor(y / CELL)))

## 玩家判定：返回是否被命中（判定半径 player_r）、擦弹数、污染弹触击数。
## 污染弹触击即消散；skip_corrupt（已污染 / 无敌 / 豁免窗口）时直接穿过不结算。
## graze_bonus：擦弹环宽（取 PlayerConst.GRAZE_R，方案 B 的设计战场里按 0.6 缩放）
func hit_test_player(px: float, py: float, player_r: float, skip_corrupt: bool = false, graze_bonus: float = PlayerConst.GRAZE_R) -> Dictionary:
	if _grid_dirty:
		_refresh_grid()
	var hit := false
	var grazed := 0
	var corrupt := 0
	var gx := int(floor(px / CELL))
	var gy := int(floor(py / CELL))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var key := Vector2i(gx + dx, gy + dy)
			var cnt: int = _cell_count.get(key, 0)
			if cnt == 0:
				continue
			var st: int = _cell_start[key]
			for k in range(st, st + cnt):
				var i := _cell_items[k]
				if (_flags[i] & F_ACTIVE) == 0:
					continue
				if (_flags[i] & F_CORRUPT) != 0 and skip_corrupt:
					continue
				var ddx := _px[i] - px
				var ddy := _py[i] - py
				var rr := _r[i] + player_r
				var d2 := ddx * ddx + ddy * ddy
				if d2 <= rr * rr:
					if (_flags[i] & F_CORRUPT) != 0:
						_kill(i)      # 污染弹触击即消散
						corrupt += 1
					else:
						hit = true
				elif (_flags[i] & F_GRAZE) != 0:
					var g := _r[i] + player_r + graze_bonus
					if d2 <= g * g:
						grazed += 1
	return {"hit": hit, "graze": grazed, "corrupt": corrupt}

## 炸弹：清空指定矩形/半径内的子弹，返回清除数量
func clear_circle(cx: float, cy: float, radius: float) -> int:
	var n := 0
	var r2 := radius * radius
	# 反向遍历（见 step 的说明）：`_kill` 也是 swap-remove
	for li in range(_live.size() - 1, -1, -1):
		var i := _live[li]
		if (_flags[i] & F_ACTIVE) == 0:
			continue
		if (_flags[i] & F_UNREMOVE) != 0:
			continue
		var dx := _px[i] - cx
		var dy := _py[i] - cy
		if dx * dx + dy * dy <= r2:
			_kill(i)
			n += 1
	return n

## 调试/自动测试用：导出全部子弹位置（活动列表顺序）
func dump_positions() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in _live:
		if (_flags[i] & F_ACTIVE) == 0:
			continue
		out.append(_px[i]); out.append(_py[i]); out.append(_r[i])
	return out

# ------------------------------------------------------------------ 单弹拾取（P2）

## 子弹身份：`[发射器序号, 出生帧, 该帧内第几发]`。非 `.brg` 来源返回空数组。
func identity_of(slot: int) -> Array:
	if slot < 0 or slot >= capacity:
		return []
	if _src_em[slot] < 0 or _src_born[slot] < 0:
		return []
	return [_src_em[slot], _src_born[slot], _src_ord[slot]]

## 在 (x, y) 附近半径内的**最近**活动子弹，返回槽位索引（-1 = 没找到）。
## 编辑器点画布删单弹时用；命中判定用视觉尺寸 `_sx`，手感比判定半径更符合直觉。
func pick(cx: float, cy: float, radius: float) -> int:
	var best := -1
	var best_d2 := radius * radius
	for i in _live:
		if (_flags[i] & F_ACTIVE) == 0:
			continue
		var dx := _px[i] - cx
		var dy := _py[i] - cy
		var d2 := dx * dx + dy * dy
		# 取「到弹体边缘的距离」：允许直接点到弹身上
		var rr := maxf(_r[i], _sx[i] * 0.5)
		var edge := maxf(0.0, sqrt(d2) - rr)
		if edge <= radius and d2 < best_d2 + rr * rr:
			best_d2 = d2
			best = i
	return best

## 当前位置与半径（编辑器绘制拾取高亮用）
func slot_info(slot: int) -> Dictionary:
	if slot < 0 or slot >= capacity or (_flags[slot] & F_ACTIVE) == 0:
		return {}
	return {
		"x": _px[slot], "y": _py[slot],
		"r": _r[slot], "size": _sx[slot],
		"em": _src_em[slot], "born": _src_born[slot], "ord": _src_ord[slot],
	}

## 遍历全部活动槽位（返回快照，避免调用方边遍历边改状态）
func active_slots() -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in _live:
		if (_flags[i] & F_ACTIVE) != 0:
			out.append(i)
	return out
