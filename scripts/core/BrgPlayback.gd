class_name BrgPlayback
extends RefCounted
## `.brg` 运行时播放器：按帧驱动 `BrgLoader` 解析出的数据类，向 `BulletManager` 发弹。
##
## 用法：
##   var pb := BrgPlayback.new(BrgLoader.load_file(path), bullets, self)
##   pb.origin_callable = func(): return boss_pos   # 发射器宿主位置（屏幕坐标）
##   pb.visual_overrides = {0: {"tex": "ember", "color": Color.RED}}  # 可选：教学/替换贴图
##   # 每帧：pb.step()
##
## 单位换算交给 `Playfield`：速度 px/帧 → px/s（×60）、加速度 px/帧² → px/s²（×3600）。
##
## 单位约定（2026-09-17，390×480 改造）：
##   · 位置/速度/加速度：设计单位 → 世界单位，走 Playfield.pos/vec/len/speed/accel（×SCALE）
##   · 弹幕尺寸/判定（`r` / `size` / `size_y`）：**世界单位直写，不随 SCALE**（冻结，见 Playfield 决议）
##   · 发射器自走：`self_pos` 在逐帧积分处 ×SCALE（初值/事件增量/循环重置均保持设计单位）

## `.brg` 图集区域名 → 本工程贴图 + 原生尺寸 + 判定半径档位（见 BRG_FORMAT.md §6）
## `hit` 直接取 BulletManager.HIT_TIERS 的档位值（判定区可小于图像的半透明边缘）。
const ATLAS := {
	"bullet62_1": {"tex": "orb_azure", "size": 32.0, "hit": 4.5, "fixed_white": true},
	"bullet_orb": {"tex": "orb_azure", "size": 32.0, "hit": 4.5, "fixed_white": true},
	"bullet_hellrock_large": {"tex": "hellrock_large", "size": 34.0, "hit": 8.0},
	"bullet_ember": {"tex": "ember", "size": 30.0, "hit": 5.0},
	"bullet_hellrock_small": {"tex": "hellrock_small", "size": 20.0, "hit": 3.0},
	"bullet_hellsword": {"tex": "hellsword", "size": 34.0, "hit": 8.0},
	"bullet_star_red_a": {"tex": "star_red_a", "size": 32.0, "hit": 4.5},
	"bullet_star_red_b": {"tex": "star_red_b", "size": 32.0, "hit": 4.5},
	"bullet_star_red_c": {"tex": "star_red_c", "size": 32.0, "hit": 4.5},
	"bullet_star_red_d": {"tex": "star_red_d", "size": 32.0, "hit": 4.5},
	"bullet_star_red_e": {"tex": "star_red_e", "size": 32.0, "hit": 4.5},
	"bullet_fire_blue": {"tex": "fire_blue", "size": 30.0, "hit": 5.0},
	"bullet_fire_purple": {"tex": "fire_purple", "size": 30.0, "hit": 5.0},
	"bullet_fire_green": {"tex": "fire_green", "size": 30.0, "hit": 5.0},
	"bullet_star_corrupt_c": {"tex": "skull_corrupt", "size": 32.0, "hit": 4.5},
	# 一面「外区弹幕」（2026-09-15 起由 .brg 发射器直接引用；见 tools/inject_outer_danmaku.py）
	"bullet_decor_wisp": {"tex": "decor_wisp", "size": 16.0, "hit": 4.5},
	"bullet_decor_lantern": {"tex": "decor_lantern", "size": 20.0, "hit": 5.0},
	"bullet_decor_higanbana": {"tex": "decor_higanbana", "size": 17.0, "hit": 4.5},
	"bullet_decor_ripple": {"tex": "decor_ripple", "size": 20.0, "hit": 8.0},
	"bullet_decor_soul_core": {"tex": "decor_soul_core", "size": 36.0, "hit": 16.0},
	"bullet_decor_grave_dust": {"tex": "decor_grave_dust", "size": 15.0, "hit": 4.1},
}
const DEFAULT_TEX := "orb"
const DEFAULT_SIZE := 32.0

