extends Node
## DanmakuForge「弹幕锻坊」命令行入口 + 自检（autoload: Cli）
##
## 编辑器本体 = `scenes/DanmakuForge.tscn`。这个 autoload 只做三件事：
##   ① 解析启动参数（打开文件 / 自动播放 / 弹事件编辑器）
##   ② 编辑器自身的回归自检（格式往返 / 写盘端到端 / UI 逻辑 / 弹道指纹）
##   ③ 截图（窗口化验证用）
##
## 与目标工程的关系：本工具**只读写 `.brg` 文件本身**——不动工程侧的索引/清单文件，
## 也不调用工程侧的 exe。把改好的 `.brg` 存回工程约定的目录，运行侧下次载入即是新表现；
## **新增**一张卡时，按你自己工程的约定去登记（若是靠清单文件登记，就在那边加一条）。
##
## 用法：
##   DanmakuForge.exe                                          # 空编辑器
##   DanmakuForge.exe --open "<path>.brg"                      # 打开即编辑
##   DanmakuForge.exe --open "<path>.brg" --play --events      # 打开 + 播放 + 弹事件编辑器
##   DanmakuForge.exe --headless -- --selftest                 # 一次跑完全部自检
##   ... -- --roundtrip "<目录[,目录]>"                        # .brg 往返逐字节一致 + 改动隔离
##   ... -- --editor-test "<file.brg>"                         # 写盘端到端（删/增/改后仍可载入）
##   ... -- --ui-test "<file.brg>"                             # 编辑器 UI 逻辑集成
##   ... -- --bullet-fp 300 "<目录>"                           # 弹道确定性指纹（跨工程比对）
##   ... -- --brg-dump 30 / --brg-sim 120 "<file.brg>"         # 发射几何 / 弹道打印
##   ... -- --shot out.png --shot-delay 2 --quit-after 1       # 截图（**必须窗口化**）
##
## 兼容别名（沿用早先的参数名，仍可用）：
##   `--brg-editor` = `--open`、`--brg-editor-play` = `--play`、`--brg-editor-events` = `--events`、
##   `--brg-roundtrip` = `--roundtrip`、`--brg-editor-test` = `--editor-test`、`--brg-ui-test` = `--ui-test`
##
## 注意：`--headless` 下本工程退出码恒为 1（ObjectDB leak 警告，autoload 导致）；
## 判断测试结果请看输出里的 ✅/❌，不要看退出码。

var out_path := ""
var delay := 4.0
var delays: Array[float] = []   # --shot-delay 支持逗号分隔，一次运行多张
var quit_after := 0.0

## 启动时要打开的文件（--open / 旧别名 --brg-editor）
var _brg_editor := ""
var _brg_editor_requested := false
var _brg_editor_events := false
var _brg_editor_play := false

## 自检输入：默认用内置的 SlimeStorm 参考样本（纯格式回归，与任何工程无关）
var _brg_file := "res://samples/sample_tutorial_hell_spiral.brg"
var _brg_file_given := false
var _brg_roundtrip := ""        ## --roundtrip <目录[,目录]>；空 = res://samples
var _brg_editor_test := false   ## --editor-test
var _brg_ui_test := false       ## --ui-test
var _brg_dump := 0              ## --brg-dump N：打印前 N 帧的发射几何
var _brg_sim := 0               ## --brg-sim N：跑 N 帧并打印弹道
var _bullet_fp := 0             ## --bullet-fp N [目录]：弹道确定性指纹
var _fp_dir := "res://samples"  ## 弹道指纹扫描目录（跨工程比对时指向工程的 barrage 目录）
var _selftest := false          ## --selftest：一次跑完全部自检
var _selftest_fails := 0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var has_next: bool = i + 1 < args.size() and not args[i + 1].begins_with("--")
		match args[i]:
			# ——— 打开 / 演出 ———
			"--open", "--brg-editor":
				_brg_editor_requested = true
				if has_next:
					_brg_editor = args[i + 1]
			"--play", "--brg-editor-play":
				_brg_editor_requested = true
				_brg_editor_play = true
			"--events", "--brg-editor-events":
				_brg_editor_requested = true
				_brg_editor_events = true
			# ——— 截图 ———
			"--shot":
				if has_next:
					out_path = args[i + 1]
			"--shot-delay":
				if has_next:
					delays.clear()
					for part in args[i + 1].split(","):
						if part.strip_edges() != "":
							delays.append(float(part))
					delay = delays[0] if not delays.is_empty() else 4.0
			"--quit-after":
				if has_next:
					quit_after = float(args[i + 1])
			# ——— 自检 ———
			"--selftest":
				_selftest = true
			"--brg-file":
				if has_next:
					_brg_file = args[i + 1]
					_brg_file_given = true
			"--roundtrip", "--brg-roundtrip":
				if has_next:
					_brg_roundtrip = args[i + 1]
			"--editor-test", "--brg-editor-test":
				_brg_editor_test = true
				if has_next:
					_brg_file = args[i + 1]
			"--ui-test", "--brg-ui-test":
				_brg_ui_test = true
				if has_next:
					_brg_file = args[i + 1]
			"--brg-dump":
				if has_next:
					_brg_dump = int(args[i + 1])
			"--brg-sim":
				if has_next:
					_brg_sim = int(args[i + 1])
			"--bullet-fp":
				if has_next:
					_bullet_fp = int(args[i + 1])
				if i + 2 < args.size() and not args[i + 2].begins_with("--"):
					_fp_dir = args[i + 2]
	if _brg_editor_requested:
		# 必须**同步**设置：autoload 的 `_ready` 早于主场景，主场景 `_ready` 时就会读走这些静态量。
		# （早期写成 call_deferred，结果延迟到主场景 `_ready` 之后才设值 → `--open` 静默失效。）
		_apply_open_args()
	if out_path != "":
		_capture_after(delay)
	if _selftest:
		_run_selftest.call_deferred()
	elif _brg_dump > 0:
		_run_brg_dump.call_deferred()
	elif _brg_sim > 0:
		_run_brg_sim.call_deferred()
	elif _bullet_fp > 0:
		_run_bullet_fp.call_deferred()
	elif _brg_roundtrip != "":
		_run_brg_roundtrip.call_deferred()
	elif _brg_editor_test:
		_run_brg_editor_test.call_deferred()
	elif _brg_ui_test:
		_run_brg_ui_test.call_deferred()

## `--open` / `--play` / `--events` 的落地点：写进 `BrgEditor` 的启动静态量。
## autoload 的 `_ready` 早于主场景，所以主场景 `_ready` 时这些值已经就位，
## 不需要再切一次场景（主场景本来就是编辑器）。
func _apply_open_args() -> void:
	if _brg_editor != "":
		BrgEditor.pending_path = _brg_editor
	BrgEditor.pending_open_events = _brg_editor_events
	BrgEditor.pending_autoplay = _brg_editor_play

# ------------------------------------------------------------------ 自检编排

## --selftest：格式往返 → 写盘端到端 → UI 逻辑 → 弹道指纹，一次跑完并汇总
func _run_selftest() -> void:
	print("[SelfTest] === DanmakuForge 自检开始（样本 %s）===" % _brg_file)
	_brg_roundtrip = "res://samples"
	_run_brg_roundtrip()
	await get_tree().process_frame
	_run_brg_editor_test()
	await get_tree().process_frame
	await _run_brg_ui_test()
	await get_tree().process_frame
	if _bullet_fp <= 0:
		_bullet_fp = 300
	_run_bullet_fp()
	print("[SelfTest] %s（失败 %d 项）" % [
		"✅ 全部通过" if _selftest_fails == 0 else "❌ 有失败项", _selftest_fails])
	get_tree().quit(0 if _selftest_fails == 0 else 1)

## 每个自检的收尾：单跑时直接退出；`--selftest` 时只记失败数，交给 `_run_selftest` 收尾
func _cli_done(ok: bool) -> void:
	if _selftest:
		if not ok:
			_selftest_fails += 1
		return
	get_tree().quit(0 if ok else 1)

# ------------------------------------------------------------------ 截图

## --shot：等 delay（或 delays 列表）后截图。主场景就是编辑器，无需切场景。
func _capture_after(t: float) -> void:
	await get_tree().process_frame
	if delays.size() > 1:
		# 多个时间点：依次截图，文件名加 _t<秒> 后缀
		var prev := 0.0
		for d in delays:
			await get_tree().create_timer(maxf(0.05, d - prev)).timeout
			prev = d
			await _grab("%s_t%04d.png" % [out_path.get_basename(), int(round(d * 100.0))])
		if quit_after > 0.0:
			await get_tree().create_timer(quit_after).timeout
		get_tree().quit(0)
		return
	await get_tree().create_timer(t).timeout
	var err: int = await _grab(out_path)
	if quit_after > 0.0:
		await get_tree().create_timer(quit_after).timeout
	get_tree().quit(0 if err == OK else 1)

