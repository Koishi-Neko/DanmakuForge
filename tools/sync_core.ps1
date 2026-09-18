# tools/sync_core.ps1 —— 从目标工程同步运行时快照
#
# 用法：
#   pwsh -File tools\sync_core.ps1 -GameDir "D:\path\to\your\project"
#   pwsh -File tools\sync_core.ps1 -GameDir "D:\path\to\your\project" -CheckOnly
#
# 背景见 VENDOR.md：下面这些文件是目标工程运行时的只读快照，编辑器的弹幕预览必须与
# 运行侧逐帧一致。同步之后请跑一次 --selftest，以及双工程的 --bullet-fp 逐行比对。

[CmdletBinding()]
param(
    [string]$GameDir = "",
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $PSScriptRoot          # 本仓库根目录

$Files = @(
    "scripts/core/BrgLoader.gd",
    "scripts/core/BrgPlayback.gd",
    "scripts/core/BulletManager.gd",
    "scripts/core/Emitter.gd",
    "scripts/core/TexLoader.gd",
    "scripts/core/Playfield.gd",
    "scripts/core/PlayerConst.gd",
    "scripts/core/Sanctity.gd",
    "tools/bake_bullets.gd"
)

if ($GameDir -eq "") {
    Write-Error "请用 -GameDir 指定目标工程的根目录（含 scripts/core/BrgLoader.gd 的那一层）"
}
if (-not (Test-Path $GameDir)) {
    Write-Error "找不到目录：$GameDir"
}
if (-not (Test-Path (Join-Path $GameDir "scripts/core/BrgLoader.gd"))) {
    Write-Error "$GameDir 下没有 scripts/core/BrgLoader.gd——请确认它指向目标工程根目录"
}

Write-Host "来源：$GameDir"

$changed = 0
$same = 0
$new = 0
foreach ($rel in $Files) {
    $src = Join-Path $GameDir $rel
    $dst = Join-Path $Here $rel
    if (-not (Test-Path $src)) { Write-Warning "来源缺文件，跳过：$rel"; continue }
    $srcHash = (Get-FileHash $src -Algorithm SHA256).Hash
    if (-not (Test-Path $dst)) {
        Write-Host ("  + 新增  {0}" -f $rel)
        $new++
    } else {
        $dstHash = (Get-FileHash $dst -Algorithm SHA256).Hash
        if ($srcHash -eq $dstHash) { $same++; continue }
        Write-Host ("  ~ 更新  {0}  {1} -> {2}" -f $rel, $dstHash.Substring(0, 8), $srcHash.Substring(0, 8))
        $changed++
    }
    if (-not $CheckOnly) {
        $dir = Split-Path -Parent $dst
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Copy-Item $src $dst -Force
    }
}

Write-Host ("同步结果：{0} 个有新内容，{1} 个未变，{2} 个新增{3}" -f `
    $changed, $same, $new, $(if ($CheckOnly) { "（-CheckOnly，未覆盖）" } else { "" }))

if ($changed -gt 0 -or $new -gt 0) {
    Write-Host ""
    Write-Host "下一步（VENDOR.md 的漂移校验）：" -ForegroundColor Yellow
    Write-Host "  ① 自检：  godot --headless --path `"$Here`" -- --selftest"
    Write-Host "  ② 双工程 --bullet-fp 300 逐行比对，必须逐字节一致"
}