var barrage: BrgLoader.Barrage = null
var bullets: Node
var host: Node2D                       # 提供 get_player_pos()（瞄准基准）
var origin_callable: Callable = Callable()   # 发射器宿主位置（屏幕坐标）
var apply_emitter_offset := true       # 是否叠加 EmitPoint 自身时的发射器 Position 偏移
## 循环到 MaxTime 时是否**保留场上弹幕**（默认 false = 清场，编辑器预览用）。
## 游戏内符卡设 true：反复播放时旧弹幕继续飞，避免「换轮瞬间全屏清空」的覆盖度断层。
var loop_keeps_bullets := false
var visual_overrides: Dictionary = {}  # emitter.index -> {tex,color,size,r,corrupt,graze,size_y}
var age := 0

## ================================================================== 单弹压制（P2）
##
## `.brg` **没有「单颗子弹」实体**：子弹是按 `Way`/`Circle`/`Count` 每帧程序化生成的，
## XML 里不存在「第 1234 号子弹」。所以「删掉某一颗碍事的弹」只能做成**补丁层**：
##
##   身份 = "发射器序号:出生帧:该帧内第几发"
##
## 本播放器是确定性的（固定种子 + 固定发弹顺序），因此该身份每次重放都稳定复现，
## 可以安全地写进 sidecar 文件。被压制的身份**根本不生成**那颗弹 —— 语义上就是
## 「它不存在」，而不是「生成了再删掉」。
##
## 持久化在 `<xxx.brg>.patch.json`，**不改 `.brg` 本身**，所以原始工程保持无损、
## SlimeStorm 仍能正常打开。
var suppressed: Dictionary = {}         # "em:born:ord" -> true
var _frame_ord := 0                     # 当前帧内已发弹计数（每帧清零）
var suppressed_hits := 0                # 本次播放实际压掉几发（诊断用）

var _states: Array = []
var _prog_ids: Array = []              # 每个发射器编译出的子弹事件程序 id（-1 = 无）

func _init(p_barrage: BrgLoader.Barrage, p_bullets: Node, p_host: Node2D) -> void:
	barrage = p_barrage
	bullets = p_bullets
	host = p_host
	if barrage != null:
		for em in barrage.emitters:
			_states.append(_init_state(em))
			_prog_ids.append(_compile_program(em))

## 把发射器的 BulletEventGroupList 编译成 `BulletManager` 程序（按时间排序）
func _compile_program(em: BrgLoader.BrgEmitter) -> int:
	if em.bullet_groups.is_empty() or bullets == null:
		return -1
	if not bullets.has_method("register_program"):
		return -1
	var steps: Array = []
	for g in em.bullet_groups:
		for ev in g.events:
			var name := String(ev.change_name)
			var val: float = ev.res
			match name:
				"Acceleration", "BulletAccelerate", "Accelerate":
					val = Playfield.accel(val)
				"Velocity", "BulletVelocity":
					val = Playfield.speed(val)
			# 保留原始条件（帧），由 `BulletManager` 每帧重估：Equal 一次性、Greater/Less 持续重放
			steps.append({
				"name": name, "value": val,
				"mode": ev.change_mode, "op": ev.op,
				"cv": float(ev.cond_value), "main": ev.contype == "TimeMain",
			})
	if steps.is_empty():
		return -1
	return bullets.register_program(steps)

func _init_state(em: BrgLoader.BrgEmitter) -> Dictionary:
	return {
		"emit_point": em.emit_point,
		"emit_radius": em.emit_radius,
		"radius_direction": em.radius_direction,
		"way": float(em.way),
		"circle": float(em.circle),
		"emit_direction": em.emit_direction,
		"range": em.range_deg,
		"count": float(em.count),
		"delta_v": em.delta_v,
		"delta_a": em.delta_a,
		"fired": {},          # "gi:ei" -> true（非循环事件只触发一次）
		"linear": [],         # [{name, remaining, per_frame}]
		"et": -1,
		# 发射器自身运动（自走小球）：位置相对宿主，逐帧积分
		"self_pos": Vector2.ZERO,
		"self_speed": em.self_velocity,
		"self_dir": em.self_direction,
		"self_accel": em.self_accelerate,
		"self_acc_dir": em.self_acc_dir,
	}