## 自检：记录 BrgPlayback 的发射几何（用于对照 .brg 手算公式）
class _BrgRec:
	extends Node
	var cur_frame := 0
	var out: Array = []
	func spawn(p: Dictionary) -> void:
		var d := p.duplicate()
		d["f"] = cur_frame
		out.append(d)

func _run_brg_dump() -> void:
	var brg = BrgLoader.load_file(_brg_file)
	if brg == null:
		print("[Dump] ❌ 载入失败：" + _brg_file)
		_cli_done(false)
		return
	var rec := _BrgRec.new()
	var pb = BrgPlayback.new(brg, rec, null)
	pb.origin_callable = func() -> Vector2: return Playfield.pos(390.0, 240.0)
	for f in _brg_dump:
		rec.cur_frame = pb.age + 1
		pb.step()
	var per_frame := {}
	for d in rec.out:
		var f: int = d["f"]
		if not per_frame.has(f):
			per_frame[f] = []
		per_frame[f].append(d)
	var frames := per_frame.keys()
	frames.sort()
	print("[Dump] %s；发射器 %d 个；前 %d 帧共发射 %d 发" % [
		_brg_file, brg.emitters.size(), _brg_dump, rec.out.size()])
	for f in frames:
		var by_em := {}
		for d in per_frame[f]:
			var e: int = d.get("em", 0)
			if not by_em.has(e):
				by_em[e] = []
			by_em[e].append(d)
		var ems := by_em.keys()
		ems.sort()
		for e in ems:
			var g: Array = by_em[e]
			var s0: Dictionary = g[0]
			var ang := rad_to_deg(atan2(float(s0["vy"]), float(s0["vx"])))
			print("  f=%-4d em=%d n=%-2d origin=(%.1f,%.1f) v=(%.1f,%.1f) ang=%.1f size=%.1f life=%.2f tex=%s" % [
				f, e, g.size(), s0["x"], s0["y"], s0["vx"], s0["vy"],
				ang, s0["size"], s0["life"], s0["tex"]])
	_cli_done(true)

## 自检：用真的 BulletManager 跑 .brg，打印 0 号弹的速度/朝向随时间变化，
## 用于验证 BulletEventGroupList（如“先直飞、到点再下坠”）。
func _run_brg_sim() -> void:
	var brg = BrgLoader.load_file(_brg_file)
	if brg == null:
		print("[Sim] ❌ 载入失败：" + _brg_file)
		_cli_done(false)
		return
	var mgr = load("res://scripts/core/BulletManager.gd").new()
	mgr.name = "BrgSimBullets"
	add_child(mgr)
	var pb = BrgPlayback.new(brg, mgr, null)
	pb.origin_callable = func() -> Vector2: return Playfield.pos(390.0, 240.0)
	print("[Sim] emitters=%d em0.bullet_groups=%d mgr._programs=%d" % [
		brg.emitters.size(), brg.emitters[0].bullet_groups.size(), mgr._programs.size()])
	var marks := {1: true, 20: true, 40: true, 41: true, 42: true, 55: true, 59: true, 60: true, 61: true, 80: true}
	for f in _brg_sim:
		pb.step()
		mgr.step(1.0 / 60.0)
		if marks.has(f + 1):
			var vx: float = mgr._vx[0]
			var vy: float = mgr._vy[0]
			print("[Sim] f=%-4d bullet0 pos=(%.1f,%.1f) v=(%.1f,%.1f) speed=%.1f ang=%.1f prog=%d pi=%d accel=%.1f adir=%.1f" % [
				f + 1, mgr._px[0], mgr._py[0], vx, vy,
				sqrt(vx * vx + vy * vy), rad_to_deg(atan2(vy, vx)),
				mgr._prog[0], mgr._prog_i[0], mgr._accel[0], mgr._acc_dir[0]])
	print("[Sim] 结束：活动弹 %d" % mgr.active_count())
	_cli_done(true)

## 回归：弹幕确定性指纹。对 `barrage/` 下全部 `.brg`，用真 BulletManager 跑固定帧数，
## 打印「活动弹数 / 击杀数 / 位置滚动校验和」。
##
## 用途：`BulletManager` / `BrgPlayback` / 发弹路径重构的**逐帧等价性**门禁——
## 与渲染帧率、自机位置无关（不跑碰撞、不跑玩家），改前改后必须逐字节一致。
## 固定 seed 保证 `.brg` 里的 randf 序列一致。
func _run_bullet_fp() -> void:
	var files: Array = []
	_scan_brg(_fp_dir, files)
	files = files.filter(func(p): return not String(p).contains("/_backup"))
	files.sort()
	var mgr = load("res://scripts/core/BulletManager.gd").new()
	mgr.name = "BulletFpMgr"
	add_child(mgr)
	var t0 := Time.get_ticks_msec()
	for path in files:
		seed(20260916)                     # 每个文件独立固定种子（randf 序列可复现）
		mgr.clear()
		var killed0: int = mgr.killed_total
		var brg = BrgLoader.load_file(path)
		if brg == null:
			print("[BulletFP] %s LOAD_FAIL" % path)
			continue
		var pb = BrgPlayback.new(brg, mgr, null)
		pb.origin_callable = func() -> Vector2: return Playfield.pos(390.0, 200.0)
		pb.loop_keeps_bullets = true
		var acc := 0.0
		var peak := 0
		for f in _bullet_fp:
			pb.step()
			mgr.step(1.0 / 60.0)
			var n: int = mgr.active_count()
			peak = maxi(peak, n)
			acc += float(n) * 0.25
			if f % 60 == 59:               # 每 60 帧采一次完整状态（滚动校验，抓中途分叉）
				acc += _bullet_fp_of(mgr.dump_positions())
		var sum_end := _bullet_fp_of(mgr.dump_positions())
		print("[BulletFP] %-28s n=%-4d peak=%-4d killed=%-4d acc=%.6f end=%.6f" % [
			path.get_file(), mgr.active_count(), peak, mgr.killed_total - killed0, acc, sum_end])
	print("[BulletFP] files=%d frames=%d ms=%d" % [files.size(), _bullet_fp,
		Time.get_ticks_msec() - t0])
	_cli_done(true)

## 顺序无关、且不受浮点噪声影响的状态校验和：
## 位置/半径量化到 0.001px 后按**整数**累加（GDScript int 是 64 位，无溢出）。
## 换遍历顺序（活动列表重构）不误报；任何真实位移变化都会被抓到。
static func _bullet_fp_of(pos: PackedFloat32Array) -> float:
	var acc := 0
	var mix := 0
	var n := pos.size() / 3
	for k in n:
		var x := int(round(pos[k * 3] * 1000.0))
		var y := int(round(pos[k * 3 + 1] * 1000.0))
		var r := int(round(pos[k * 3 + 2] * 100.0))
		acc += x + y * 3 + r * 7
		mix += x * x + y * y + r * r
	return float(acc) + float(mix % 1000000007) * 1e-6

