class_name Emitter
extends RefCounted
## 弹幕发射器：帧级脚本调度
##
## 一个发射器 = 一份「第 N 帧做什么」的清单。用闭包（Callable）描述每一波，
## 所以写一张符卡就是写一个函数，不需要额外数据格式。
##
## 用法：
##   var e := Emitter.new(bullets, self)
##   e.at(0, func(em): em.fan(Vector2(390,200), 12, 120.0, 180.0, 30.0, {...}))
##   e.at(60, func(em): em.ring(...))
##   e.at(120, func(em): em.repeat(10, 8, func(k): ...))

var bullets: Node
var host: Node2D
var _queue: Array = []   # [{f: int, cb: Callable}]
var _frame: int = 0
var _done: bool = false
var age_limit: int = 0      # >0 时，超过此帧数不再执行回调

func _init(p_bullets: Node, p_host: Node2D) -> void:
	bullets = p_bullets
	host = p_host

# ------------------------------------------------------------------ 调度

func at(frame: int, cb: Callable) -> Emitter:
	_queue.append({"f": frame, "cb": cb})
	return self

func every(period: int, count: int, offset: int, cb: Callable) -> Emitter:
	for k in count:
		var f := offset + k * period
		at(f, cb)
	return self

func repeat(count: int, period: int, cb: Callable) -> Emitter:
	for k in count:
		var kk := k
		at(_frame + k * period, func(em: Emitter) -> void: cb.call(kk))
	return self

func after(delay: int, cb: Callable) -> Emitter:
	return at(_frame + delay, cb)

func tick() -> void:
	if _done:
		return
	if age_limit > 0 and _frame >= age_limit:
		_queue.clear()
		_done = true
		return
	var keep: Array = []
	for item in _queue:
		if item["f"] <= _frame:
			(item["cb"] as Callable).call(self)
		else:
			keep.append(item)
	_queue = keep
	_frame += 1
	if _queue.is_empty():
		_done = true

func finished() -> bool:
	return _done

# ------------------------------------------------------------------ 弹型helper

func _p(emitter_pos: Vector2, angle_deg: float, speed: float, extra: Dictionary) -> Dictionary:
	var a := deg_to_rad(angle_deg)
	var d := extra.duplicate()
	d["x"] = emitter_pos.x
	d["y"] = emitter_pos.y
	d["vx"] = cos(a) * speed
	d["vy"] = sin(a) * speed
	# 箭头类贴图（血箭/光箭）美术朝向上方，按飞行方向旋转对齐。
	# 注意：子弹走 QuadMesh+MultiMesh 渲染，其 UV 在 2D 画布下垂直翻转，
	# 因此这里用 -90° 而非 +90°（+90° 会让箭尾超前）。
	var tex: String = d.get("tex", "")
	if tex.ends_with("_arrow"):
		d["rot"] = a - PI * 0.5
	return d

## 扇形：以 base_angle 为中心，均匀铺 count 发
func fan(pos: Vector2, count: int, base_angle: float, spread: float, speed: float, props: Dictionary = {}) -> void:
	if count <= 1:
		bullets.spawn(_p(pos, base_angle, speed, props))
		return
	var step := spread / float(count - 1)
	var start := base_angle - spread * 0.5
	for i in count:
		bullets.spawn(_p(pos, start + step * i, speed, props))

## 环形：等角分布，可带相位偏移
func ring(pos: Vector2, count: int, speed: float, props: Dictionary = {}, phase: float = 0.0) -> void:
	var step := 360.0 / float(count)
	for i in count:
		bullets.spawn(_p(pos, phase + step * i, speed, props))

## 螺旋：连续多帧，每帧一个环形并旋转相位
func spiral(pos: Vector2, arms: int, frames: int, period: int, speed: float, props: Dictionary = {}, spin: float = 7.0) -> void:
	for k in frames:
		var kk := k
		after(k * period, func(em: Emitter) -> void:
			em.ring(pos, arms, speed, props, kk * spin)
		)

## 瞄准玩家方向发射（需要 host 提供 player_pos）
func aimed(pos: Vector2, count: int, spread: float, speed: float, props: Dictionary = {}) -> void:
	var target := _player_pos()
	var base := rad_to_deg((target - pos).angle())
	fan(pos, count, base, spread, speed, props)

func _player_pos() -> Vector2:
	if host and host.has_method("get_player_pos"):
		return host.get_player_pos()
	return Vector2(390, 800)
