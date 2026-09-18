class_name TexLoader
extends RefCounted
## 运行时贴图加载器（带缓存）
##
## 为什么不用导入的 CompressedTexture2D？
## 实测：本机 Godot 4.7.2 + RTX 5060（Vulkan 1.4.341 / OpenGL 3.3）下，
## **尺寸 ≥ 128px 的导入贴图在 CanvasItem._draw() 中会渲染成纯白色矩形**
## （CPU 侧 get_image() 数据完全正常；64px 及以下正常）。
## 运行时用 Image.load_from_file() + ImageTexture 创建的贴图则完全正常。
##
## 因此所有需要 draw_texture* 的贴图都走这里，绕开导入系统。
## 注意：Image.load_from_file 需要**真实文件路径**，res:// 要先 globalize。

static var _cache: Dictionary = {}

## 加载贴图为 ImageTexture（带缓存）。失败返回 null。
static func get_tex(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	if not ResourceLoader.exists(path):
		_cache[path] = null
		return null
	var real := ProjectSettings.globalize_path(path)
	var img := Image.load_from_file(real)
	if img == null:
		# 回退：路径可能不是普通文件（如打包进 pck），退回导入资源
		var res: Texture2D = load(path)
		_cache[path] = res
		return res
	var t := ImageTexture.create_from_image(img)
	_cache[path] = t
	return t

## 清空缓存（换场景/换素材时用）
static func clear() -> void:
	_cache.clear()

# ==================================================================== 弹幕贴图烘焙
#
# 弹幕贴图是 256–2048px 的高清渲染图，而实际显示只有 12–51px。若让 GPU 直接从
# 2048px 采样到 25px（默认线性过滤、无 mipmap），每个屏幕像素只命中 1–2 个纹素：
# 移动时闪烁爬行、形状糊化，而且在暗/亮背景上都没有轮廓可读（玩家反馈）。
#
# 这里在加载时**一次性烘焙**（结果缓存，运行时零额外 draw call）：
#   ① Lanczos 降采样到「显示尺寸 × 2.5」（≤320px，且不放大原图）
#   ② 高光提亮：亮度软阈值把亮部推向近白（只碰亮部，不洗掉暗部体积）
#   ③ 镜面点：白名单实心圆弹加左上小高光（形状语言不匹配的弹不加）
# 2026-09-17：**取消白+黑双层描边**（用户要求"所有弹幕取消硬性描边"；尺寸已足够大）。
#   烘焙画布不再留边距，pad_ratio 恒为 1.0；轮廓感由美术自身的半透明边缘/辉光承担。

const BAKE_MAX := 320
## 构建期预烘焙：允许的烘焙尺寸阶梯（`tools/bake_bullets.gd` 按此出图）。
## 运行时按 `clamp(size*2.5, 48, 320)` 就近取一档 —— 视觉尺寸只由调用方的 `size`
## 决定，贴图像素多少只影响锐度，所以档位差 ≤25% 无感。
## 预烘焙的意义：① 去掉首次使用时的烘焙卡顿（2048² 一张 ~48ms）
##                  ② **导出后 `Image.load_from_file` 回退时也保持同样的锐度/高光**
## 2026-09-17（390×480 改造）：上限 160→320、追加 256/320 两档 ——
##   BulletManager._base_display_size 翻倍后最大需求 ≈180（≤160 档即可覆盖），
##   新档位为后续更大显示尺寸预留。
const BAKE_LADDER := [48, 64, 96, 128, 160, 256, 320]
const BAKED_DIR := "res://assets/textures_baked"
const HILIGHT_LO := 0.55                          # 高光提亮起点亮度
const HILIGHT_HI := 0.90                          # 高光提亮饱和亮度
const HILIGHT_MIX := 0.45                         # 高光提亮最大混合
## 镜面点白名单：实心圆/球类贴图（文件名，含扩展名）。
## 2026-09-17：orb/dot 改为自带体积光的高清程序化美术（tools/gen_bullet_art.py），
## 不再需要额外镜面点，从白名单移除。
const SPECULAR_TEX := {
	"bullet_fire_blue.png": true, "bullet_fire_purple.png": true, "bullet_fire_green.png": true,
}

static var _bake_cache: Dictionary = {}
static var bake_ms_last := 0.0    # 上一次烘焙耗时（诊断用）
static var bake_ms_total := 0.0   # 累计烘焙耗时（诊断用）
static var bake_count := 0        # 已烘焙贴图数（诊断用）
## 磁盘缓存：烘焙一次后写 user://，之后启动直接读小图（大图 PNG 解码是大头：
## 2048² 一张就要 ~48ms）。改动烘焙逻辑必须提升版本号。
## 2026-09-17：BAKE_LADDER 扩展（256/320）→ 版本 3→4；**取消双层描边** → 4→5。
const BAKE_CACHE_VERSION := 5
const BAKE_DIR := "user://bullet_bake"
static var _manifest: Dictionary = {}
static var _manifest_loaded := false

## 烘焙一张弹幕贴图；返回 {"tex": Texture2D, "pad_ratio": float}。
## 优先读构建期预烘焙（assets/textures_baked），其次磁盘缓存（user://bullet_bake），
## 最后运行时现烘焙。失败时回退到原始贴图（pad_ratio = 1.0）。
## base_size = 该贴图在游戏里的最大显示边长。
static func get_bullet_tex(path: String, base_size: float) -> Dictionary:
	var key := "%s@%d" % [path, int(round(base_size))]
	if _bake_cache.has(key):
		return _bake_cache[key]
	var pre := _load_prebaked(path, base_size)
	if not pre.is_empty():
		_bake_cache[key] = pre
		return pre
	var cached := _load_baked(key, path)
	if not cached.is_empty():
		_bake_cache[key] = cached
		return cached
	var t0 := Time.get_ticks_msec()
	var res := _bake_bullet(path, base_size)
	if res.get("tex") == null:
		# 源文件缺失：不计数、不落盘（每次重试都很便宜）
		_bake_cache[key] = res
		return res
	bake_ms_last = float(Time.get_ticks_msec() - t0)
	bake_ms_total += bake_ms_last
	bake_count += 1
	_store_baked(key, path, res)
	_bake_cache[key] = res
	return res

## ------------------------------------------------------------------ 构建期预烘焙
## 读取 assets/textures_baked/manifest.json（由 tools/bake_bullets.gd 生成）。
static var _prebaked: Dictionary = {}
static var _prebaked_loaded := false

static func _load_prebaked(path: String, base_size: float) -> Dictionary:
	if not _prebaked_loaded:
		_prebaked_loaded = true
		var f := FileAccess.open(BAKED_DIR + "/manifest.json", FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				_prebaked = parsed
	var e: Dictionary = _prebaked.get(path, {})
	if e.is_empty():
		return {}
	var tgt := _ladder_target(base_size)
	var ent: Dictionary = e.get(str(tgt), {})
	if ent.is_empty():
		return {}
	var tex := get_tex(BAKED_DIR + "/" + String(ent.get("file", "")))
	if tex == null:
		return {}
	return {"tex": tex, "pad_ratio": float(ent.get("pad", 1.0))}

## 运行时/预烘焙共用的尺寸档位：目标 = clamp(size*2.5, 48, 320)，就近取阶梯值
static func _ladder_target(base_size: float) -> int:
	var want := clampi(int(round(base_size * 2.5)), 48, BAKE_MAX)
	var best := BAKE_LADDER[0]
	for v in BAKE_LADDER:
		if absi(v - want) < absi(best - want):
			best = v
	return best

## 预烘焙用的尺寸（tools/bake_bullets.gd 调用）：让 `_bake_bullet` 正好落在该档位
static func bake_target_size(target: int) -> float:
	return float(target) / 2.5

## ------------------------------------------------------------------ 磁盘缓存
static func _bake_dir_real() -> String:
	return BAKE_DIR + "_v%d" % BAKE_CACHE_VERSION

static func _src_stamp(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "?"
	var size := f.get_length()
	f.close()
	return "%d@%d" % [size, FileAccess.get_modified_time(path)]

static func _load_manifest() -> void:
	if _manifest_loaded:
		return
	_manifest_loaded = true
	var p := _bake_dir_real() + "/manifest.json"
	if not FileAccess.file_exists(p):
		return
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_manifest = parsed

static func _save_manifest() -> void:
	DirAccess.make_dir_recursive_absolute(_bake_dir_real())
	var f := FileAccess.open(_bake_dir_real() + "/manifest.json", FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_manifest))
	f.close()

static func _load_baked(key: String, path: String) -> Dictionary:
	_load_manifest()
	var e: Dictionary = _manifest.get(key, {})
	if e.is_empty() or String(e.get("src", "")) != _src_stamp(path):
		return {}
	var img := Image.load_from_file(_bake_dir_real() + "/" + String(e.get("file", "")))
	if img == null:
		return {}
	return {"tex": ImageTexture.create_from_image(img), "pad_ratio": float(e.get("pad", 1.0))}

static func _store_baked(key: String, path: String, res: Dictionary) -> void:
	_load_manifest()
	var tex: Texture2D = res["tex"]
	if tex == null:
		return
	var img := tex.get_image()
	if img == null:
		return
	DirAccess.make_dir_recursive_absolute(_bake_dir_real())
	var fname := key.md5_text() + ".png"
	if img.save_png(_bake_dir_real() + "/" + fname) != OK:
		return
	_manifest[key] = {"src": _src_stamp(path), "file": fname, "pad": res["pad_ratio"]}
	_save_manifest()

static func _bake_bullet(path: String, base_size: float) -> Dictionary:
	var img := _load_image(path)
	if img == null:
		return {"tex": get_tex(path), "pad_ratio": 1.0}
	# ① 降采样（先反复 1/2 均值降采样：大图直接 Lanczos 太贵；再一步 Lanczos 收尾）
	var src_long := maxi(img.get_width(), img.get_height())
	var target: int = mini(_ladder_target(base_size), src_long)
	if src_long > target:
		while maxi(img.get_width(), img.get_height()) > target * 4:
			img.resize(maxi(1, img.get_width() / 2), maxi(1, img.get_height() / 2),
				Image.INTERPOLATE_BILINEAR)
		var cur := maxi(img.get_width(), img.get_height())
		if cur > target:
			var f := float(target) / float(cur)
			img.resize(maxi(1, int(round(img.get_width() * f))),
				maxi(1, int(round(img.get_height() * f))), Image.INTERPOLATE_LANCZOS)
	# ② 高光提亮 ③ 镜面点
	img = _lift_highlights(img)
	if SPECULAR_TEX.has(path.get_file()):
		_specular_dot(img)
	# 2026-09-17：不再叠白+黑描边（用户要求所有弹幕取消硬性描边）；
	# 画布即贴图本身，pad_ratio = 1.0（调用方显示尺寸不再放大）。
	return {"tex": ImageTexture.create_from_image(img), "pad_ratio": 1.0}

## 读取图片文件（失败返回 null；与 get_tex 一致的加载路径）
static func _load_image(path: String) -> Image:
	if not ResourceLoader.exists(path):
		return null
	var real := ProjectSettings.globalize_path(path)
	return Image.load_from_file(real)

## ② 高光提亮：亮度软阈值把亮部推向近白（只会更亮，不改 alpha；字节数组处理）
static func _lift_highlights(img: Image) -> Image:
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var used := img.get_used_rect()
	var data := img.get_data()
	for y in range(used.position.y, used.end.y):
		var row := y * w * 4
		for x in range(used.position.x, used.end.x):
			var i := row + x * 4
			var a := data[i + 3]
			if a <= 5:
				continue
			var lum := (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2]) / 255.0
			var t := clampf((lum - HILIGHT_LO) / (HILIGHT_HI - HILIGHT_LO), 0.0, 1.0)
			t = t * t * (3.0 - 2.0 * t)
			var k := t * HILIGHT_MIX * (float(a) / 255.0)
			if k <= 0.001:
				continue
			for c in 3:
				var v := data[i + c]
				data[i + c] = clampi(int(round(v + (255 - v) * k)), 0, 255)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)

## ③ 镜面点：贴图左上 1/3 处一颗软高光（只给实心圆弹用）
static func _specular_dot(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var r := maxf(2.5, float(mini(w, h)) * 0.17)
	var cx := float(w) * 0.37
	var cy := float(h) * 0.33
	for y in range(maxi(0, int(cy - r)), mini(h, int(cy + r) + 1)):
		for x in range(maxi(0, int(cx - r)), mini(w, int(cx + r) + 1)):
			var d := Vector2((float(x) + 0.5 - cx) / r, (float(y) + 0.5 - cy) / r).length()
			if d >= 1.0:
				continue
			var c := img.get_pixel(x, y)
			if c.a <= 0.05:
				continue
			var k := pow(1.0 - d, 1.8) * 0.9
			img.set_pixel(x, y, Color(c.r + (1.0 - c.r) * k, c.g + (1.0 - c.g) * k,
				c.b + (1.0 - c.b) * k, c.a))
