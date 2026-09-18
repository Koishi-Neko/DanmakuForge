class_name Sanctity
extends RefCounted
## 圣洁 / 污染 双槽核心机制（2026-09-10 重做：单槽 -100~+100 → 双槽 0~100）
##
## 两条互斥的槽，同一时刻只有一条处于激活状态：
##   圣洁槽（默认激活，初始 100 = 满火力）
##     · 擦弹 +1/秒；攒满后多余的擦弹时间计入 x 加值槽（金条覆蓝）
##     · x 攒满 100 秒 → +1 Bomb；若 Bomb 已达 5 个 → Bomb -2、残机 +1
##     · 圣光（Bomb）：只消耗 Bomb 计数，**不改变圣洁值**，持续 = 当前圣洁 / 25 秒
##   污染槽（由污染弹累积，a_k = 3k-1 递增：2,5,8,…,23，第 8 次累计 100）
##     · 攒满 100 → 强制切换为污染状态（普通难度残机不变；至纯之路残机 -1）
##     · 污染状态：固定满火力、伤害更高、判定点更大、不追踪、没有 Bomb
##     · 血雨（负面 Bomb）：-25 污染，持续 = 释放前污染 / 25 秒，不可叠加
##     · 污染归 0 → 转回圣洁姿态（圣洁 50）+ 1 Bomb
##
## 死亡复活：回到圣洁姿态，按**剩余残机**阶梯恢复圣洁（见 DEATH_RECOVER），
## 残机 ≤1 时额外赠送一次免费圣光；Bomb 重置为 3（由 Player 处理）。
##
## 至纯之路（高难）：获得污染值立即进入污染状态且残机 -1。

const MAX_V := 100.0
const BOMB_COST := 25.0
const CONVERT_SANCTITY := 50.0     # 污染归 0 转回圣洁时的初始圣洁
## 死亡复活按**剩余残机**阶梯恢复圣洁（索引 = min(残机, 3)，越少残机恢复越多）：
##   残机 ≥3 → 25 ｜ =2 → 50 ｜ =1 → 75 ｜ =0（最后一命）→ 100
## 残机 ≤1 的背水档额外赠送一次免费圣光。
const DEATH_RECOVER: Array[float] = [100.0, 75.0, 50.0, 25.0]
const X_MAX := 100.0               # x 加值槽上限（擦弹秒数）

const TIERS: Array[float] = [0.0, 25.0, 50.0, 75.0, 100.0]

# 追踪转向速度（度/秒，按圣洁档位线性；污染态恒 0 = 不追踪）
const HOMING_SANCTITY: Array[float] = [0.0, 90.0, 180.0, 270.0, 360.0]

# 判定点半径（污染态更大）
const HIT_R_SANCTITY := 2.0
const HIT_R_CORRUPTION := 3.0

var sanctity: float = MAX_V        # 圣洁槽 0~100（圣洁态时激活）
var corruption: float = 0.0        # 污染槽 0~100（污染态时激活）
var x_bonus: float = 0.0           # 擦弹加值槽 0~100（仅圣洁满 100 时累积）
var corrupt_hits: int = 0          # 本轮污染弹命中计数 k（a_k = 3k-1）
var hard_mode := false             # 至纯之路：污染即转化 + 残机 -1
var _holy := true                  # 当前激活姿态：true = 圣洁

signal state_changed(is_sanctity: bool)
signal x_filled                    # x 加值攒满 100（由 Player 决定奖励内容）
signal converted_to_holy           # 污染归 0 转回圣洁（由 Player 补 1 Bomb）

func is_sanctity() -> bool:
	return _holy

func is_corrupt() -> bool:
	return not _holy

## 当前激活槽的值
func active_value() -> float:
	return sanctity if _holy else corruption

## 兼容旧接口的有符号视图：圣洁为正、污染为负（Bot / 截图 / 回放指纹用）
var value: float:
	get:
		return sanctity if _holy else -corruption
	set(v):
		# 调试钉值：v >= 0 → 圣洁态圣洁 v；v < 0 → 污染态污染 -v
		if v >= 0.0:
			_holy = true
			sanctity = clampf(v, 0.0, MAX_V)
			corruption = 0.0
		else:
			_holy = false
			corruption = clampf(-v, 0.0, MAX_V)
			sanctity = 0.0
		x_bonus = 0.0
		corrupt_hits = 0

## 当前档位索引 0~4（污染态固定满火力 = 4）
func tier_index() -> int:
	if not _holy:
		return 4
	var idx := 0
	for i in TIERS.size():
		if sanctity >= TIERS[i]:
			idx = i
	return idx

## 档位内的线性进度 0~1（污染态恒 1）
func tier_lerp() -> float:
	if not _holy:
		return 1.0
	var idx := tier_index()
	if idx >= TIERS.size() - 1:
		return 1.0
	var lo := TIERS[idx]
	var hi := TIERS[idx + 1]
	if hi - lo <= 0.0001:
		return 0.0
	return clampf((sanctity - lo) / (hi - lo), 0.0, 1.0)

