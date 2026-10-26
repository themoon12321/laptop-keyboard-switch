# =====================================================================
#  一键安装 (新机器 / 重装通用)
#  做的事:
#    1. 自检管理员并自我提权 (弹一次 UAC)
#    2. 预检: ARM64 拒装 / 内存完整性(HVCI)警告确认 / 执行策略
#    3. 解除文件网络锁定 (Unblock-File, 整个 app 目录)
#    4. 安装 Interception 驱动 (可 -SkipDriver 跳过)
#    5. 关键调优: 服务改 SYSTEM_START (否则冷启动后驱动不加载, 识别失败)
#    6. 拆除鼠标侧过滤绑定并重启鼠标设备 (可 -KeepMouseFilter 跳过)
#    7. 每步结果校验, 失败即停
#    8. 调用用户级 install.ps1 (桌面快捷方式 + 开机自启)
#  用法: setup.cmd 双击, 或管理员 PowerShell 运行本文件; 完成后需重启一次
# =====================================================================
param(
    [switch]$SkipDriver,       # 已装过驱动, 只做调优+用户组件
    [switch]$KeepMouseFilter,  # 保留鼠标侧过滤绑定 (默认拆除)
    [switch]$YesToAll          # 跳过所有交互确认 (无人值守)
)
$ErrorActionPreference = 'Stop'
$dir  = $PSScriptRoot
$app  = Join-Path $dir 'app'
$log  = Join-Path $app 'driver' 'setup.log'

# ---- 0. 提权 ----
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args_ = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($SkipDriver)     { $args_ += '-SkipDriver' }
    if ($KeepMouseFilter){ $args_ += '-KeepMouseFilter' }
    if ($YesToAll)       { $args_ += '-YesToAll' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $args_
    exit
}

function Info($m) { Write-Host "[..] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!!] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[XX] $m" -ForegroundColor Red; Read-Host '安装中止, 按回车关闭'; exit 1 }

New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
"=== setup $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Set-Content -LiteralPath $log -Encoding UTF8
function L($m) { Add-Content -LiteralPath $log -Value $m -Encoding UTF8 }

Write-Host ''
Write-Host '=== 笔记本内置键盘热开关 · 一键安装 ===' -ForegroundColor White
Write-Host ''

# ---- 1. 预检 ----
Info '预检系统环境...'
$arch = $env:PROCESSOR_ARCHITECTURE
L "arch=$arch os=$([Environment]::OSVersion.VersionString)"
if ($arch -eq 'ARM64') {
    Fail '本机是 ARM64 (骁龙等) 处理器, Interception 驱动不支持 ARM64, 无法安装。'
}

$hvciOn = $false
try {
    $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction Stop).Enabled
    if ($v -eq 1) { $hvciOn = $true }
} catch { }
if (-not $hvciOn) {
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
        if ($dg.SecurityServicesRunning -contains 2) { $hvciOn = $true }
    } catch { }
}
if ($hvciOn) {
    Warn '检测到「内存完整性 (HVCI)」已开启。'
    Warn 'Interception 驱动是 2012 年个人签名, HVCI 会拒绝加载,'
    Warn '最坏情况会导致所有键盘 (含外接) 失效, 只能进安全模式恢复。'
    if (-not $YesToAll) {
        $a = Read-Host '继续安装? 建议先到 设置->隐私和安全性->Windows 安全中心->设备安全性->内核隔离 关闭内存完整性 (y/N)'
        if ($a -ne 'y' -and $a -ne 'Y') { Fail '已按用户选择中止。' }
    } else { L 'HVCI on, forced continue by -YesToAll' }
} else { Ok '内存完整性未开启, 驱动可正常加载' }
L "hvci=$hvciOn"

Info '解除文件网络锁定标记 (压缩包经网络传输会带上)...'
try { Get-ChildItem -LiteralPath $app -Recurse -File | Unblock-File; Ok '已解除' } catch { Warn "Unblock 跳过: $($_.Exception.Message)" }

# ---- 2. 驱动 ----
$instExe = Join-Path $app 'driver\install-interception.exe'
if (-not (Test-Path $instExe)) { Fail "找不到驱动安装器: $instExe" }

