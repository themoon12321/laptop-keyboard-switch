# =====================================================================
#  完整卸载: 用户组件 + Interception 驱动 + 残留文件 (会弹一次 UAC)
#  流程: 停守护(放行) -> 用户级清理 -> 卸载驱动 -> 校验过滤器还原 -> 清 ini/log
#  完成后需重启一次
# =====================================================================
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$log = Join-Path $dir 'uninstall-all.log'

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    exit
}
"=== uninstall-all $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Set-Content -LiteralPath $log -Encoding UTF8
function L($m) { Add-Content -LiteralPath $log -Value $m -Encoding UTF8 }
function Ok($m) { Write-Host "[OK] $m" -ForegroundColor Green }

Write-Host ''
Write-Host '=== 完整卸载 (含驱动) ===' -ForegroundColor White

# 1. 用户级清理 (会停掉守护进程 = 键盘自动放行)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'uninstall.ps1')
Ok '用户组件已清理'

# 2. 卸载驱动
$instExe = Join-Path $dir 'app\driver\install-interception.exe'
if (Test-Path $instExe) {
    Write-Host '[..] 卸载 Interception 驱动...'
    $o = & $instExe /uninstall 2>&1
    L "uninstall exit=$LASTEXITCODE out=$(($o | Out-String).Trim())"
    Ok '驱动卸载命令已执行'
} else {
    Write-Host '[..] 未找到驱动安装器, 跳过驱动卸载'
    L 'installer missing, skip driver uninstall'
}

# 3. 校验键盘/鼠标类过滤器已还原
Start-Sleep -Seconds 2
$kbCls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}'
$msCls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}'
$kbNow = @((Get-ItemProperty $kbCls -ErrorAction SilentlyContinue).UpperFilters)
$msNow = @((Get-ItemProperty $msCls -ErrorAction SilentlyContinue).UpperFilters)
$kbNow = @($kbNow | Where-Object { $_ })
$msNow = @($msNow | Where-Object { $_ })
L "after uninstall: kbd=[$($kbNow -join ',')] mouse=[$($msNow -join ',')]"
if ($kbNow -contains 'keyboard') {
    # 卸载器未清干净时手动兜底
    $fix = @($kbNow | Where-Object { $_ -ne 'keyboard' })
    Set-ItemProperty -Path $kbCls -Name UpperFilters -Value $fix -Type MultiString
    Write-Host '[!!] 键盘过滤器残留已手动清除' -ForegroundColor Yellow
}
if ($msNow -contains 'mouse') {
    $fix = @($msNow | Where-Object { $_ -ne 'mouse' })
    Set-ItemProperty -Path $msCls -Name UpperFilters -Value $fix -Type MultiString
    Write-Host '[!!] 鼠标过滤器残留已手动清除' -ForegroundColor Yellow
}
Ok '设备类过滤器已还原'

# 4. 残留文件
Remove-Item (Join-Path $dir 'app\KeyboardToggle.ini') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $dir 'app\KeyboardToggle.log') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $dir 'app\KeyboardToggle.log.old') -Force -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $dir 'app\driver') -Filter '*.log' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Ok '配置/日志已清理'

Write-Host ''
Ok '卸载完成, 请重启电脑彻底生效。'
Read-Host '按回车关闭'
