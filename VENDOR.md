# VENDOR：运行时快照

编辑器画布上的子弹不是示意动画，而是由一套真实的弹幕运行时跑出来的：同一份 `.brg`
在预览里和在目标工程里，必须飞出**同一条弹道**。为此本仓库原样收录了那套运行时的
若干文件——**代码一行未改**，只做只读快照。

下文把最终消费 `.brg`、同时提供这份运行时实现的那套工程统称为**目标工程**。

## 收录清单（sha256 前 16 位）

| 文件 | 作用 | sha256[:16] |
|---|---|---|
| `scripts/core/BrgLoader.gd` | `.brg` 语义层解析（XML → 发射器 / 弹道参数） | `1A546914C2CABB4B` |
| `scripts/core/BrgPlayback.gd` | 把语义层转成发射事件（含单弹压制 sidecar 的读写） | `78B799BFCBBFBAB8` |
| `scripts/core/BulletManager.gd` | 弹池 + 批量渲染 + 单弹拾取 `pick()` | `053D09D2B836F46D` |
| `scripts/core/Emitter.gd` | 运行时发射器（`BrgLoader` 的回退路径依赖它） | `94F0872D6FEE9357` |
| `scripts/core/TexLoader.gd` | 贴图加载与弹幕贴图烘焙（预烘焙档 / `user://` 缓存） | `F8D69705B1480FE4` |
| `scripts/core/Playfield.gd` | 设计坐标 ↔ 世界坐标换算（`SCALE`） | `95632B9A0A602DE4` |
| `scripts/core/PlayerConst.gd` | 自机常量（`BulletManager` 引用） | `69C4AE374D645D9C` |
| `scripts/core/Sanctity.gd` | 自机判定半径真值（画布上的判定圈按它绘制） | `09CC2ABE4D59EFC4` |
| `tools/bake_bullets.gd` | 预烘焙 `assets/textures_baked/`（与目标工程同一支脚本） | — |

> `scripts/editor/*` 与 `scenes/DanmakuForge.tscn` **不在**快照范围内：它们是本产品自有
> 代码，独立演进，只需要保持 `.brg` 文件格式不变。

## 方向

**目标工程是唯一真相源。** 想改运行时行为，请改工程侧、再同步过来；不要在这里直接改。
这里一旦私自改动，两边的弹道就会悄悄分叉，而「预览即实机」这个前提也就没了。

## 同步

```powershell
pwsh -File tools\sync_core.ps1 -GameDir "D:\path\to\your\project"
pwsh -File tools\sync_core.ps1 -GameDir "D:\path\to\your\project" -CheckOnly   # 只看差异
```

脚本逐个文件比对哈希、打印差异，然后覆盖更新，并提醒你跑下面的校验。

## 漂移校验（同步之后必跑）

```powershell
# ① 本产品自检：格式往返 / 写盘端到端 / 界面逻辑 / 弹道指纹
DanmakuForge.exe --headless -- --selftest

# ② 与目标工程逐帧一致性：同一批 .brg 两边各跑一次弹道指纹，逐行比对
#    （目标工程侧的同名入口：--bullet-fp）
godot --headless --path "<目标工程>" -- --bullet-fp 300               > $env:TEMP\fp_game.txt
DanmakuForge.exe --headless -- --bullet-fp 300 "<目标工程>\barrage"   > $env:TEMP\fp_editor.txt
# 两份文件的逐文件行（`[BulletFP] <name> n=… peak=… killed=… acc=… end=…`）
# 必须逐字节一致；末行 `files=/frames=/ms=` 含耗时，不参与比对。
```

**基线**：2026-09-18，10/10 行逐字节一致。

> 改动运行时（`scripts/core/`）之后，如果自检通过但这条比对不通过，说明预览用的实现
> 已经与目标工程分叉——以工程侧为准重新同步，不要改校验。
