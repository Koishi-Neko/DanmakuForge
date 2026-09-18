class_name PlayerConst
extends RefCounted
## 全局数值常量：让 Game / Player / 自动测试脚本读同一份真值

const HIT_R := 3.2
const GRAZE_R := 30.0     # 擦弹环宽（红魔乡换算 ~40，取 25~40 中值偏保守）
const SPEED_FAST := 540.0  # 9 px/帧 @60fps（红魔乡换算 8.1~10.2 区间）
const SPEED_SLOW := 270.0  # 4.5 px/帧（红魔乡换算 4.1~5.1 区间）；斜向由 Player 归一化 ÷√2
