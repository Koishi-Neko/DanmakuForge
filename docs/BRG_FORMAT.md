# SlimeStorm `.brg` 弹幕工程格式与移植指南

> 适用版本：`.brg` ver 1.02（SlimeStorm 1.02 内置弹幕播放器 / 编辑器）
> 安装参考：`D:\steam\steamapps\common\SlimeStorm`
> 本文汇总 2026-09-11 教程移植的全部经验；原始手册节选与属性表已归档到
> `docs/reference/slime/`，**不要依赖临时目录里的散落笔记**。

---

## 1. 容器格式：纯 XML

`.brg` 就是 XML 文本（早期误判为二进制，已推翻）。结构：

```xml
<Barrage>
  <version>ver 1.02</version>
  <Beat>20</Beat>          <!-- BPM，仅音乐同步用，与弹幕逻辑无关 -->
  <Offset>0</Offset>
  <MaxTime>1200</MaxTime>  <!-- 整段时长（帧），Loop 时循环 -->
  <Loop>true</Loop>
  <BulletEmitterList>      <!-- 子弹发射器；本工程当前只消费这一种 -->
    <EmitterBullet> ... </EmitterBullet>
  </BulletEmitterList>
  <LaserEmitterList />     <!-- 激光 -->
  <EnemyEmitterList />     <!-- 敌机 -->
  <EffectEmitterList />    <!-- 特效 -->
  <AffecterList />
  <LinkCopyList />
</Barrage>
```

样例工程：`docs/reference/slime/sample_tutorial_hell_spiral.brg`
（桌面「新手教程1非：地狱螺旋.brg」的归档副本）。

---

## 2. EmitterBullet 字段速查

### 发射器本体

| 字段 | 含义 | 单位 / 取值 |
|---|---|---|
| `ID` / `Tag` | 编号 / 标签 | |
| `StartTime` | 首次生效时间 | 帧；样例 `1`（移植时 `t = age - 1`） |
| `Duration` | 持续时长 | 帧 |
| `Position` (X,Y) | 发射器自身位置 | 画布坐标；绑定宿主时为其偏移。样例 `(0,-128)` |
| `Velocity`/`Direction`/`Accelerate`/`AccDirection` | **发射器自身**运动 | 与子弹参数无关 |
| `TextureName` | 图集区域名 | 如 `bullet62_1`，见 §6 |
| `HiRes` | 2x 贴图标志 | 内置播放器不支持，渲染尺寸折半 |
| `BindingID` / `DeepBinding` / `BindWithDirection` / `DeathBinding` | 宿主绑定 | `-1` = 无绑定 |
| `Disabled` | 停用 | |
| `EventGroupList` | 发射器事件组 | 见 §4 |
| `BulletEventGroupList` | 子弹自身事件组 | 本样例为空，未实现 |

### 发射几何

| 字段 | 含义 | 单位 / 取值 |
|---|---|---|
| `EmitPoint` (X,Y) | 发射点 | `-99998` = **自身**（跟随发射器）；「自机」= 跟随玩家 |
| `EmitRadius` | 发射半径 | 粒子从半径 r 的圆上出生 |
| `RadiusDirection` | 半径方向 | 度；「自机」= 指向玩家 |
| `RDirectionFollowsEDirection` | 半径方向=发射角度 | bool |
| `Way` | 条数（每环粒子数） | 整数；样例 A=4、B=9 |
| `Circle` | 周期 | 帧；样例 A=5、B=30 |
| `EmitDirection` | 发射角度 | 度；`90` = 正下；`-99999` = **指向自机** |
| `Range` | 范围 | 度；粒子围绕 `EmitDirection` 均布。`360` = 整环 |
| `Count` | 层数 | 整数；样例均为 1 |
| `DeltaV` | 层差速度 | 每层速度增量（px/帧） |
| `DeltaA` | 层差角度 | 每层角度增量（度） |
| `Layer` | 渲染层 | `Top` / `Middle` / `Bottom` |
| `EmitTimeList` | 额外发射时间点 | 帧列表 |

### 粒子（子弹）