## 回归：对目录下全部 .brg 做「解析 → 序列化 → 逐字节比对」，并附带「改动隔离」测试
## （改一个字段后，必须只有那一行变化）。规格见 scripts/editor/BrgDocument.gd。
func _run_brg_roundtrip() -> void:
	var files: Array = []
	for part in _brg_roundtrip.split(","):
		var d := part.strip_edges()
		if d != "":
			_scan_brg(d, files)
	if files.is_empty():
		print("[RT] ❌ 没找到 .brg 文件：" + _brg_roundtrip)
		_cli_done(false)
		return

	var ok := 0
	var fails: Array = []
	for f in files:
		var orig := _read_text_keep_cr(f)
		if orig == "":
			fails.append([f, "打不开"])
			continue
		var doc := BrgDocument.parse_text(orig)
		if doc == null:
			fails.append([f, "解析失败"])
			continue
		var out := doc.to_text()
		if out == orig:
			ok += 1
		else:
			fails.append([f, "首个差异 %s" % _first_diff(orig, out)])

	print("[RT] 往返逐字节一致 %d/%d" % [ok, files.size()])
	for e in fails.slice(0, 8):
		print("  ❌ %s：%s" % [e[0].get_file(), e[1]])

	# 改动隔离测试：改 Way → 只有 Way 那一行应该变
	var edit_ok := 0
	var edit_fails: Array = []
	for f in files:
		var orig := _read_text_keep_cr(f)
		if orig == "":
			continue
		var doc := BrgDocument.parse_text(orig)
		if doc == null:
			continue
		var ems := doc.emitter_nodes()
		if ems.is_empty():
			continue
		var cur_way: int = doc.get_i(ems[0], "Way", 7)
		var new_way: int = 7 if cur_way != 7 else 8
		doc.set_field(ems[0], "Way", new_way)
		var edited := doc.to_text()
		var ol := orig.split("\n")
		var nl := edited.split("\n")
		if ol.size() != nl.size():
			edit_fails.append([f, "行数变了 %d → %d" % [ol.size(), nl.size()]])
			continue
		var diff := 0
		var seen := ""
		for i in ol.size():
			if ol[i] != nl[i]:
				diff += 1
				seen = ol[i].strip_edges() + " → " + nl[i].strip_edges()
		# 期望：恰好 1 行变化，且变化后就是 <Way>new</Way>
		if diff == 1 and seen.ends_with("→ <Way>%d</Way>" % new_way):
			edit_ok += 1
		else:
			edit_fails.append([f, "%d 行变化（%s）" % [diff, seen]])

	print("[RT] 改动隔离（Way→7 仅 1 行变化）%d/%d" % [edit_ok, files.size()])
	for e in edit_fails.slice(0, 8):
		print("  ❌ %s：%s" % [e[0].get_file(), e[1]])

	var all_ok: bool = fails.is_empty() and edit_fails.is_empty()
	print("[RT] %s" % ("✅ 全部通过（保持 SlimeStorm 兼容）" if all_ok else "❌ 有失败项"))
	_cli_done(all_ok)

## 按字节读文件再 UTF-8 解码：`get_as_text()` 会吃掉 \r，而 .brg 是 CRLF，
## 往返比对必须保留 CR。
func _read_text_keep_cr(path: String) -> String:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return ""
	var b := fa.get_buffer(fa.get_length())
	fa.close()
	return b.get_string_from_utf8()