## 是否播完（非循环工程超过 MaxTime 即算完；循环工程永不完）
func finished() -> bool:
	if barrage == null:
		return true
	if barrage.loop:
		return false
	return barrage.max_time > 0 and age > barrage.max_time

# ------------------------------------------------------------------ 每帧

func step() -> void:
	if barrage == null or bullets == null:
		return
	age += 1
	_frame_ord = 0          # 每帧重置发弹序号基数（单弹身份用）
	# 循环工程：到 MaxTime 回到开头重放（同 SlimeStorm），重置事件触发状态并清场
	if barrage.loop and barrage.max_time > 0 and age >= barrage.max_time:
		age -= barrage.max_time
		for i in _states.size():
			var st: Dictionary = _states[i]
			st["fired"] = {}
			st["linear"] = []
			st["self_pos"] = Vector2.ZERO
			var em0: BrgLoader.BrgEmitter = barrage.emitters[i]
			st["self_speed"] = em0.self_velocity
			st["self_dir"] = em0.self_direction
			st["self_accel"] = em0.self_accelerate
			st["self_acc_dir"] = em0.self_acc_dir
		if bullets != null and bullets.has_method("clear") and not loop_keeps_bullets:
			bullets.clear()
	if bullets != null and bullets.has_method("set_main_time"):
		bullets.set_main_time(float(age) / 60.0)
	# 追踪弹（.brg ParaA 扩展）的引导目标：跟随宿主上下文里的自机位置
	# （游戏内 = 真自机；编辑器预览 = 可拖动的自机点；dump/sim 工具无此字段则跳过）
	if bullets != null and "homing_target" in bullets:
		bullets.homing_target = _player_pos()
	var n := _states.size()
	for idx in n:
		var em: BrgLoader.BrgEmitter = barrage.emitters[idx]
		if em.disabled:
			continue
		if age < em.start_time:
			continue
		if em.duration > 0 and age >= em.start_time + em.duration:
			continue
		var st: Dictionary = _states[idx]
		var et: int = age - em.start_time
		st["et"] = et
		# 发射器自身运动（自走小球）：先积分位置，再从新位置发射
		# self_speed/self_accel 是设计单位（px/帧、px/帧²），积分结果 ×SCALE 转世界
		var sacc := float(st["self_accel"])
		if sacc != 0.0:
			st["self_speed"] = float(st["self_speed"]) + sacc
		var sdir := deg_to_rad(float(st["self_dir"]))
		st["self_pos"] = (st["self_pos"] as Vector2) + Vector2(cos(sdir), sin(sdir)) * float(st["self_speed"]) * Playfield.SCALE
		_apply_events(em, st, et)
		_tick_linears(st)
		var circle := maxi(1, int(round(float(st["circle"]))))
		var fire: bool = (et % circle) == 0
		if em.emit_time_list.has(et):
			fire = true
		if fire:
			_emit(em, st)

# ------------------------------------------------------------------ 事件组

func _apply_events(em: BrgLoader.BrgEmitter, st: Dictionary, et: int) -> void:
	var fired: Dictionary = st["fired"]
	for gi in em.groups.size():
		var g = em.groups[gi]
		var events = g.events
		var loop_t: bool = g.loop and g.loop_circle > 0
		for ei in events.size():
			var ev = events[ei]
			# 事件身份用整数键（原先是 "gi:ei" 字符串拼接，每帧每命中事件都要格式化一次）
			var key: int = gi * 4096 + ei
			var t: int = et
			if loop_t:
				t = et % g.loop_circle
			if not _cond(ev, t):
				continue
			if not g.loop and fired.has(key):
				continue
			fired[key] = true
			var amount: float = ev.res * (1.0 if ev.change_mode == "Increase" else -1.0)
			if ev.change_type == "Linear" and ev.change_time > 1:
				(st["linear"] as Array).append({
					"name": ev.change_name, "remaining": ev.change_time,
					"per_frame": amount / float(ev.change_time),
				})
			else:
				_apply_delta(st, ev.change_name, amount)