| 字段 | 含义 | 单位 / 取值 |
|---|---|---|
| `LifeTime` | 生命 | 帧；样例 500 |
| `BulletVelocity` | 速度 | px/帧；样例 A=2、B=1.5 |
| `BulletDirection` | 初始方向 | 相对 `EmitDirection` |
| `BulletAccelerate` | 加速度 | px/帧²；样例 A=0、B=0.01 |
| `BulletAccDirection` | 加速度方向 | 度；`90` = 固定向下（**不随速度转向**）；B 使用 |
| `ScaleWidth` / `ScaleHeight` / `ScaleWidthEqualsScaleHeight` | 缩放 | B = 0.55 |
| `ColorValue` | 颜色 | `ARGBColor:a:r:g:b`，乘算；白=贴图原色 |
| `Transparent` | 透明度 | 0~255 |
| `Angle` / `AngleFollowsDirection` | 贴图旋转 / 跟随速度方向 | |
| `AngularVelocity` | 角速度 | |
| `BeginningEffect` / `BeginMode` / `EndingEffect` | 出/消弹特效 | 内置播放器有出弹缩放闪光 |
| `Blend` | 混合模式 | `AlphaBlend` 等 |
| `Ghosting` / `GhostingCount` | 残影 | |
| `OutBound` | 出屏即消 | bool；B=true，A=false（靠 LifeTime 回收） |
| `Protect100` | 前 100 帧不出屏销毁 | bool |
| `UnRemoveable` | 不可被消除（炸弹清不掉） | bool |
| `Reflect` / `ReflectEdges` | 反弹 / 反弹边 | 0 = 关 |
| `Region` / `VisualSize` | 判定区域 / 视觉判定尺寸 | 0 = 跟贴图 |
| `RanX`/`RanY`/`RanRadius`/`RanRadiusDirection`/`RanWay`/`RanCircle`/`RanEmitDirection`/`RanRange` | 发射随机量 | 每环按范围随机 |
| `RanBulletAngle`/`RanBulletVelocity`/`RanBulletDirection`/`RanBulletAccelerate`/`RanBulletAccDirection` | 粒子随机量 | |
| `Twinkle*` | 颜色闪烁（周期/目标色/模式） | |
| `BackImage*` | 背层贴图（子图）参数 | |

---

## 3. 事件系统（EventData）

事件组挂在 `EventGroupList` 下，每组：

```xml
<EventGroup_Emitter>
  <Loop>true</Loop>          <!-- 条件是否循环触发 -->
  <LoopCircle>0</LoopCircle>
  <EventList>
    <EventData> ... </EventData>
  </EventList>
</EventGroup_Emitter>
```

| 字段 | 含义 |
|---|---|
| `Mode` | 作用对象：`Emitter` / `Bullet` |
| `contype` / `contype2` | 条件量：`Time`（帧）等 |
| `conditionValue` / `conditionValue2` | 条件值；来源 `conditionSource=Constant` |
| `opreator` / `opreator2` | 比较：`Equal` / `Greater` / `Less` … |
| `changemode` | `Increase` / `Decrease` |
| `changetype` | `Step`（立即跳变）/ `Linear`（在 `changetime` 帧内线性完成） |
| `changename` | 属性数字 ID（见下） |
| `ChangeNameEmitter` / `ChangeNameBullet` / `ChangeNameAffecter` | 属性名（**导入时直接读字符串，不要依赖数字 ID**） |
| `res` (=1) | 变化量 |
| `changetime` (=1) | 变化时长（帧） |

`changename` 数字 ID = **对应 `ChangeName*` 枚举的序号**（运行时按它选属性；务必与
`ChangeName*` 字符串一致，不然事件等于没生效）。权威序号（2026-09-11 反射取得）：

```
ResultEmitter (ChangeNameEmitter) 序号：
  0 PositionX  1 PositionY  2 Radius  3 RadiusDirection  4 Way  5 Circle
  6 EmitterDirection  7 Range  8 Velocity  9 Direction  10 Acceleration
  11 AccDirection  12 LifeTime  13 ScaleWidth  14 ScaleHeight  15 R  16 G  17 B
  18 Transparent  19 Angle  20 BulletVelocity  21 BulletDirection
  22 BulletAcceleration  23 BulletAccDirection  24 ScaleX  25 ScaleY
  26 BeginEffect  27 EndEffect  28 BlendMode  29 Ghosting  30 OutBound
  31 Unremoveable  32 TextureName  33 ParaA  34 ParaB  35 Count  36 DeltaV  37 DeltaA

ResultBullet (ChangeNameBullet) 序号：
  0 LifeTime  1 ScaleWidth  2 ScaleHeight  3 R  4 G  5 B  6 Transparent  7 Angle
  8 Velocity  9 Direction  10 Acceleration  11 AccDirection  12 ScaleX  13 ScaleY
  14 BeginEffect  15 EndEffect  16 BlendMode  17 Ghosting  18 OutBound
  19 Unremoverable  20 TextureName  21 PositionX  22 PositionY  23 Cover
  24 AngularVelocity
```