func _scan_brg(dir_path: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var full := dir_path.path_join(n)
		if d.current_is_dir():
			if n != "." and n != "..":
				_scan_brg(full, out)
		elif n.to_lower().ends_with(".brg"):
			out.append(full)
		n = d.get_next()
	d.list_dir_end()

func _first_diff(a: String, b: String) -> String:
	var n: int = mini(a.length(), b.length())
	for i in n:
		if a[i] != b[i]:
			return "@%d 原=%s 新=%s" % [
				i, a.substr(i, 40).strip_edges(), b.substr(i, 40).strip_edges()]
	if a.length() != b.length():
		return "长度 %d vs %d" % [a.length(), b.length()]
	return "无差异"

## 验证「语义 A 删除发射器 → 存盘」的结果既无损又仍被语义层接受：
##   1. 存盘后再解析一次必须与存盘内容逐字节一致（幂等无损）
##   2. 差异必须恰好是一整块 <EmitterBullet>…</EmitterBullet>，其余行一模一样
##   3. `BrgLoader`（语义层 / SlimeStorm 同构）必须仍能载入且发射器数正确
##   4. 新增发射器后同样成立
func _run_brg_editor_test() -> void:
	var src := _brg_file
	var orig := _read_text_keep_cr(src)
	if orig == "":
		print("[EdTest] ❌ 读不到源文件：" + src)
		_cli_done(false)
		return
	var tmp_dir := "user://brged_test"
	DirAccess.make_dir_recursive_absolute(tmp_dir)
	var work := tmp_dir + "/work.brg"
	var fails: Array = []

	var doc := BrgDocument.load_file(src)
	if doc == null:
		print("[EdTest] ❌ BrgDocument 打不开 " + src)
		_cli_done(false)
		return
	var n0 := doc.emitter_count()
	print("[EdTest] 源 %s：%d 个发射器" % [src.get_file(), n0])
	doc.source_path = work
	if not doc.save():
		print("[EdTest] ❌ 存盘失败")
		_cli_done(false)
		return

	# --- 1) 删一个发射器 ---
	var d2 := BrgDocument.load_file(work)
	var target: BrgDocument.XNode = d2.emitter_nodes()[n0 - 1]
	d2.delete_emitter(target)
	var del_path := tmp_dir + "/deleted.brg"
	d2.source_path = del_path
	d2.save()
	var del_text := _read_text_keep_cr(del_path)

	var rt := BrgDocument.parse_text(del_text)
	if rt == null or rt.to_text() != del_text:
		fails.append("删除后存盘再解析不一致（不是幂等无损）")
	if del_text.count("<EmitterBullet>") != n0 - 1:
		fails.append("删除后 EmitterBullet 数应为 %d，实际 %d" % [
			n0 - 1, del_text.count("<EmitterBullet>")])

	var brg = BrgLoader.load_file(del_path)
	if brg == null:
		fails.append("删除后 BrgLoader 载入失败（SlimeStorm 兼容性风险）")
	elif brg.emitters.size() != n0 - 1:
		fails.append("删除后语义层发射器数 %d ≠ %d" % [brg.emitters.size(), n0 - 1])

	# 差异必须恰好是「删掉一整块连续的行」，其余行逐行一致
	var ol := orig.split("\n")
	var dl := del_text.split("\n")
	var removed_count := ol.size() - dl.size()
	var first := 0
	while first < mini(ol.size(), dl.size()) and ol[first] == dl[first]:
		first += 1
	# 删掉 ol[first .. first+removed_count-1] 之后必须与 dl 完全一致
	var tail_ok := true
	if first + removed_count > ol.size():
		tail_ok = false
	else:
		var o_rest := Array(ol).slice(first + removed_count)
		var d_rest := Array(dl).slice(first)
		if o_rest.size() != d_rest.size():
			tail_ok = false
		else:
			for i in o_rest.size():
				if o_rest[i] != d_rest[i]:
					tail_ok = false
					break
	if not tail_ok:
		fails.append("删除不是「连续整块移除」：多改了其它行")
	var removed := Array(ol).slice(first, first + removed_count)
	if removed.is_empty():
		fails.append("没有检测到被删除的行块")
	else:
		var head := String(removed[0]).strip_edges()
		var tail := String(removed[removed.size() - 1]).strip_edges()
		if head != "<EmitterBullet>" or tail != "</EmitterBullet>":
			fails.append("删除的不是完整发射器块：首=%s 尾=%s" % [head, tail])
		print("[EdTest] 删除块 = 第 %d~%d 行（%d 行），其余行逐行一致=%s" % [
			first + 1, first + removed_count, removed_count, str(tail_ok)])

	# --- 2) 新增发射器 ---
	var d3 := BrgDocument.load_file(del_path)
	d3.add_emitter("BulletNew")
	var add_path := tmp_dir + "/added.brg"
	d3.source_path = add_path
	d3.save()
	var add_text := _read_text_keep_cr(add_path)
	var rt3 := BrgDocument.parse_text(add_text)
	if rt3 == null or rt3.to_text() != add_text:
		fails.append("新增后存盘再解析不一致")
	if add_text.count("<EmitterBullet>") != n0:
		fails.append("新增后 EmitterBullet 数应为 %d，实际 %d" % [
			n0, add_text.count("<EmitterBullet>")])
	var brg3 = BrgLoader.load_file(add_path)
	if brg3 == null:
		fails.append("新增后 BrgLoader 载入失败")
	else:
		if brg3.emitters.size() != n0:
			fails.append("新增后语义层发射器数 %d ≠ %d" % [brg3.emitters.size(), n0])
		# 新发射器必须能被语义层读出合理几何
		var ne = brg3.emitters[n0 - 1]
		print("[EdTest] 新发射器语义层：tag=%s way=%d circle=%d v=%.2f life=%.0f" % [
			ne.tag, ne.way, ne.circle, ne.bullet_velocity, ne.life_time])
		if ne.way < 1:
			fails.append("新发射器 Way 非法：%d" % ne.way)

	# 新发射器不得有重复的容器元素（Position/EmitPoint/EmitDirection/RadiusDirection）。
	# 这是 add_emitter 真实踩过的 bug：同一容器既当标量写一遍又当容器建一遍，
	# 结果每个发射器多出 <Position>0</Position> 之类，SlimeStorm 会报「XML 文档中有错误」。
	var dup: Array = []
	for tag in ["Position", "EmitPoint", "EmitDirection", "RadiusDirection"]:
		var cnt: int = add_text.count("<%s>" % tag)
		if cnt != n0:
			dup.append("%s×%d" % [tag, cnt])
	if not dup.is_empty():
		fails.append("新增发射器容器元素重复（每个应 1 份，共 %d）：%s" % [n0, str(dup)])
	else:
		print("[EdTest] 新增发射器无重复容器元素（Position/EmitPoint/EmitDirection/RadiusDirection 各 %d 份）✅" % n0)

	# --- 3) 字段编辑（发射角度写自机狙）后仍可用 ---
	var d4 := BrgDocument.load_file(add_path)
	var e0: BrgDocument.XNode = d4.emitter_nodes()[0]
	d4.set_angle(e0, "EmitDirection", BrgDocument.SENTINEL_AIM)
	var aim_path := tmp_dir + "/aim.brg"
	d4.source_path = aim_path
	d4.save()
	var brg4 = BrgLoader.load_file(aim_path)
	if brg4 == null:
		fails.append("写自机狙后 BrgLoader 载入失败")
	elif absf(brg4.emitters[0].emit_direction - BrgDocument.SENTINEL_AIM) > 1.0:
		fails.append("自机狙哨兵没被语义层读到：%f" % brg4.emitters[0].emit_direction)
	else:
		print("[EdTest] 自机狙哨兵语义层读回 OK（%.0f）" % brg4.emitters[0].emit_direction)

	if fails.is_empty():
		print("[EdTest] ✅ 全部通过（删除/新增/字段编辑都不破坏 SlimeStorm 兼容）")
	else:
		for m in fails:
			print("  ❌ " + m)
		print("[EdTest] ❌ %d 项失败" % fails.size())
	_cli_done(fails.is_empty())

## 无头实例化 BrgEditor 场景，直接驱动 UI 逻辑，验证「选中 → 拖拽 → 删除 → 撤销 → 改属性」
## 这条链路的接线正确（不是只验证脚本能编译）。
func _run_brg_ui_test() -> void:
	var scene: PackedScene = load("res://scenes/DanmakuForge.tscn")
	if scene == null:
		print("[UI] ❌ 载入不了 BrgEditor.tscn")
		_cli_done(false)
		return
	var ed = scene.instantiate()
	add_child(ed)
	await get_tree().process_frame
	await get_tree().process_frame

	var fails: Array = []
	ed._open_path(_brg_file)
	await get_tree().process_frame
	if ed.doc == null:
		print("[UI] ❌ 编辑器打不开 " + _brg_file)
		_cli_done(false)
		return
	var n0: int = ed.doc.emitter_count()
	print("[UI] 载入 %s：%d 个发射器" % [_brg_file.get_file(), n0])

	# 1) 结构树条目数应与发射器数一致
	var tree_items := 0
	var it = ed.tree.get_root().get_first_child()
	while it != null:
		tree_items += 1
		it = it.get_next()
	if tree_items != n0:
		fails.append("结构树条目 %d ≠ 发射器数 %d" % [tree_items, n0])
	else:
		print("[UI] 结构树条目 = %d ✅" % tree_items)

	# 2) 画布点选
	ed._on_canvas_click(0, false)
	if ed.selected != [0]:
		fails.append("画布点选失败：selected=%s" % str(ed.selected))
	else:
		print("[UI] 画布点选 #0 ✅")

	# 3) 画布拖拽改位置（写 Position / EmitPoint）
	var node: BrgDocument.XNode = ed.doc.emitter_nodes()[0]
	var self_ref: bool = ed._is_self_ref(node)
	var before_pos: Vector2 = ed.doc.get_vec(node, "Position", Vector2.ZERO) if self_ref \
		else ed.doc.get_vec(node, "EmitPoint", Vector2.ZERO)
	ed.canvas._drag_index = 0
	ed.canvas._drag_mode = BrgCanvas.DragMode.MOVE
	ed.canvas._drag_offset = Vector2.ZERO
	ed.canvas._apply_drag(Vector2(123.0, 456.0))
	var after_pos: Vector2 = ed.doc.get_vec(node, "Position", Vector2.ZERO) if self_ref \
		else ed.doc.get_vec(node, "EmitPoint", Vector2.ZERO)
	if after_pos == before_pos:
		fails.append("拖拽没有改变位置")
	elif after_pos == Vector2(123, 456) and not self_ref:
		print("[UI] 拖拽改 EmitPoint → (123,456) ✅")
	elif self_ref:
		var want: Vector2 = Vector2(123, 456) - Vector2(ed.host_origin)
		if after_pos == want.round():
			print("[UI] 拖拽改 Position → %s（相对宿主）✅" % str(after_pos))
		else:
			fails.append("跟随宿主的拖拽结果不对：%s ≠ %s" % [str(after_pos), str(want.round())])
	else:
		fails.append("绝对发射点拖拽结果不对：%s" % str(after_pos))

	# 手柄位置诊断：确认每个手柄实际落在哪里（肉眼判断容易出错）
	var anchor_dbg: Vector2 = ed.canvas._emitter_canvas_pos(node)
	var hp_dbg: Array = []
	for hid in [BrgCanvas.H_DIR, BrgCanvas.H_RANGE_LO, BrgCanvas.H_RANGE_HI, BrgCanvas.H_RADIUS]:
		if not ed.canvas._handle_available(node, hid):
			hp_dbg.append("hid%d=不可用" % hid)
			continue
		var hp: Vector2 = ed.canvas._handle_pos(node, anchor_dbg, hid)
		hp_dbg.append("hid%d=(%+.0f,%+.0f)" % [hid, hp.x - anchor_dbg.x, hp.y - anchor_dbg.y])
	print("[UI] 手柄相对偏移: " + " ".join(PackedStringArray(hp_dbg)))
	print("[UI] RadiusDirection aim=%s EmitRadius=%.1f（容器的 text 应为空）" % [
		str(ed.canvas._is_aim(node, "RadiusDirection")),
		ed.doc.get_f(node, "EmitRadius", 0.0)])
	# 容器元素的 text 不得被当成数值：get_field 对容器必须返回默认值
	if ed.doc.get_field(node, "RadiusDirection", "X") != "X":
		fails.append("get_field 对容器元素没有返回默认值（把缩进空白当值了）")
	elif ed.doc.get_field(node, "EmitDirection", "") != "":
		fails.append("get_field(EmitDirection) 应为空字符串")
	else:
		print("[UI] 容器元素的 text 不再被当成数值 ✅")

	# 3b) 手柄拖拽：发射角度 / 范围 / 发射半径（P1 新增的直接操控）
	var anchor: Vector2 = ed.canvas._emitter_canvas_pos(node)
	ed.canvas._drag_index = 0
	ed.canvas.snap = false
	ed.canvas._drag_mode = BrgCanvas.DragMode.DIRECTION
	ed.canvas._apply_drag(anchor + Vector2(0, -200))        # 正上方 = -90°
	var ang: float = ed.doc.get_angle(node, "EmitDirection", 999.0)
	if absf(ang - (-90.0)) > 0.5:
		fails.append("拖拽发射角度 → %.1f°，期望 -90°" % ang)
	else:
		print("[UI] 拖拽改发射角度 → %.1f° ✅" % ang)

	# Shift 吸附 15°
	ed.canvas.snap = true
	ed.canvas._apply_drag(anchor + Vector2(200, -60))       # ≈ -16.7° → 吸附 -15°
	var ang_snap: float = ed.doc.get_angle(node, "EmitDirection", 999.0)
	if absf(ang_snap - (-15.0)) > 0.6:
		fails.append("Shift 吸附 → %.1f°，期望 -15°" % ang_snap)
	else:
		print("[UI] Shift 吸附发射角度 → %.1f° ✅" % ang_snap)
	ed.canvas.snap = false

	# 范围：相对拖拽。幽灵手柄在 base±15°，拖到离基准 40° → Range = 2×(40−15) = 50°
	ed.doc.set_angle(node, "EmitDirection", -90.0)
	ed.doc.set_field(node, "Range", 0.0)
	var r0: float = ed.doc.get_f(node, "Range", -1.0)
	if absf(r0) > 0.01:
		fails.append("前置：Range 未能置 0（实际 %.1f）" % r0)
	ed.canvas.begin_drag(0, BrgCanvas.DragMode.RANGE, BrgCanvas.H_RANGE_HI,
		anchor + BrgCanvas._deg_vec(-90.0 + BrgCanvas.GHOST_RANGE_HALF) * BrgCanvas.RANGE_FAN_LEN)
	ed.canvas._apply_drag(anchor + BrgCanvas._deg_vec(-50.0) * BrgCanvas.RANGE_FAN_LEN)
	var rng: float = ed.doc.get_f(node, "Range", -1.0)
	if absf(rng - 50.0) > 0.8:
		fails.append("拖拽范围 → %.1f°，期望 50°" % rng)
	else:
		print("[UI] 拖拽改范围 → %.1f°（相对拖拽，无跳变）✅" % rng)

	# 满环（Range=360）时手柄落在 base±90，向内拖 30° → 300°，不应跳到底
	ed.doc.set_field(node, "Range", 360.0)
	ed.canvas.begin_drag(0, BrgCanvas.DragMode.RANGE, BrgCanvas.H_RANGE_HI,
		anchor + BrgCanvas._deg_vec(-90.0 + 90.0) * BrgCanvas.RANGE_FAN_LEN)
	ed.canvas._apply_drag(anchor + BrgCanvas._deg_vec(-90.0 + 60.0) * BrgCanvas.RANGE_FAN_LEN)
	var rng_full: float = ed.doc.get_f(node, "Range", -1.0)
	if absf(rng_full - 300.0) > 1.0:
		fails.append("满环向内拖 → %.1f°，期望 300°" % rng_full)
	else:
		print("[UI] 满环向内拖 → %.1f°（无跳变）✅" % rng_full)

	# 发射半径 + 半径方向
	ed.canvas._drag_mode = BrgCanvas.DragMode.RADIUS
	ed.canvas._apply_drag(anchor + Vector2(120, 0))
	var er: float = ed.doc.get_f(node, "EmitRadius", -1.0)
	var rd: float = ed.doc.get_angle(node, "RadiusDirection", 999.0)
	if absf(er - 120.0) > 1.0:
		fails.append("拖拽发射半径 → %.1f，期望 120" % er)
	elif absf(rd) > 0.6:
		fails.append("拖拽半径方向 → %.1f°，期望 0°" % rd)
	else:
		print("[UI] 拖拽改发射半径 → %.0f + 半径方向 %.0f° ✅" % [er, rd])

	# 自机狙发射器不应提供方向手柄（那个角度运行时才算得出）
	ed.doc.set_angle(node, "EmitDirection", BrgDocument.SENTINEL_AIM)
	if ed.canvas._handle_available(node, BrgCanvas.H_DIR):
		fails.append("自机狙发射器不应提供方向手柄")
	else:
		print("[UI] 自机狙不提供方向手柄（角度是运行时动态的）✅")
	# 但范围手柄仍应可用（Range 只是一个对称张角）
	if not ed.canvas._handle_available(node, BrgCanvas.H_RANGE_LO):
		fails.append("自机狙应仍提供范围手柄")
	else:
		print("[UI] 自机狙仍提供范围手柄 ✅")
	ed.doc.set_angle(node, "EmitDirection", 90.0)

	# 3c) 数值就地同步（拖拽时属性面板要跟着变，且不能触发回写）
	ed.refresh_property_values()
	if ed._suspend_widgets:
		fails.append("refresh_property_values 没有复位 _suspend_widgets")
	else:
		print("[UI] 属性面板数值就地同步（不重建控件）✅")

	# 4) 属性面板写值（批量落到选中项）
	ed.selected = [0]
	ed._apply_field("Way", 11)
	if ed.doc.get_i(ed.doc.emitter_nodes()[0], "Way", -1) != 11:
		fails.append("属性写入 Way=11 没生效")
	else:
		print("[UI] 属性面板写 Way=11 ✅")

	# 5) 删除（语义 A）
	ed.selected = [0]
	ed._on_delete_pressed()
	if ed.doc.emitter_count() != n0 - 1:
		fails.append("删除后发射器数 %d ≠ %d" % [ed.doc.emitter_count(), n0 - 1])
	else:
		print("[UI] 删除发射器：%d → %d ✅" % [n0, ed.doc.emitter_count()])

	# 6) 撤销 / 重做
	ed._on_undo_pressed()
	if ed.doc.emitter_count() != n0:
		fails.append("撤销后发射器数 %d ≠ %d" % [ed.doc.emitter_count(), n0])
	else:
		print("[UI] 撤销恢复为 %d ✅" % ed.doc.emitter_count())
	ed._on_redo_pressed()
	if ed.doc.emitter_count() != n0 - 1:
		fails.append("重做后发射器数 %d ≠ %d" % [ed.doc.emitter_count(), n0 - 1])
	else:
		print("[UI] 重做回到 %d ✅" % ed.doc.emitter_count())

	# 7) 新建发射器
	ed._on_undo_pressed()
	ed._on_add_pressed()
	if ed.doc.emitter_count() != n0 + 1:
		fails.append("新建后发射器数 %d ≠ %d" % [ed.doc.emitter_count(), n0 + 1])
	else:
		print("[UI] 新建发射器：%d → %d ✅" % [n0, ed.doc.emitter_count()])

	# 7b) 属性面板字段覆盖：除两个事件组容器外，其余 91 个 EmitterBullet 字段都应露出 UI
	var spec_tags := {}
	for spec in BrgEditor.FIELD_SPECS:
		spec_tags[String(spec["tag"])] = true
	var missing_specs: Array = []
	for t in BrgDocument.EMITTER_ORDER:
		if t == "EventGroupList" or t == "BulletEventGroupList":
			continue
		if not spec_tags.has(t):
			missing_specs.append(t)
	if not missing_specs.is_empty():
		fails.append("属性面板缺少字段：%s" % str(missing_specs))
	else:
		print("[UI] 属性面板覆盖全部 91 个非容器 EmitterBullet 字段 ✅")

	# 7c) 新增字段可写：字符串 / 颜色 / 整数等类型
	ed.selected = [0]
	ed._apply_field("Blend", "AddBlend")
	ed._apply_field("ReflectEdges", "Top Bottom")
	ed._apply_field("ColorValue", "ARGBColor:128:10:20:30")
	ed._apply_field("ColorType", "Custom")
	ed._apply_field("GhostingCount", 7)
	var f0: BrgDocument.XNode = ed.doc.emitter_nodes()[0]
	if ed.doc.get_field(f0, "Blend", "") != "AddBlend" \
			or ed.doc.get_field(f0, "ReflectEdges", "") != "Top Bottom" \
			or ed.doc.get_field(f0, "ColorValue", "") != "ARGBColor:128:10:20:30" \
			or ed.doc.get_field(f0, "ColorType", "") != "Custom" \
			or ed.doc.get_i(f0, "GhostingCount", -1) != 7:
		fails.append("新增属性字段写入失败")
	else:
		print("[UI] 新增属性字段可写（Blend/ReflectEdges/ColorValue/ColorType/GhostingCount）✅")

	# 7d) EmitTimeList（intlist 类型）
	ed.selected = [0]
	ed._apply_int_list("EmitTimeList", "10, 40, 90")
	if ed.doc.get_int_list(f0, "EmitTimeList") != [10, 40, 90]:
		fails.append("EmitTimeList 写入失败：%s" % str(ed.doc.get_int_list(f0, "EmitTimeList")))
	else:
		print("[UI] EmitTimeList 逗号列表写入 ✅")

	# 7e) 画布 Way 条数手柄：拖动改变 Way
	ed.selected = [0]
	var wn: BrgDocument.XNode = ed.doc.emitter_nodes()[0]
	ed.doc.set_field(wn, "Way", 4)
	var wpos: Vector2 = ed.canvas._emitter_canvas_pos(wn)
	var wdir: Vector2 = BrgCanvas._deg_vec(ed.canvas._base_dir_deg(wn) + 90.0)
	ed.canvas.begin_drag(0, BrgCanvas.DragMode.WAY, BrgCanvas.H_WAY,
		wpos + wdir * ed.canvas._way_handle_r(wn))
	ed.canvas._apply_drag(wpos + wdir * (BrgCanvas.WAY_R_BASE + 6.0 * BrgCanvas.WAY_R_STEP))
	var wnew: int = ed.doc.get_i(wn, "Way", -1)
	if wnew != 7:
		fails.append("Way 手柄 → %d，期望 7" % wnew)
	else:
		print("[UI] Way 条数手柄拖动 → %d ✅" % wnew)

	# 7f) 移动吸附 60px 网格
	ed.selected = [0]
	ed.canvas.snap_grid = true
	ed.canvas._drag_index = 0
	ed.canvas._drag_mode = BrgCanvas.DragMode.MOVE
	ed.canvas._drag_offset = Vector2.ZERO
	ed.canvas._apply_drag(Vector2(123.0, 456.0))
	var snap_np := Vector2(123.0, 456.0).snapped(Vector2(60, 60))
	var snap_ok := false
	if ed._is_self_ref(wn):
		snap_ok = ed.doc.get_vec(wn, "Position", Vector2.ZERO).is_equal_approx(
			(snap_np - Vector2(ed.host_origin)).round())
	else:
		snap_ok = ed.doc.get_vec(wn, "EmitPoint", Vector2.ZERO).is_equal_approx(snap_np.round())
	ed.canvas.snap_grid = false
	if not snap_ok:
		fails.append("移动吸附网格失败（目标 %s）" % str(snap_np))
	else:
		print("[UI] 移动吸附 60px 网格 ✅")

	# 7g) 时间轴多选整体拖拽：两段同移同一 delta
	ed.selected = [0, 1]
	ed.timeline.set_selected(ed.selected)
	var s0a: int = ed.doc.get_i(ed.doc.emitter_nodes()[0], "StartTime", 0)
	var s1a: int = ed.doc.get_i(ed.doc.emitter_nodes()[1], "StartTime", 0)
	ed.timeline.snap_frames = true
	ed.timeline._drag = BrgTimeline.Drag.MOVE
	ed.timeline._drag_index = 0
	ed.timeline._grab_off_frames = 0.0
	ed.timeline._begin_group(0)
	ed.timeline._apply_move(Vector2(ed.timeline.frame_to_x(float(s0a) + 30.0), 0.0))
	var s0b: int = ed.doc.get_i(ed.doc.emitter_nodes()[0], "StartTime", 0)
	var s1b: int = ed.doc.get_i(ed.doc.emitter_nodes()[1], "StartTime", 0)
	if s0b - s0a != 30 or s1b - s1a != 30:
		fails.append("时间轴多选拖拽 delta 不一致：%d / %d" % [s0b - s0a, s1b - s1a])
	else:
		print("[UI] 时间轴多选整体拖拽：两段同移 +30 帧（%d→%d, %d→%d）✅" % [
			s0a, s0b, s1a, s1b])
	# 清掉这次直接驱动的拖拽状态，避免污染后面 8c 的单片段拖拽断言
	ed.timeline._group.clear()
	ed.timeline._group_starts.clear()
	ed.timeline._group_durs.clear()

	# 7h) 复制 / 粘贴：新发射器字段一致、ID 不冲突
	ed.selected = [0]
	ed._on_copy_pressed()
	var before_n: int = ed.doc.emitter_count()
	ed._on_paste_pressed()
	var after_n: int = ed.doc.emitter_count()
	if after_n != before_n + 1:
		fails.append("粘贴后发射器数 %d ≠ %d" % [after_n, before_n + 1])
	elif ed.selected.is_empty() or int(ed.selected[0]) != after_n - 1:
		fails.append("粘贴后未选中新发射器：%s" % str(ed.selected))
	else:
		var src0: BrgDocument.XNode = ed.doc.emitter_nodes()[0]
		var dst0: BrgDocument.XNode = ed.doc.emitter_nodes()[after_n - 1]
		var same: bool = ed.doc.get_field(src0, "Blend", "") == ed.doc.get_field(dst0, "Blend", "") \
			and ed.doc.get_field(src0, "ColorValue", "") == ed.doc.get_field(dst0, "ColorValue", "") \
			and ed.doc.get_int_list(dst0, "EmitTimeList") == ed.doc.get_int_list(src0, "EmitTimeList") \
			and ed.doc.get_i(src0, "ID", -1) != ed.doc.get_i(dst0, "ID", -1)
		if not same:
			fails.append("粘贴的发射器字段/ID 不正确")
		else:
			print("[UI] 复制/粘贴：%d → %d，字段一致且新 ID=%d ✅" % [
				before_n, after_n, ed.doc.get_i(dst0, "ID", -1)])

	# 8) 播放预览能推进且确定
	ed._reload_playback(0)
	ed._advance(30)
	if ed.frame != 30:
		fails.append("预览推进帧数 %d ≠ 30" % ed.frame)
	else:
		print("[UI] 预览推进到第 %d 帧（场上 %d 弹）✅" % [ed.frame, ed.bullets.active_count()])

	# 8a) 播放按真实时间固定 60fps（本工程关了 vsync，不能按渲染帧推进）
	var fps_ok := true
	ed._reload_playback(0)
	ed.playing = true
	ed._play_accum = 0.0
	ed._process(0.5)                 # 0.5 s → 30 逻辑帧
	if ed.frame != 30:
		fails.append("播放累加器 0.5s → %d 帧，期望 30" % ed.frame)
		fps_ok = false
	ed._process(1.0 / 60.0)          # 再 1/60 s → 31
	if ed.frame != 31:
		fails.append("播放累加器 +1/60s → %d 帧，期望 31" % ed.frame)
		fps_ok = false
	ed.playing = false
	ed._play_accum = 0.0
	ed._reload_playback(0)
	if fps_ok:
		print("[UI] 播放按真实时间固定 60fps（0.5s→30 帧，与渲染帧率解耦）✅")

	# 8a2) 加速度在编辑器预览中生效：给发射器 0 设 BulletAccelerate=0.05 + 方向 90（固定向下）
	ed.selected = [0]
	ed._apply_field("BulletAccelerate", 0.05)
	ed._apply_field("BulletAccDirection", 90)
	ed._reload_playback(0)
	var acc_slot := -1
	for i in 240:
		ed.playback.step()
		ed.bullets.step(1.0 / 60.0)
		for s in ed.bullets.active_slots():
			if int(ed.bullets._src_em[s]) == 0:
				acc_slot = s
				break
		if acc_slot >= 0:
			break
	if acc_slot < 0:
		fails.append("加速度测试：240 帧内没找到发射器 0 的子弹")
	else:
		var a0: float = ed.bullets._accel[acc_slot]
		var ad0: float = ed.bullets._acc_dir[acc_slot]
		var vy0: float = ed.bullets._vy[acc_slot]
		for i in 60:
			ed.playback.step()
			ed.bullets.step(1.0 / 60.0)
		var vy1: float = ed.bullets._vy[acc_slot]
		var want_dv: float = Playfield.accel(0.05)      # 0.05 px/帧² → 180 px/s²，1 秒 +180 px/s
		if absf(a0 - want_dv) > 0.5:
			fails.append("子弹 accel=%.1f，期望 %.1f" % [a0, want_dv])
		elif absf(ad0 - 90.0) > 0.1:
			fails.append("子弹 acc_dir=%.1f，期望 90" % ad0)
		elif vy1 - vy0 < want_dv * 0.9:
			fails.append("加速度未生效：1 秒内 vy %.1f → %.1f（期望约 +%.1f）" % [vy0, vy1, want_dv])
		else:
			print("[UI] 编辑器预览加速度生效：accel=%.0f 方向=%.0f，1 秒 vy %.1f → %.1f ✅" % [
				a0, ad0, vy0, vy1])
	ed.selected = [0]
	ed._apply_field("BulletAccelerate", 0)
	ed._apply_field("BulletAccDirection", 0)

	# 8a3) 自机小球：拖动改位置；自机狙朝小球当前坐标发射
	var pb0: Vector2 = ed.canvas._player_pos()
	var pev := InputEventMouseButton.new()
	pev.button_index = MOUSE_BUTTON_LEFT
	pev.pressed = true
	pev.position = pb0
	ed.canvas._handle_press(pev)
	var mev := InputEventMouseMotion.new()
	mev.position = Vector2(650.0, 500.0)
	ed.canvas._handle_motion(mev)
	var rev := InputEventMouseButton.new()
	rev.button_index = MOUSE_BUTTON_LEFT
	rev.pressed = false
	ed.canvas._handle_release()
	if ed.canvas._player_pos() != Vector2(650.0, 500.0):
		fails.append("拖动小球后自机位置 %s ≠ (650,500)" % str(ed.canvas._player_pos()))
	else:
		print("[UI] 拖动小球改自机位置 → (650,500) ✅")

	ed.selected = [0]
	var aim_node: BrgDocument.XNode = ed.doc.emitter_nodes()[0]
	# 清掉事件组，避免发射角旋转事件干扰自机狙判定
	for gname in ["EventGroupList", "BulletEventGroupList"]:
		var gl := aim_node.child(gname)
		if gl != null:
			gl.children.clear()
	ed.doc.set_angle(aim_node, "EmitDirection", BrgDocument.SENTINEL_AIM)
	ed.doc.set_vec(aim_node, "EmitPoint", Vector2(390.0, 240.0))   # 绝对发射点（.brg 文档=设计空间，不换算），避免 Position 偏移歧义
	ed.doc.set_vec(aim_node, "Position", Vector2.ZERO)
	ed.doc.set_field(aim_node, "EmitRadius", 0.0)                 # 前面测试留下的半径会让实际发射点偏移
	ed.doc.set_field(aim_node, "Range", 0.0)
	ed.doc.set_field(aim_node, "TextureName", "bullet_star_corrupt_c")   # 污染弹（贴图名含 corrupt）
	ed.doc.set_field(aim_node, "Way", 1)
	ed.doc.set_field(aim_node, "Circle", 1)
	ed.doc.set_field(aim_node, "StartTime", 1)
	var aim_origin: Vector2 = ed.canvas._emitter_canvas_pos(aim_node)
	var aim_target := Vector2(700.0, 300.0)
	ed.canvas.set_player_pos(aim_target)
	ed._reload_playback(0)
	var aim_slot := -1
	for i in 30:
		ed.playback.step()
		ed.bullets.step(1.0 / 60.0)
		for s in ed.bullets.active_slots():
			if int(ed.bullets._src_em[s]) == 0:
				aim_slot = s
				break
		if aim_slot >= 0:
			break
	if aim_slot < 0:
		fails.append("自机狙测试：30 帧内没找到发射器 0 的子弹")
	else:
		var got: float = rad_to_deg(atan2(ed.bullets._vy[aim_slot], ed.bullets._vx[aim_slot]))
		var want: float = rad_to_deg((aim_target - aim_origin).angle())
		var diff: float = absf(wrapf(got - want, -180.0, 180.0))
		if diff > 1.0:
			fails.append("自机狙方向 %.1f° ≠ 指向小球 %.1f°（差 %.1f°）" % [got, want, diff])
		else:
			print("[UI] 自机小球：自机狙朝小球(%.0f,%.0f)发射 %.1f° ✅" % [
				aim_target.x, aim_target.y, got])
		# 污染弹标记：贴图名含 corrupt → BulletManager F_CORRUPT(4) 置位（命中不致死、累加污染）
		if (ed.bullets._flags[aim_slot] & 4) == 0:
			fails.append("污染弹未打上 F_CORRUPT 标记")
		else:
			print("[UI] 污染弹标记 F_CORRUPT ✅")

	# 8b) 实时预览性能：拖动 gizmo 时每帧都要重放，代价必须可接受。
	#     先分解耗时，别猜（弹池大小已试过，不是主因）。
	var t0 := Time.get_ticks_msec()
	var txt: String = ed.doc.to_text()
	var t1 := Time.get_ticks_msec()
	var brg2 = BrgLoader.load_text(txt)
	var t2 := Time.get_ticks_msec()
	var mgr2 = load("res://scripts/core/BulletManager.gd").new()
	mgr2.capacity = BrgEditor.PREVIEW_CAPACITY
	mgr2.collision_enabled = false        # 与编辑器实际配置一致（否则测的不是真实代价）
	ed.add_child(mgr2)
	var pb2 = BrgPlayback.new(brg2, mgr2, ed._play_host)
	pb2.origin_callable = func() -> Vector2: return ed.host_origin
	for i in 300:
		pb2.step()
		mgr2.step(1.0 / 60.0)
	var t3 := Time.get_ticks_msec()
	print("[UI] 重放 300 帧分解：序列化 %d ms / 解析 %d ms / 模拟 %d ms（共 %d ms，%d 发射器）" % [
		t1 - t0, t2 - t1, t3 - t2, t3 - t0, ed.doc.emitter_count()])
	print("[UI] 模拟后场上 %d 弹（池 %d）" % [mgr2.active_count(), mgr2.capacity])
	ed.remove_child(mgr2)
	mgr2.queue_free()
	var dt: int = t3 - t0
	# 一次重放的固有代价（拖动中会被防抖掉，停手/松手才付这一笔）
	print("[UI] 一次完整重放到第 300 帧 = %d ms（预算 400ms；拖动中被防抖）" % dt)
	if dt > 400:
		fails.append("单次重放太慢（%d ms）" % dt)

	# 8c) 时间轴：坐标换算往返 / 拖片段改 StartTime / 拖右边缘改 Duration / 标尺 scrub
	var rt_ok := true
	for f in [0, 1, 137, 600, 1707]:
		var xx: float = ed.timeline.frame_to_x(float(f))
		if absf(ed.timeline.x_to_frame(xx) - float(f)) > 0.01:
			rt_ok = false
	if not rt_ok:
		fails.append("时间轴 frame_to_x / x_to_frame 往返不一致")
	else:
		print("[UI] 时间轴坐标换算往返一致 ✅")

	ed.timeline.snap_frames = true
	ed.timeline._drag = BrgTimeline.Drag.MOVE
	ed.timeline._drag_index = 0
	ed.timeline._grab_off_frames = 0.0
	ed.timeline._apply_move(Vector2(ed.timeline.frame_to_x(100.0), 0.0))
	var st_new: int = ed.doc.get_i(ed.doc.emitter_nodes()[0], "StartTime", -1)
	if st_new != 100:
		fails.append("时间轴拖片段 → StartTime=%d，期望 100" % st_new)
	else:
		print("[UI] 时间轴拖片段改起始时间 → %d 帧 ✅" % st_new)

	ed.doc.set_field(ed.doc.emitter_nodes()[0], "Duration", 100)
	ed.timeline._drag = BrgTimeline.Drag.RESIZE
	ed.timeline._drag_index = 0
	ed.timeline._apply_resize(Vector2(ed.timeline.frame_to_x(350.0), 0.0))
	var du_new: int = ed.doc.get_i(ed.doc.emitter_nodes()[0], "Duration", -1)
	if du_new != 250:
		fails.append("时间轴拖右边缘 → Duration=%d，期望 250" % du_new)
	else:
		print("[UI] 时间轴拖右边缘改持续时间 → %d 帧 ✅" % du_new)

	ed.timeline._apply_scrub(Vector2(ed.timeline.frame_to_x(200.0), 0.0))
	if ed.timeline.playhead != 200:
		fails.append("时间轴 scrub → 播放头 %d，期望 200" % ed.timeline.playhead)
	elif ed.frame != 200:
		fails.append("时间轴 scrub 没带动预览帧（frame=%d）" % ed.frame)
	else:
		print("[UI] 时间轴标尺 scrub → 播放头 %d 且预览跟随 ✅" % ed.timeline.playhead)

	ed.timeline.fit()
	if ed.timeline.px_per_frame <= 0.0:
		fails.append("时间轴 fit() 后 px_per_frame 非法")
	else:
		print("[UI] 时间轴 fit() → %.4f px/帧（整段 %d 帧）✅" % [
			ed.timeline.px_per_frame, ed.timeline.max_time])

	# 时间轴「随尺寸自动适配」：模拟布局给出真实宽度后，缩放必须等于 (宽−GUTTER)/总长。
	# 这条正是被「布局前 fit() 用最小宽度算成功」坑过的地方。
	ed.timeline.size = Vector2(780.0, 170.0)   # 编辑器画布宽（设计空间，D5 不随 SCALE 改）
	ed.timeline._on_resized()
	var want_ppf: float = (780.0 - BrgTimeline.GUTTER) / float(ed.timeline._extent())
	if absf(ed.timeline.px_per_frame - want_ppf) > 0.001:
		fails.append("时间轴自动适配失败：%.4f ≠ 期望 %.4f" % [
			ed.timeline.px_per_frame, want_ppf])
	else:
		print("[UI] 时间轴随尺寸自动适配 → %.4f px/帧（宽 780 / 整段 %d 帧）✅" % [
			ed.timeline.px_per_frame, ed.timeline._extent()])

	# 手动缩放后必须停止自动适配，否则用户白缩
	var wev := InputEventMouseButton.new()
	wev.button_index = MOUSE_BUTTON_WHEEL_UP
	wev.pressed = true
	wev.ctrl_pressed = true
	wev.position = Vector2(500, 5)
	ed.timeline._handle_button(wev)
	var ppf_after_zoom: float = ed.timeline.px_per_frame
	ed.timeline._on_resized()
	if absf(ed.timeline.px_per_frame - ppf_after_zoom) > 0.0001:
		fails.append("Ctrl+滚轮缩放后仍在自动适配（缩不住）")
	else:
		print("[UI] 手动 Ctrl+滚轮缩放后不再自动适配 ✅")

	# 10) 事件编辑器：关键是 `changename` 数字 ID 必须与 `ChangeName*` 字符串同步
	ed.selected = [0]
	ed._open_event_editor()          # 走真实入口（工具栏「事件…」就是调它）
	if ed.event_editor == null:
		fails.append("事件编辑器没被创建")
	else:
		var ee = ed.event_editor
		ee.open(ed.doc, ed.doc.emitter_nodes()[0])
		var g0: int = ee._groups().size()
		ee._on_add_group()
		var g1: int = ee._groups().size()
		if g1 != g0 + 1:
			fails.append("新增事件组：%d → %d（期望 +1）" % [g0, g1])
		ee._on_add_event()
		var ev: BrgDocument.XNode = ee._cur_event()
		if ev == null:
			fails.append("新增事件后取不到当前事件")
		else:
			# 20 个字段是否齐全
			var missing: Array = []
			for t in BrgDocument.EVENT_ORDER:
				if not ev.has_child(t):
					missing.append(t)
			if not missing.is_empty():
				fails.append("新事件缺字段：%s" % str(missing))
			else:
				print("[UI] 新事件 20 个字段齐全 ✅")

			# 发射器侧结果：Way
			ed.doc.set_event_result(ev, "Emitter", "Way")
			if ed.doc.get_field(ev, "ChangeNameEmitter", "") != "Way":
				fails.append("ChangeNameEmitter 未设为 Way")
			elif ed.doc.get_i(ev, "changename", -1) != BrgDocument.RESULT_EMITTER.find("Way"):
				fails.append("changename=%d ≠ RESULT_EMITTER 里 Way 的序号 %d" % [
					ed.doc.get_i(ev, "changename", -1),
					BrgDocument.RESULT_EMITTER.find("Way")])
			else:
				print("[UI] 事件结果 Way → changename=%d 与 ChangeNameEmitter 同步 ✅" % [
					ed.doc.get_i(ev, "changename", -1)])

			# 切到子弹侧：Acceleration（序号 10），且另外两个 ChangeName* 仍须合法
			ed.doc.set_event_result(ev, "Bullet", "Acceleration")
			var cn_b: String = ed.doc.get_field(ev, "ChangeNameBullet", "")
			var cn_e: String = ed.doc.get_field(ev, "ChangeNameEmitter", "")
			if cn_b != "Acceleration":
				fails.append("ChangeNameBullet 未设为 Acceleration")
			elif ed.doc.get_i(ev, "changename", -1) != BrgDocument.RESULT_BULLET.find("Acceleration"):
				fails.append("子弹侧 changename=%d ≠ %d" % [
					ed.doc.get_i(ev, "changename", -1),
					BrgDocument.RESULT_BULLET.find("Acceleration")])
			elif not BrgDocument.RESULT_EMITTER.has(cn_e):
				fails.append("Mode=Bullet 时 ChangeNameEmitter=%s 不是合法成员" % cn_e)
			else:
				print("[UI] 切到子弹侧 Acceleration → changename=%d，且 ChangeNameEmitter(%s) 仍合法 ✅" % [
					ed.doc.get_i(ev, "changename", -1), cn_e])

		# 事件改动后仍必须无损往返且能被语义层载入
		var evp := "user://brged_test/events.brg"
		DirAccess.make_dir_recursive_absolute("user://brged_test")
		if not ed.doc.save(evp):
			fails.append("带事件改动存盘失败")
		else:
			var etxt := _read_text_keep_cr(evp)
			var ert := BrgDocument.parse_text(etxt)
			if ert == null or ert.to_text() != etxt:
				fails.append("事件改动后存盘不是幂等无损")
			elif BrgLoader.load_file(evp) == null:
				fails.append("事件改动后 BrgLoader 载入失败")
			else:
				print("[UI] 事件改动后仍无损且可被语义层载入 ✅")

		# 删掉刚加的组，恢复原状
		ee._on_del_group()
		if ee._groups().size() != g0:
			fails.append("删除事件组未恢复：%d ≠ %d" % [ee._groups().size(), g0])
		else:
			print("[UI] 事件组增删对称 ✅")

	# 11) 单弹压制（语义 B）：拾取一颗真弹 → 压制 → 重放后它不再存在 → 补丁可持久化
	var mgr = ed.bullets
	ed._reload_playback(60)
	var alive_slots: PackedInt32Array = mgr.active_slots()
	if alive_slots.is_empty():
		fails.append("第 60 帧没有活动弹，无法测单弹压制")
	else:
		var slot: int = alive_slots[0]
		var ident: Array = mgr.identity_of(slot)
		if ident.size() != 3:
			fails.append("子弹没有来源身份（em/born/ord）")
		else:
			var key := BrgPlayback.make_key(int(ident[0]), int(ident[1]), int(ident[2]))
			print("[UI] 拾取到子弹身份 %s（em=%d born=%d ord=%d）" % [
				key, ident[0], ident[1], ident[2]])
			if int(ident[0]) < 0 or int(ident[1]) < 0:
				fails.append("身份字段非法：%s" % str(ident))

			var before: int = mgr.active_count()
			ed.playback.suppressed[key] = true
			ed._reload_playback(60)                 # 重放（压制列表必须被搬运过去）
			var after: int = mgr.active_count()
			if after != before - 1:
				fails.append("压制 1 发后弹数 %d → %d（期望 −1）" % [before, after])
			else:
				print("[UI] 压制单弹后同帧弹数 %d → %d（恰好 −1）✅" % [before, after])

			# 重放后该身份必须彻底不再出现（而不是「生成了又删掉」）
			var still := false
			for s2 in mgr.active_slots():
				var id2: Array = mgr.identity_of(s2)
				if id2.size() == 3 and BrgPlayback.make_key(
						int(id2[0]), int(id2[1]), int(id2[2])) == key:
					still = true
					break
			if still:
				fails.append("被压制的弹在重放后仍然存在")
			else:
				print("[UI] 重放后被压制的弹不再出现 ✅")

			# sidecar 持久化：写出 → 读回 → 身份还在；且 .brg 本体不被改动
			DirAccess.make_dir_recursive_absolute("user://brged_test")
			var brg_tmp := "user://brged_test/supp.brg"
			var bytes_before: String = ed.doc.to_text()
			if not ed.doc.save(brg_tmp):
				fails.append("压制测试：存 .brg 失败")
			elif not ed.playback.save_patch(brg_tmp):
				fails.append("压制补丁写出失败")
			else:
				var pp := BrgPlayback.patch_path_for(brg_tmp)
				if not FileAccess.file_exists(pp):
					fails.append("补丁文件不存在：%s" % pp)
				else:
					var pb_rt = BrgPlayback.new(null, null, null)
					if not pb_rt.load_patch(brg_tmp):
						fails.append("补丁读回失败")
					elif not (pb_rt.suppressed as Dictionary).has(key):
						fails.append("补丁里没有刚压制的身份 %s" % key)
					else:
						print("[UI] 压制补丁写出/读回一致（%s）✅" % pp.get_file())
					if _read_text_keep_cr(brg_tmp) != bytes_before:
						fails.append(".brg 被补丁改动了（应当只写 sidecar）")
					else:
						print("[UI] .brg 本体未被压制补丁改动 ✅")
			ed.playback.clear_suppressed()
			ed._reload_playback(60)

	# 12) 跨进程机评不在本工具范围内（需要工程侧的机器人与 exe）。

	# 9) 存盘仍无损
	var tmp := "user://brged_test/ui.brg"
	DirAccess.make_dir_recursive_absolute("user://brged_test")
	if ed.doc.save(tmp):
		var t := _read_text_keep_cr(tmp)
		var rt := BrgDocument.parse_text(t)
		if rt == null or rt.to_text() != t:
			fails.append("UI 编辑后存盘不是幂等无损")
		else:
			print("[UI] UI 编辑后存盘仍无损 ✅")
	else:
		fails.append("UI 存盘失败")

	if fails.is_empty():
		print("[UI] ✅ 全部通过")
	else:
		for m in fails:
			print("  ❌ " + m)
		print("[UI] ❌ %d 项失败" % fails.size())
	_cli_done(fails.is_empty())

## 存一张截图，返回 Error
func _grab(path: String) -> int:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var dir := path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	var err := img.save_png(path)
	print("SHOT %s err=%d size=%dx%d" % [path, err, img.get_width(), img.get_height()])
	return err