if ($SkipDriver) {
    Info '跳过驱动安装 (-SkipDriver)'
} else {
    Info '安装 Interception 过滤驱动...'
    $o = & $instExe /install 2>&1
    $code = $LASTEXITCODE
    L "install exit=$code out=$(($o | Out-String).Trim())"
    if ($code -ne 0) {
        $o | ForEach-Object { Write-Host "    $_" }
        Fail "驱动安装失败 (exit=$code), 详见 $log"
    }
    Ok '驱动安装命令执行成功'
}

# ---- 3. 关键调优: SYSTEM_START (否则冷启动后 devlist=0) ----
Info '设置驱动服务为系统启动 (修复冷启动识别不到的问题)...'
foreach ($svc in 'keyboard', 'mouse') {
    $o = & sc.exe config $svc start= system 2>&1
    if ($LASTEXITCODE -ne 0) { L "$svc sc-config: $($o|Out-String)"; Fail "无法设置服务 $svc 启动类型 (服务不存在? 驱动未装?)" }
}
Ok '服务已设为 SYSTEM_START'

# ---- 4. 校验 ----
Info '校验安装结果...'
$kbdSvc = & sc.exe qc keyboard 2>&1 | Out-String
if ($kbdSvc -notmatch 'SYSTEM_START') { Fail 'keyboard 服务未生效为 SYSTEM_START' }
$kbFilters = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}').UpperFilters
if ($kbFilters -notcontains 'keyboard') { Fail "键盘类 UpperFilters 中没有 keyboard 过滤项: $($kbFilters -join ',')" }
$sys = "$env:SystemRoot\System32\drivers\keyboard.sys"
if (-not (Test-Path $sys)) { Fail "驱动文件不存在: $sys" }
Ok '校验通过: 服务/过滤器/驱动文件全部就位'
L "verify ok: filters=$($kbFilters -join ',')"

# 备份 UpperFilters 原始值 (供卸载/回滚)
$backup = Join-Path $app 'driver' ('upperfilters-backup-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$kbf = $kbFilters -join ','
$msf = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}').UpperFilters) -join ','
"keyboard=$kbf`nmouse=$msf" | Set-Content -LiteralPath $backup -Encoding UTF8
L "backup: $backup"

# ---- 5. 鼠标保护: 拆除鼠标侧过滤绑定 ----
$mouseCls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}'
if ($KeepMouseFilter) {
    Info '保留鼠标侧过滤绑定 (-KeepMouseFilter)'
} else {
    Info '拆除鼠标侧过滤绑定 (本工具只拦截键盘, 从机制上保证不碰任何鼠标)...'
    $cur = (Get-ItemProperty $mouseCls).UpperFilters
    $new = @($cur | Where-Object { $_ -ne 'mouse' })
    if ($new.Count -eq 0) { $new = @('mouclass') }
    Set-ItemProperty -Path $mouseCls -Name UpperFilters -Value $new -Type MultiString
    L "mouse filters: $($cur -join ',') -> $($new -join ',')"
    $txt = pnputil /enum-devices /class Mouse /connected | Out-String
    $ids = [regex]::Matches($txt, 'HID\\[^\r\n]+') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique
    foreach ($id in $ids) {
        $o = pnputil /restart-device "$id" 2>&1
        L "restart $id exit=$LASTEXITCODE"
    }
    Ok '鼠标侧绑定已拆除, 在线鼠标设备已重启 (执行中鼠标闪断 1-2 秒属正常)'
}

# ---- 6. 用户级组件 ----
Info '安装用户组件 (桌面快捷方式 + 开机自启)...'
$userInstall = Join-Path $dir 'install.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $userInstall
if ($LASTEXITCODE -ne 0) { Fail '用户组件安装失败' }
Ok '用户组件就绪'

Write-Host ''
Ok '安装完成! 请重启电脑让驱动挂载生效。'
Write-Host ''
Write-Host '重启后: 托盘出现键盘图标即工作; 按 Ctrl+Alt+K 切换内置键盘。' -ForegroundColor White
Write-Host '若托盘提示未识别, 稍等片刻看门狗会自动重试并弹出识别向导。' -ForegroundColor Gray
Write-Host ''
if (-not $YesToAll) { Read-Host '按回车关闭' }