范例（四臂弹流整体下坠）：`Mode=Bullet`、`contype=TimeMain`（全局帧）、
`changename=10` + `ChangeNameBullet=Acceleration`、`changename=11` +
`ChangeNameBullet=AccDirection`。

> **权威枚举（2026-09-11 从 `Barrage.dll` 反射取得，编辑器严格校验，写错就报
> 「XML 文档(N,C)中有错误」）**：
> - `Operator` = `Equal` / `Greater` / `Less`（**没有 `GreaterEqual`**）
> - `Condition` = `Time` / `TimeMain` / `PositionX` / `PositionY`
> - `EventType`(=`Mode`) = `None` / `Emitter` / `Bullet` / `Affecter`
> - `ChangeMode` = `ChangeTo` / `Increase` / `Decrease`
> - `ChangeType` = `Linear` / `Step` / `Sin` / `Cos` / `EaseIn` / `EaseOut` / `EaseInOut`
> - `ChangeNameEmitter`(`ResultEmitter`) 成员：`PositionX` `PositionY` `Radius`
>   `RadiusDirection` `Way` `Circle` `EmitterDirection`（不是 `EmitDirection`）`Range`
>   `Velocity` `Direction` `Acceleration` `AccDirection` `LifeTime` `ScaleWidth`
>   `ScaleHeight` `R` `G` `B` `Transparent` `Angle` `BulletVelocity`
>   `BulletDirection` `BulletAcceleration` `BulletAccDirection` `ScaleX` `ScaleY`
>   `BeginEffect` `EndEffect` `BlendMode` `Ghosting` `OutBound` `Unremoveable`
>   `TextureName` `ParaA` `ParaB` `Count` `DeltaV` `DeltaA`
> - `ChangeNameBullet`(`ResultBullet`) 成员：`LifeTime` `ScaleWidth` `ScaleHeight`
>   `R` `G` `B` `Transparent` `Angle` `Velocity` `Direction` **`Acceleration`**
>   **`AccDirection`** `ScaleX` `ScaleY` `BeginEffect` `EndEffect` `BlendMode`
>   `Ghosting` `OutBound` `Unremoverable` `TextureName` `PositionX` `PositionY`
>   `Cover` `AngularVelocity`
>
> 注意两边命名不一致：发射器角度是 `EmitterDirection`；粒子速度是 `Velocity`、
> 加速度是 `Acceleration`（不是 `BulletVelocity`/`BulletAccelerate`）。
> 即便 `Mode=Bullet`，`ChangeNameEmitter`/`ChangeNameAffecter` 也必须填合法成员（否则照样报错）。

样例解释（教学螺旋）：

- 组 1（`Loop=true`）：条件 `Time > 0` → `EmitDirection` Increase Linear，res=1、
  changetime=1 ⇒ **每帧 +1°**（旋转相位）。
- 组 2（`Loop=false`）：六个 `Time == 25/50/75/100/125/150` 事件 →
  t=25 为 Step +1，t≥50 为 Linear +1（changetime=1，等效 +1）⇒ **Way 4→10**。

### 事件执行语义（关键，2026-09-11 对齐）

**每帧检测条件，满足就执行结果**（手册 5.7.1）。因此：

- `opreator=Equal`（如 `TimeMain == 60`）→ 只在那一帧满足 → **一次性**。
- `opreator=Greater/Less`（如 `TimeMain > 59`）→ 之后每帧都满足 → **每帧重放**。
  - `Increase/Decrease` 会逐帧累积（样例旋转 1°/帧）。
  - `ChangeTo` 每帧重设同一值（幂等）；但若用来设**速度**，会把累积的加速度
    “压回”基速 —— 例如下坠想要加速，起速必须用 `Equal` 一次性给，之后只留
    `Acceleration ChangeTo` 每帧重放。
- 引擎侧 `BulletManager` 对子弹事件即按此规则**每帧重估条件**（不再一事件触发一次）。

---

## 4. 单位、方向与时间基准

