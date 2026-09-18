extends SceneTree
## 构建期弹幕贴图烘焙（headless）：
##   godot --headless --path <项目> --script tools/bake_bullets.gd
##
## 对 `BulletManager.TEX_PATHS` 里每张贴图，按 `TexLoader.BAKE_LADDER` 的每个档位
## 跑一遍与运行时**完全相同**的烘焙算法（TexLoader._bake_bullet），把结果写进
## `assets/textures_baked/<键名>_<档位>.png`，并生成 `manifest.json`（pad_ratio）。
##
## 运行时 `TexLoader.get_bullet_tex()` 会优先命中这份预烘焙：
##   ① 免去首次使用时的烘焙卡顿  ② 导出版（load_from_file 回退）也带描边
##
## 改弹幕贴图 / 改烘焙算法后重跑本脚本即可。
const OUTFILE_DIR := "res://assets/textures_baked"


func _init() -> void:
	var bm: GDScript = load("res://scripts/core/BulletManager.gd")
	if bm == null:
		push_error("[BakeBullets] 载入 BulletManager 失败")
		quit(1)
		return
	var paths: Dictionary = bm.TEX_PATHS
	DirAccess.make_dir_recursive_absolute(OUTFILE_DIR)
	var manifest := {}
	var t0 := Time.get_ticks_msec()
	var total := 0
	for key in paths:
		var path: String = paths[key]
		# 源图实际长边：档位高于源尺寸时，烘焙结果与「源尺寸档」完全一样 → 复用同一份文件
		var src := TexLoader._load_image(path)
		var src_long := 0 if src == null else maxi(src.get_width(), src.get_height())
		if src_long == 0:
			print("[BakeBullets] ❌ 跳过（源缺失）：%s" % path)
			continue
		var per_tex := {}
		var made := {}          # 实际生成过的尺寸 -> 文件名
		for tgt in TexLoader.BAKE_LADDER:
			var eff: int = mini(int(tgt), src_long)
			if not made.has(eff):
				var res: Dictionary = TexLoader._bake_bullet(path, TexLoader.bake_target_size(eff))
				var tex: Texture2D = res.get("tex")
				if tex == null:
					print("[BakeBullets] ❌ 烘焙失败：%s @%d" % [path, eff])
					break
				var img: Image = tex.get_image()
				var fname := "%s_%d.png" % [key, eff]
				if img.save_png(OUTFILE_DIR + "/" + fname) != OK:
					push_error("[BakeBullets] 写盘失败：%s" % fname)
					break
				made[eff] = {"file": fname, "pad": res["pad_ratio"]}
				total += 1
			var ent: Dictionary = made[eff]
			per_tex[str(tgt)] = ent
		if not per_tex.is_empty():
			manifest[path] = per_tex
	var f := FileAccess.open(OUTFILE_DIR + "/manifest.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest, "  "))
	f.close()
	print("[BakeBullets] ✅ 完成：%d 张贴图 / %d 个档位文件，%d ms → %s" % [
		manifest.size(), total, Time.get_ticks_msec() - t0, OUTFILE_DIR])
	quit(0)