## 追踪转向速度（度/秒），污染态为 0
func homing_turn_rate() -> float:
	if not _holy:
		return 0.0
	var idx := tier_index()
	var v: float = HOMING_SANCTITY[idx]
	if idx < HOMING_SANCTITY.size() - 1:
		v = lerpf(v, HOMING_SANCTITY[idx + 1], tier_lerp())
	return v

## Bomb 持续帧数 = 当前激活槽值 / 25 秒（圣光不扣费；血雨在扣费前取值）
func bomb_duration_frames() -> int:
	return int(active_value() / 25.0 * 60.0)

## 判定点半径（污染态更大）
func hit_radius() -> float:
	return HIT_R_SANCTITY if _holy else HIT_R_CORRUPTION

## 弹幕颜色（用于视觉反馈）：满档（100）圣洁光箭变亮白（2026-09-15）
func arrow_color() -> Color:
	if _holy:
		if sanctity >= MAX_V - 0.001:
			return Color(1.0, 1.0, 1.0, 1.0)
		return Color(1.0, 0.95, 0.72, 1.0)
	return Color(0.85, 0.12, 0.18, 1.0)

func glow_color() -> Color:
	if _holy:
		return Color(1.0, 0.9, 0.55, 1.0)
	return Color(0.9, 0.1, 0.15, 1.0)

# ------------------------------------------------------------------ 增减

## 污染弹命中：普通难度按 a_k = 3k-1 递增累积；至纯之路立即转化。
## 返回 true = 本次命中导致切换为污染状态（残机惩罚由 Player 按难度结算）。
func add_corruption_hit() -> bool:
	if not _holy:
		return false                 # 已是污染态：污染弹惰性化
	if hard_mode:
		_convert_to_corrupt()
		return true
	corrupt_hits += 1
	corruption = minf(corruption + float(3 * corrupt_hits - 1), MAX_V)
	if corruption >= MAX_V - 0.001:
		_convert_to_corrupt()
		return true
	return false

func _convert_to_corrupt() -> void:
	_holy = false
	corruption = MAX_V
	corrupt_hits = 0
	x_bonus = 0.0
	state_changed.emit(false)

## 擦弹推进（每固定步调用一次，seconds = 本步时长）：
## 圣洁未满 → +seconds 圣洁；已满 → 累积 x 加值；x 满 → 发 x_filled 奖励。
## 污染态下擦弹不影响槽值（只有分数）。
func on_graze_tick(seconds: float) -> void:
	if not _holy:
		return
	if sanctity < MAX_V:
		sanctity = minf(sanctity + seconds, MAX_V)
	else:
		x_bonus += seconds
		if x_bonus >= X_MAX:
			x_bonus = 0.0
			x_filled.emit()

## 掉落物拾取（火力道具）：+v 圣洁；圣洁已满 → 计入 x 加值槽（与擦弹同效）。
## 污染态下无效（返回 false，表现由调用方决定）。
func add_sanctity_item(v: float) -> bool:
	if not _holy:
		return false
	if sanctity < MAX_V:
		sanctity = minf(sanctity + v, MAX_V)
	else:
		x_bonus += v
		if x_bonus >= X_MAX:
			x_bonus = 0.0
			x_filled.emit()
	return true

## 放 Bomb 的结算：圣光只消耗 Bomb 计数（由 Player 处理），**不改变圣洁值**，
## 因此满槽的 x 加值也不会被打断；血雨 -25 污染（归 0 转回圣洁 +1 Bomb）。
func on_bomb_used() -> void:
	if _holy:
		return
	corruption = maxf(corruption - BOMB_COST, 0.0)
	if corruption <= 0.001:
		corruption = 0.0
		_holy = true
		sanctity = CONVERT_SANCTITY
		corrupt_hits = 0
		state_changed.emit(true)
		converted_to_holy.emit()

## 死亡复活：回到圣洁姿态，按剩余残机阶梯恢复（见 DEATH_RECOVER）。
## 返回 true = 额外赠送一次免费圣光（残机 ≤1 的背水档）。
func on_death(lives_left: int) -> bool:
	var was_corrupt := not _holy
	_holy = true
	corruption = 0.0
	x_bonus = 0.0
	corrupt_hits = 0
	sanctity = DEATH_RECOVER[clampi(lives_left, 0, 3)]
	if was_corrupt:
		state_changed.emit(true)
	return lives_left <= 1

## 主动修正（调试用）
func adjust(delta: float) -> void:
	if _holy:
		sanctity = clampf(sanctity + delta, 0.0, MAX_V)
		if sanctity < MAX_V:
			x_bonus = 0.0
	else:
		corruption = clampf(corruption + delta, 0.0, MAX_V)

## 顶格提示（HUD 辉光用）
func is_at_cap() -> bool:
	return (_holy and sanctity >= MAX_V) or (not _holy and corruption >= MAX_V)

## 归一化激活槽 0~1（UI 条形用）
func normalized() -> float:
	return active_value() / MAX_V

func state_label() -> String:
	return "圣洁 %d" % int(round(sanctity)) if _holy else "污染 %d" % int(round(corruption))

## HUD 提示：当前应该做什么
func direction_hint() -> String:
	if _holy:
		return "擦弹 → 充能圣光" if sanctity >= MAX_V else "擦弹 → 圣洁"
	return "血雨 -25 污染 · 归零转圣洁"