func _tick_linears(st: Dictionary) -> void:
	var list: Array = st["linear"]
	var n := list.size()
	if n == 0:
		return
	# 原地压缩，不新建数组（原先每帧每发射器一个 keep 数组）
	var w := 0
	for r in n:
		var it: Dictionary = list[r]
		var rem := int(it["remaining"]) - 1
		it["remaining"] = rem
		_apply_delta(st, String(it["name"]), float(it["per_frame"]))
		if rem > 0:
			if w != r:
				list[w] = it
			w += 1
	if w != n:
		list.resize(w)

func _cond(ev, t: float) -> bool:
	var cv: float = ev.cond_value
	match ev.op:
		"Equal":
			return absf(t - cv) < 0.0001
		"Greater":
			return t > cv
		"Less":
			return t < cv
		"GreaterEqual":
			return t >= cv
		"LessEqual":
			return t <= cv
		"NotEqual":
			return absf(t - cv) >= 0.0001
	return false

func _apply_delta(st: Dictionary, name: String, d: float) -> void:
	match name:
		"EmitRadius":
			st["emit_radius"] = float(st["emit_radius"]) + d
		"RadiusDirection":
			st["radius_direction"] = float(st["radius_direction"]) + d
		"EmitterDirection", "EmitDirection":
			st["emit_direction"] = float(st["emit_direction"]) + d
		"Way":
			st["way"] = float(st["way"]) + d
		"Circle":
			st["circle"] = float(st["circle"]) + d
		"Range":
			st["range"] = float(st["range"]) + d
		"Count":
			st["count"] = float(st["count"]) + d
		"DeltaV":
			st["delta_v"] = float(st["delta_v"]) + d
		"DeltaA":
			st["delta_a"] = float(st["delta_a"]) + d
		# 发射器自身运动（自走小球）
		"Velocity":
			st["self_speed"] = float(st["self_speed"]) + d
		"Direction":
			st["self_dir"] = float(st["self_dir"]) + d
		"Acceleration":
			st["self_accel"] = float(st["self_accel"]) + d
		"AccDirection":
			st["self_acc_dir"] = float(st["self_acc_dir"]) + d

# ------------------------------------------------------------------ 发射

func _emit(em: BrgLoader.BrgEmitter, st: Dictionary) -> void:
	var origin := _emit_origin(em, st)
	var layers := maxi(1, int(round(float(st["count"]))))
	for layer_i in layers:
		var base_deg := float(st["emit_direction"])
		if base_deg <= BrgLoader.SENTINEL_AIM + 1.0:
			base_deg = rad_to_deg((_player_pos() - origin).angle())
		base_deg += float(st["delta_a"]) * float(layer_i)
		if em.ran_emit_dir != 0.0:
			base_deg += randf_range(-em.ran_emit_dir * 0.5, em.ran_emit_dir * 0.5)
		var rng := float(st["range"])
		if em.ran_range != 0.0:
			rng += randf_range(-em.ran_range * 0.5, em.ran_range * 0.5)
		var speed_dpf: float = em.bullet_velocity + float(st["delta_v"]) * float(layer_i)
		var way := maxi(1, int(round(float(st["way"]))))
		if em.ran_way != 0.0:
			way = maxi(1, way + int(round(randf_range(-em.ran_way, em.ran_way))))
		for a_deg in _spread_angles(base_deg, way, rng):
			# 单弹身份：该帧内第几发（**无论是否被压制都要自增**，
			# 否则压制掉一发会让后面所有弹的身份整体前移，补丁就错位了）
			var ord := _frame_ord
			_frame_ord += 1
			# 绝大多数对局没有单弹压制补丁：先判空，避免每发弹都拼一个字符串键
			if not suppressed.is_empty() and suppressed.has(_sup_key(em.index, age, ord)):
				suppressed_hits += 1
				continue
			_spawn_one(em, origin, a_deg, speed_dpf, ord)

## 单弹身份的字符串键
static func _sup_key(em_index: int, born: int, ord: int) -> String:
	return "%d:%d:%d" % [em_index, born, ord]

static func make_key(em_index: int, born: int, ord: int) -> String:
	return _sup_key(em_index, born, ord)

# ------------------------------------------------------------------ 单弹压制持久化

