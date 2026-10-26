# =====================================================================
#  USB 省电策略修复 (针对扩展坞键鼠掉线/失灵)
#  1. 关闭所有 USB 集线器/控制器/HID 设备的"允许计算机关闭此设备以节约电源"
#  2. 关闭当前电源计划的 USB 选择性暂停
#  3. 保留可逆性: 只改电源管理开关, 不删驱动不改硬件配置
#  需管理员权限
# =====================================================================
$ErrorActionPreference = 'Continue'
$out = 'C:\Project\Other_Project\笔记本键盘开关\_usbfix.txt'
function L($s) { Add-Content -LiteralPath $out -Value $s -Encoding UTF8 }
try { Remove-Item $out -ErrorAction SilentlyContinue } catch {}

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    exit
}

L ('=== USB 省电修复 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===')

# ---- 1. 关闭各 USB/HID 设备的电源管理 ----
L ''
L '--- 1. 逐设备关闭 "允许计算机关闭此设备以节约电源" ---'
$targets = @(
    (Get-PnpDevice -Class USB -PresentOnly -ErrorAction SilentlyContinue),
    (Get-PnpDevice -Class HIDClass -PresentOnly -ErrorAction SilentlyContinue),
    (Get-PnpDevice -Class Keyboard -PresentOnly -ErrorAction SilentlyContinue),
    (Get-PnpDevice -Class Mouse -PresentOnly -ErrorAction SilentlyContinue)
) | ForEach-Object { $_ }
$targets = $targets | Where-Object { $_ -ne $null } | Sort-Object InstanceId -Unique

$changed = 0
foreach ($d in $targets) {
    $pm = Get-CimInstance -ClassName MSPower_DeviceEnable -Namespace root\wmi -ErrorAction SilentlyContinue |
          Where-Object { $_.InstanceName -like ($d.InstanceId + '*') }
    foreach ($item in $pm) {
        if ($item.Enable -eq $true) {
            try {
                $item.Enable = $false
                Set-CimInstance -InputObject $item -ErrorAction Stop
                $changed++
                L ("  [OK] 已关闭省电: " + $item.InstanceName)
            } catch {
                L ("  [!!] 关闭失败: " + $item.InstanceName + " : " + $_.Exception.Message)
            }
        }
    }
}
L ("  共修改 $changed 个设备")

# ---- 2. 关闭当前电源计划的 USB 选择性暂停 ----
L ''
L '--- 2. 关闭电源计划中的 USB 选择性暂停 ---'
$sub = '2a737441-1930-4402-8d77-b2bebba308a3'   # USB settings
$setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'  # USB selective suspend
$guid = ((powercfg /getactivescheme) -split '\s+')[3]
L ('  当前电源计划 GUID = ' + $guid)

# 交流 + 电池 都设为 0 (禁用)
foreach ($mode in 'ac','dc') {
    $r = & powercfg /setacvalueindex $guid $sub $setting 0 2>&1
    if ($mode -eq 'dc') { $r = & powercfg /setdcvalueindex $guid $sub $setting 0 2>&1 }
}
& powercfg /setactive $guid | Out-Null
$cur = & powercfg /query $guid $sub $setting 2>&1 | Out-String
L ('  powercfg 结果:')
foreach ($line in ($cur -split "`n")) {
    if ($line -match '当前|Current|索引|Index') { L ('    ' + $line.Trim()) }
}

# ---- 3. 关闭 "USB 集线器允许关闭" 的注册表策略 ----
L ''
L '--- 3. 检查 USB 集线器增强电源管理 ---'
$hubKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\USB'
if (Test-Path $hubKey) {
    $v = Get-ItemProperty $hubKey -Name DisableSelectiveSuspend -ErrorAction SilentlyContinue
    L ('  DisableSelectiveSuspend = ' + $v.DisableSelectiveSuspend)
} else {
    L '  (USB 服务注册表项不存在)'
}

L ''
L '=== 完成 ==='
Write-Host 'DONE'