- 时间：**帧 @ 60fps**（`Beat` 只影响音乐）。
- 位置：画布像素；速度：px/帧；加速度：px/帧²。
- 角度：度，0° = 右（+x），90° = 下（+y），顺时针增大（屏幕坐标，y 向下）。
- 哨兵值：点字段 `-99998` = 自身（发射器）、角度字段 `-99999` = 指向自机；
  **不能当普通数字参与计算**。
- 移植时间基准：样例 `StartTime=1`，教程取 `t = age - 1`（入场结束的第一帧为 t=0）。
- 单位映射（2026-09-17 起）：`size` / `hit`（判定）为**世界单位直写、不随 `Playfield.SCALE`**；
  位置 / 速度 / 加速度随 SCALE 换算（见 §5）。

---

## 5. 设计画布与本工程映射（Playfield）

- DanmakuPlayer 窗口 **1280×960**：左右边栏各 256、中央**战场可见矩形 768×896 @ (256,32)**
  （2026-09-16 新典比例）。**`.brg` 画布仍是 780×960 设计空间**（与编辑器画布一致，
  不随分辨率改造变动）。
- 2026-09-17 决议（战斗区 390×480）：世界空间缩到 **390×480**，`Playfield.SCALE = 0.5`
  （≈红魔乡原生 384×448）。世界坐标 = 画布坐标 × 0.5；屏幕上由 Game 根节点放大约
  1.97/1.87 显示 → 屏上布局与改造前逐像素一致。
- **尺寸/判定冻结**：`size` / `hit`（判定半径）是**世界单位直写、不随 SCALE**（屏上净 +43%，
  由 `ART_SCALE` 1.4→1.0 配合）；位置 / 速度 / 加速度随 SCALE。
- 编辑器：BrgEditor 画布/文档仍是 780×960；预览的 BulletManager 以 `scale = 1/SCALE`
  显示回设计空间，宿主 / 自机 / 单弹拾取在做坐标换算。

| `.brg` 量 | 本工程（`SCALE = 0.5`） | 公式 |
|---|---|---|
| 位置（画布 px） | 世界像素（×0.5） | `pos = Playfield.pos(x, y)` |
| 速度（px/帧） | 世界 px/s | `v × 60 × 0.5`（`Playfield.speed`） |
| 加速度（px/帧²） | 世界 px/s² | `a × 3600 × 0.5`（`Playfield.accel`） |
| 尺寸/判定（px） | **世界单位直写（冻结）** | `size` / `hit` 不换算 |
| 时间（帧） | 帧 | 不变（固定 60fps 逻辑步） |
| 角度（度） | 度 | 不变（同为 y 向下顺时针） |

`Way` 在整环均布；`Range` 围绕 `EmitDirection` 均布（`Range=360` 即整环）。

---

## 6. 贴图与图集解析

- 图集定义在安装目录 `Image\Bullet\*.txt`，每行：
  `name  x  y  w  h  0  0`。
- 例：`bullet-6.txt` 中 `bullet62_1  32  0  32  32` ⇒ 原生 **32×32**；
  `HiRes=false`、`ScaleWidth/Height=1`。
- **弹径必须按图集原生尺寸渲染**（内容占比不同的贴图要按可见亮核校正）：
  本工程 `bullet_orb.png` 内容约占画布 2/3，quad 取 32 设计像素时可见亮核 ≈21px，
  与 `bullet62_1` 实测亮核一致。曾因自造 `size=17` 导致弹链观感稀疏一倍。
- `ColorValue` 为乘算：白色保留贴图原色；本工程把红/紫等颜色经实例色施加。
- 图集尺寸不会随工程文件携带，导入时需查安装目录或维护映射表。

---

## 7. 当前覆盖度

**导入器已实现**（`scripts/core/BrgLoader.gd` 解析 + `scripts/core/BrgPlayback.gd` 播放，
2026-09-11）：

- `BrgLoader`：XML → 数据类（`Barrage` / `BrgEmitter` / `EventGroup` / `Event`），按
  `ChangeName*` 字符串解析，哨兵 `-99998`/`-99999` 原样保留
- 调度：`StartTime` / `Duration` / `EmitTimeList`；`MaxTime` / `Loop`（`finished()`）
- 事件组：`Time` 条件 + `Equal`/`Greater`/`Less`… + `Step`/`Linear`（`changetime>1` 逐帧）
  + `Increase`/`Decrease` + `Loop`/`LoopCircle`
- 多层 / 几何：`Count` + `DeltaV`/`DeltaA`、`EmitRadius` + `RadiusDirection`、
  `Range` 环（≥360）与扇均布、`EmitDirection` 自机狙