## `.brg` 旁边的补丁文件路径：`xxx.brg` → `xxx.brg.patch.json`
static func patch_path_for(brg_path: String) -> String:
	return brg_path + ".patch.json"

func set_suppressed(em_index: int, born: int, ord: int) -> String:
	var k := _sup_key(em_index, born, ord)
	suppressed[k] = true
	return k

func clear_suppressed() -> void:
	suppressed.clear()

## 从 sidecar 载入压制列表。文件不存在不算错误。
func load_patch(brg_path: String) -> bool:
	var p := patch_path_for(brg_path)
	if not FileAccess.file_exists(p):
		return false
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed == null or not (parsed is Dictionary):
		push_warning("[BrgPlayback] 补丁不是合法 JSON 对象：%s" % p)
		return false
	var list = (parsed as Dictionary).get("suppressed", [])
	if not (list is Array):
		return false
	suppressed.clear()
	for e in list:
		if e is String:
			suppressed[String(e)] = true
		elif e is Dictionary:
			# 也接受结构化写法 {em,born,ord}，便于人工编辑
			suppressed[_sup_key(int((e as Dictionary).get("em", -1)),
				int((e as Dictionary).get("born", -1)),
				int((e as Dictionary).get("ord", -1)))] = true
	print("[BrgPlayback] 压制补丁载入：%d 条 ← %s" % [suppressed.size(), p.get_file()])
	return true

## 写出 sidecar。**不改 `.brg` 本身**，原始工程保持无损。
func save_patch(brg_path: String, note := "") -> bool:
	var p := patch_path_for(brg_path)
	var list: Array = suppressed.keys()
	list.sort()
	var obj := {
		"version": 1,
		"_comment": "BrgEditor 单弹压制补丁。身份 = 发射器序号:出生帧:该帧内第几发。"
			+ "本文件不改动 .brg，SlimeStorm 仍可正常打开原工程。",
		"brg": brg_path,
		"count": list.size(),
		"suppressed": list,
	}
	if note != "":
		obj["note"] = note
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		push_error("[BrgPlayback] 写不了补丁：%s（导出后 res:// 只读）" % p)
		return false
	f.store_string(JSON.stringify(obj, "\t"))
	f.close()
	return true

func _spread_angles(base_deg: float, way: int, rng: float) -> Array:
	var out: Array = []
	if way <= 1:
		out.append(base_deg)
	elif rng >= 359.999:
		var step := 360.0 / float(way)
		for i in way:
			out.append(base_deg + step * float(i))
	else:
		var step := rng / float(way - 1)
		var start := base_deg - rng * 0.5
		for i in way:
			out.append(start + step * float(i))
	return out

func _emit_origin(em: BrgLoader.BrgEmitter, st: Dictionary) -> Vector2:
	var ep: Vector2 = st["emit_point"]
	var base: Vector2
	if ep.x <= BrgLoader.SENTINEL_SELF + 1.0 and ep.y <= BrgLoader.SENTINEL_SELF + 1.0:
		base = _host_pos()
		if apply_emitter_offset:
			base += Playfield.vec(em.position)
	else:
		base = Playfield.pos(ep.x, ep.y)
	base += (st.get("self_pos", Vector2.ZERO) as Vector2)   # 发射器自走位移
	var rr := float(st["emit_radius"])
	if rr > 0.0:
		var rd := float(st["radius_direction"])
		if rd <= BrgLoader.SENTINEL_AIM + 1.0:
			rd = rad_to_deg((_player_pos() - base).angle())
		base += Vector2(cos(deg_to_rad(rd)), sin(deg_to_rad(rd))) * Playfield.len(rr)
	return base

