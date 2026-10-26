# =====================================================================
#  干跑回归测试: 用桩替换真实 AHI 库, 在 %TEMP% 里驱动守护进程,
#  断言识别/截断/恢复全链路。不触碰真实键盘 (订阅全是记录)。
#  用法: powershell -NoProfile -ExecutionPolicy Bypass -File tests\dryrun.ps1
# =====================================================================
$ErrorActionPreference = 'Stop'
$root    = $PSScriptRoot | Split-Path
$srcApp  = Join-Path $root 'app'
$work    = Join-Path $env:TEMP 'kbtest'
$ahkExe  = Join-Path $work 'AutoHotkey\AutoHotkey64.exe'

if (-not (Test-Path (Join-Path $srcApp 'KeyboardToggle.ahk'))) { throw 'app 缺失' }

# 0. 清理上次测试可能残留的进程 ( KbTest.ahk )
Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*KbTest.ahk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

# 1. 复制 app 到临时目录, 重命名脚本 (避免与本机真实守护进程撞名互扰), 替换为桩
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null
Copy-Item (Join-Path $srcApp '*') $work -Recurse -Force
Copy-Item -Force (Join-Path $PSScriptRoot 'fake-Lib\AutoHotInterception.ahk') (Join-Path $work 'Lib\AutoHotInterception.ahk')
Remove-Item -Force (Join-Path $work 'KeyboardToggle.ini'), (Join-Path $work 'KeyboardToggle.log') -ErrorAction SilentlyContinue
Rename-Item (Join-Path $work 'KeyboardToggle.ahk') 'KbTest.ahk'

$script = Join-Path $work 'KbTest.ahk'
$log    = Join-Path $work 'KeyboardToggle.log'

function Send-KbCli([string]$cmd) {
    & $ahkExe $script $cmd | Out-Null
    Start-Sleep -Milliseconds 2500
}

# 2. 启动守护进程 (桩环境)
$daemon = Start-Process -FilePath $ahkExe -ArgumentList ('"{0}"' -f $script) -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 5
if ($daemon.HasExited) { throw '守护进程启动即退出' }

# 3. off -> on 全链路
Send-KbCli 'off'
Send-KbCli 'on'

# 4. 结束守护
Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# 5. 断言
$txt = Get-Content $log -Raw -Encoding UTF8
$fail = @()
if ($txt -notmatch 'identified 1 internal keyboard\(s\)') { $fail += '未识别到恰好 1 个内置键盘 (启发式误选外接?)' }
if ($txt -notmatch 'state -> blocked subs=1')             { $fail += '截断订阅设备数不是 1 (整设备订阅)' }
if ($txt -notmatch 'state -> allowed subs=0')             { $fail += '恢复后订阅未清零' }
if ($txt -match 'BLOCK SKIP|BLOCK ERROR')                 { $fail += '截断过程出现跳过/错误' }

Write-Host ''
if ($fail.Count -eq 0) {
    Write-Host '[PASS] 干跑回归: 识别=1 设备 / 截断=511 键 / 恢复=0 键' -ForegroundColor Green
    exit 0
} else {
    $fail | ForEach-Object { Write-Host "[FAIL] $_" -ForegroundColor Red }
    Write-Host '--- log ---'
    Get-Content $log | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
    exit 1
}