- 弹体：`BulletVelocity`/`BulletDirection`/`BulletAccelerate` + `BulletAccDirection`
  （定向加速度）、`LifeTime`、`ScaleWidth`/`ScaleHeight`、`ColorValue`/`Transparent`、
  `Angle`/`AngleFollowsDirection`/`AngularVelocity`、`OutBound`/`Protect100`/`UnRemoveable`
- **子弹自身事件 `BulletEventGroupList`**：按条件触发，可改
  `Acceleration`/`AccDirection`/`Velocity`/`Direction`/`AngularVelocity`/`LifeTime`。
  `contype=Time` 按**子弹年龄**触发；`contype=TimeMain` 按**全局时间**触发（全体子弹
  同一时刻触发，如「四臂弹流成十字后整体下坠」）。`Step` 立即生效；`Linear` 当前按单步近似
- 随机量：`RanWay`/`RanCircle`/`RanEmitDirection`/`RanRange` 与 `RanBullet*`（基础实现）。
  ⚠ `RanX`/`RanY`/`RanRadius` **只解析未消费**（发射位置随机化未实现，勿用）
- **追踪弹扩展（2026-09-13，本工程复用保留字段）**：发射器 `ParaA` > 0 ⇒ 该发射器的
  子弹为追踪弹，转向速率 = `ParaA` 度/帧（`BrgLoader.para_a` → `BrgPlayback._spawn_one`
  写入 `info["homing"]` → `BulletManager._home` rad/s）。每帧把速度向量朝
  `BulletManager.homing_target` 拧（限速转向，可绕圈甩开）；`homing_target` 由
  `BrgPlayback.step()` 每帧写入自机位置（编辑器预览 = 画布上可拖动的自机点）。
  `ParaB` 已解析预留。编辑器保真层对 `ParaA/ParaB` 无损读写。
- **发射器自身运动**（2026-09-12 补）：`Velocity`/`Direction`/`Accelerate`/`AccDirection`
  逐帧积分，发射器可从宿主出发自走；发射点选「自身」时子弹从移动后的位置发出
  （`BrgPlayback._emit_origin` 叠加 `self_pos`）。发射器事件改 `Direction`/`Velocity`/
  `Acceleration`/`AccDirection` 可让小球转弯（做环绕轨道）。
- 图集映射：`BrgPlayback.ATLAS`（`bullet62_1 → orb 32²`，`HiRes` 折半）；
  **一面外区弹幕贴图（2026-09-15 补）**：`bullet_decor_wisp`(16²)、`bullet_decor_lantern`(20²)、
  `bullet_decor_higanbana`(17²)、`bullet_decor_ripple`(20²)、`bullet_decor_soul_core`(36²)、
  `bullet_decor_grave_dust`(15²)（判定半径见 ATLAS 的 `hit`；soul_core 可用
  `ScaleWidth=1.333` 放大到 48px 巨弹）
- **外区弹幕（一面，2026-09-15）**：`.brg` 直接内嵌"自机不会去"的空域弹幕
  （顶带 / 左右竖带 / 下方两角；禁区 `Rect2(160,520,460,440)` 零进入）。
  注入器 `tools/inject_outer_danmaku.py`（幂等，Tag 以 `outer-` 开头）；
  自检 `tools/outer_zone_check.gd`（仿真两循环，断言密度与禁区）。
  密度目标：非符 ≈220 / 符卡 ≈400 / 终符 ≈560（新增发射器同屏），巨弹 4-6 / 8-10 / 12-14。
- 教学语义：`visual_overrides`（按发射器序号替换贴图/颜色/尺寸/判定，如污染弹）

**教程已改为加载 `.brg`**（`TutorialStage.gd`）：`BrgLoader.load_file()` + `BrgPlayback`，
配 `--brg-dump N` 做几何对照。

**尚未实现**（按需再补）：

- `BeginningEffect` 出弹缩放闪光、`Top/Middle/Bottom` 渲染层
- `BindingID` 宿主绑定（发射器绑定到别的发射器/子弹，实现「子发射器」）
- `Twinkle*` / `BackImage*` / `Reflect` / `VisualSize`- Laser / Enemy / Effect / Affecter / LinkCopy 四类发射器
- 完整图集区域名映射表（含内容占比校正）

---

## 8. 踩坑记录