func _spawn_one(em: BrgLoader.BrgEmitter, origin: Vector2, a_deg: float,
		speed_dpf: float, ord: int = -1) -> void:
	var ov: Dictionary = visual_overrides.get(em.index, {})
	var at: Dictionary = ATLAS.get(em.texture_name, {})
	var base_size: float = float(at.get("size", DEFAULT_SIZE))
	if em.hi_res:
		base_size *= 0.5
	var visual: float = base_size * em.scale_w
	var cr: float = float(at.get("hit", base_size * 0.16))   # 判定半径取统一档位
	var tex: String = ov.get("tex", String(at.get("tex", DEFAULT_TEX)))
	var col: Color = em.color
	if ov.has("color"):
		col = ov["color"]
	# 2026-09-17：orb 系「白芯湛蓝」弹（bullet62_1 / bullet_orb → orb_azure）忽略 .brg 的
	# 淡紫/淡蓝色值，强制白色实例色 —— 保证纯白内质 + 湛蓝半透明轮廓不被染色。
	# `visual_overrides`（教程/自检）优先级更高，仍可覆盖。
	if bool(at.get("fixed_white", false)) and not ov.has("color"):
		col = Color.WHITE
	if ov.has("size"):
		visual = float(ov["size"])
	if ov.has("r"):
		cr = float(ov["r"])
	var y_scale: float = em.scale_h / maxf(em.scale_w, 0.0001)
	var speed: float = speed_dpf
	if em.ran_bullet_velocity != 0.0:
		speed += randf_range(-em.ran_bullet_velocity * 0.5, em.ran_bullet_velocity * 0.5)
	var bdir: float = a_deg + em.bullet_direction
	if em.ran_bullet_direction != 0.0:
		bdir += randf_range(-em.ran_bullet_direction * 0.5, em.ran_bullet_direction * 0.5)
	var rad := deg_to_rad(bdir)
	var info := {
		"x": origin.x, "y": origin.y,
		"vx": cos(rad) * Playfield.speed(speed),
		"vy": sin(rad) * Playfield.speed(speed),
		"em": em.index,
		"born": age,          # 出生帧：单弹身份的一部分
		"ord": ord,           # 该帧内第几发
		# 2026-09-17 起尺寸/判定为「世界单位直写」，不随 SCALE（弹幕大小冻结，见 Playfield 决议）
		"r": cr,
		"size": visual,
		"size_y": visual * y_scale,
		"life": em.life_time / 60.0,
		"color": col,
		"tex": tex,
		"graze": ov.get("graze", true),
		# 污染弹：显式 override 优先；否则贴图名含 "corrupt" 的自动视为污染弹
		# （命中不致死，改为累积污染值，见 Game.gd / BulletManager.F_CORRUPT）
		"corrupt": ov.get("corrupt", String(em.texture_name).contains("corrupt")),
	}
	if em.bullet_accel != 0.0:
		var acc: float = em.bullet_accel
		if em.ran_bullet_accel != 0.0:
			acc += randf_range(-em.ran_bullet_accel * 0.5, em.ran_bullet_accel * 0.5)
		info["accel"] = Playfield.accel(acc)
		info["acc_dir"] = em.bullet_acc_dir
	if em.angular_velocity != 0.0 or em.angle != 0.0 or em.angle_follows_dir:
		var rot := deg_to_rad(em.angle)
		if em.angle_follows_dir:
			rot = rad - PI * 0.5
		info["rot"] = rot
	if em.angular_velocity != 0.0:
		info["spin"] = deg_to_rad(em.angular_velocity) * 60.0
	if em.out_bound:
		info["outbound"] = true
	if em.protect100:
		info["protect"] = 100.0 / 60.0
	if em.unremoveable:
		info["unremoveable"] = true
	# 2026-09-17：hellrock 亮红熔缘（rim 层）已移除——用户要求所有弹幕取消硬性描边；
	# 碎块的可读性由 hellrock 贴图自身的熔岩裂纹承担。
	# 追踪弹（本工程扩展）：ParaA > 0 → 转向速率（度/帧），BulletManager 逐帧导向
	if em.para_a != 0.0:
		info["homing"] = em.para_a
	if em.index < _prog_ids.size():
		var pid: int = int(_prog_ids[em.index])
		if pid >= 0:
			info["prog"] = pid
	bullets.spawn(info)

# ------------------------------------------------------------------ 基准

func _host_pos() -> Vector2:
	if origin_callable.is_valid():
		return origin_callable.call()
	if host != null:
		return host.global_position
	return Playfield.pos(390.0, 480.0)

func _player_pos() -> Vector2:
	if host != null and host.has_method("get_player_pos"):
		return host.get_player_pos()
	return Playfield.pos(390.0, 800.0)
