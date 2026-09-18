class_name Playfield
extends RefCounted
## 弹幕设计画布（780×960）→ 世界（390×480）→ 屏幕。
##
## 决议（2026-09-17）：**战斗区 390×480 改造（本质 = 内容约 2× 变焦）**。
##   · 设计画布维持 780×960：`.brg` 数据 / 编辑器画布一律不动（路径 A）
##   · 世界空间 SCALE = 0.5 → 战场 390×480（≈红魔乡原生 384×448 坐标系）
##   · 屏幕可见矩形仍是 768×896 @ (256,32) → VIEW_SX/SY ≈ 1.969/1.867（≈2× 放大）
##   · **位置 / 速度 / 加速度随 SCALE 减半**（屏上表现与改造前逐像素一致）
##   · **尺寸与判定冻结**：弹幕 r/size、敌机 e.r、美术尺寸=世界单位直写，不随 SCALE
##     （屏上放大 ≈1.97×；配合 ART_SCALE 回调 1.0，净 +43% ≈ 东方大玉比例）
##   · 自机速度/判定/自机弹由 Game 注入的 *_scale（=SCALE）自动适配；自机贴图与
##     自机弹用钉住的 `Player.gd:PLAYER_ART_SCALE`，屏上不变
##   · VIEW_SX/SY 改为按 FIELD_W/FIELD_H 计算（**关键：漏改则全屏错位**）
##
## 历史（2026-09-16）：**可见战场按红魔乡·新典比例重排**。
##   · 窗口 1280×960（4:3），战场可见矩形 768×896 @ (256,32)，左右边栏各 256
## HUD / 菜单一律按**屏幕像素**排版，用 LEFT_W / RIGHT_W / VIEW_* 定位。
## 时间轴（帧率）与角度不换算。

const DESIGN_W := 780.0
const DESIGN_H := 960.0
const SCALE := 0.5                       # 世界空间内：设计单位 → 世界像素（2026-09-17 起）
const FIELD_W := DESIGN_W * SCALE        # 390
const FIELD_H := DESIGN_H * SCALE        # 480
const FIELD_X := 0.0
const FIELD_Y := 0.0

# ------------------------------------------------------------------ 新典比例

const WINDOW_W := 1280.0
const WINDOW_H := 960.0
const VIEW_X := 256.0
const VIEW_Y := 32.0
const VIEW_W := 768.0                    # 0.6 × WINDOW_W
const VIEW_H := 896.0                    # 0.9333 × WINDOW_H
const VIEW_SX := VIEW_W / FIELD_W        # 1.969230…（2026-09-17 改除以 FIELD_W）
const VIEW_SY := VIEW_H / FIELD_H        # 1.866666…（2026-09-17 改除以 FIELD_H）
const LEFT_W := VIEW_X                   # 256
const RIGHT_W := WINDOW_W - VIEW_X - VIEW_W   # 256
## 兼容别名：旧代码里的「外置 UI 竖栏宽」
const SIDE_W := LEFT_W
## 战场可见区中线（= 窗口中线 640）
const VIEW_CX := VIEW_X + VIEW_W * 0.5

# ------------------------------------------------------------------ 美术放大
# 2026-09-16：弹幕"视觉指数增大"——只放大**绘制**尺寸，模拟/判定一律不动。
#   · 弹幕：只乘 `size`（绘制），`hit`（判定半径）保持原值 → 判定区仍是红魔乡式小判定
#   · 敌机 / Boss / 掉落物：`r`（受击半径）随美术同步放大（自机弹要能打中贴图边缘）
#   · 自机：贴图与光晕放大，判定点 / 擦弹圈 / 受击半径全部不动
# 2026-09-17（390×480 改造）：ART_SCALE 1.4 → 1.0。尺寸数值已在世界空间冻结不变，
#   屏幕放大约 2× → 与之相乘后屏上净 +43%；自机贴图/自机弹改用钉住的
#   `Player.gd 的 PLAYER_ART_SCALE = 1.4`，屏上尺寸不变。想回到满 2× 只需把这里改回 1.4。
const ART_SCALE := 1.0

## 美术尺寸换算（绘制专用）
static func art(d: float) -> float:
	return d * ART_SCALE

# ------------------------------------------------------------------ 世界坐标（逻辑）

static func rect() -> Rect2:
	return Rect2(FIELD_X, FIELD_Y, FIELD_W, FIELD_H)

## 战场可见矩形（屏幕像素）
static func view_rect() -> Rect2:
	return Rect2(VIEW_X, VIEW_Y, VIEW_W, VIEW_H)

## 设计坐标（画布像素）→ 世界坐标
static func pos(x: float, y: float) -> Vector2:
	return Vector2(FIELD_X + x * SCALE, FIELD_Y + y * SCALE)

static func vec(v: Vector2) -> Vector2:
	return Vector2(FIELD_X, FIELD_Y) + v * SCALE

## 设计长度（像素）→ 世界像素
static func len(d: float) -> float:
	return d * SCALE

## 设计速度（px/帧）→ 世界速度（px/s）
static func speed(v: float) -> float:
	return v * 60.0 * SCALE

## 设计加速度（px/帧²）→ 世界加速度（px/s²）
static func accel(a: float) -> float:
	return a * 3600.0 * SCALE

# ------------------------------------------------------------------ 世界 → 屏幕
# HUD 是 CanvasLayer（不受 Game 根节点变换影响），画与世界坐标相关的东西
# （Boss 指示器、符号等）时必须走这几个函数换算。

static func to_screen_x(x: float) -> float:
	return VIEW_X + x * VIEW_SX

static func to_screen_y(y: float) -> float:
	return VIEW_Y + y * VIEW_SY

static func to_screen(p: Vector2) -> Vector2:
	return Vector2(to_screen_x(p.x), to_screen_y(p.y))