1. **`.brg` 是 XML**——不要按二进制魔改；直接 XML 解析即可。
2. **弹径决定观感密度**：必须按图集原生尺寸（`bullet62_1`=32×32），自造的
   17px 让链看起来稀疏一倍（2026-09-11 修正）。
3. **加速度有两种语义**：沿速度方向 vs 固定方向（`BulletAccDirection`）。
   解析时看 `BulletAccelerate` 是否非 0：A=0，B=0.01 且方向 90（固定向下）。
4. **`Linear` 事件**在 `changetime=1` 时与 `Step` 等效；按事件净增量实现即可。
5. **时间基准**：`StartTime=1`，迁移时 `t = age - 1`；否则整体提前一帧。
6. **发射器 `Position` 偏移**：样例 `(0,-128)`。教程把发射器锚在撒旦中心，
   未叠该偏移（约等于把宿主摆低 128px）；严格复刻时需带偏移。
7. **窗口 ≠ 画布**：1280×960 窗口里两侧各 250 宽是 UI 面板，画布是 780×960。
8. **播放器截屏是黑屏**（DirectX 表面），无法像素级对比；用数据对照 + 机器人 + 截图。
9. **发射器事件跨循环不复位**（2026-09-15）：`BrgPlayback` 循环重播只重置
   `fired`/`linear`/`self_pos`/`self_speed`/`self_dir`/`self_accel`/`self_acc_dir`，
   **`emit_direction`/`way`/`circle`/`range`/`emit_radius` 等事件累加值不会归零**——
   用 `EmitterDirection` 事件持续自转的发射器会一圈圈转下去（实测 0.06°/帧 在两循环内
   累积 72°+，把上半圆环幕转进禁区）。需要"循环内往复/自转"时应改成
   **静态几何 + 弹体自旋（`AngularVelocity`）**，或给引擎补上"循环复位事件值"。

---

## 9. 验证方法

- 几何对照：同帧导出子弹位置/速度，与按 `.brg` 公式手算或播放器目视比对。
- 本项目工具：
  - `--brg-dump N [--brg-file PATH]`：无窗口跑前 N 帧，打印每帧发射几何（发射器 / 条数 / 首弹速度角度）
  - `--brg-sim N [--brg-file PATH]`：用真 `BulletManager` 跑 N 帧并打印 0 号弹弹道，验证 `BulletEventGroupList`（先直飞后下坠）
  - `--auto --tutorial --auto-policy dodge|aim`（通关/生存回归）
  - `--shot`（截图存档，`build/shots/`）
  - `--system-test`（机制自检）
- 关键回归指标：`cleared`、`lives_left`、`dead_frames`、`avg_bullets`、`max_bullets`。

---

## 10. 参考资料

> **可视化编辑器见 [`BRG_EDITOR.md`](BRG_EDITOR.md)**（`BrgEditor`，P0 已完成）。
> 编辑器走**保真层 `BrgDocument`**，不是本文件的 `BrgLoader`——
> 因为 `BrgLoader` 只解析 146 种标签里的 72 种，直接拿它做模型再存回会**静默抹掉
> 74 种字段**（发射器自身 `Velocity/Direction/Accelerate/AccDirection`、`BindingID`、
> `Blend`、`Ghosting*`、`Twinkle*`、`BackImage*`、`Region/VisualSize`、`Reflect*`、
> `ParaA/ParaB`、`ScaleX/ScaleY`、`Affect`、`MotionLink` …）。
> 保真写回的完整规格（6 条）与 139/139 逐字节验证见 `BRG_EDITOR.md` §3。

仓库内（已归档）：

- `docs/reference/slime/prop_names.txt`：发射器/粒子属性名与显示名对照
- `docs/reference/slime/prop_attrs.txt`：属性 C# 类型清单（反射整理）
- `docs/reference/slime/manual_section_4_3_props.txt`：手册 4.3 子弹属性
- `docs/reference/slime/manual_section_5_editor.txt`：手册第五章（编辑器交互）
- `docs/reference/slime/manual_en.txt`：英文手册全文
- `docs/reference/slime/sample_tutorial_hell_spiral.brg`：教程样例工程

安装目录：

- `D:\steam\steamapps\common\SlimeStorm\SlimeStorm_UserManual_CN.html` / `_EN.html`
- `D:\steam\steamapps\common\SlimeStorm\Image\Bullet\*.txt`（图集定义）
- `D:\steam\steamapps\common\SlimeStorm\BulletPlayer\DanmakuPlayer.exe`（参考播放器）
