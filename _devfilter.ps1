# =====================================================================
#  设备级过滤实验: 把 interception 的 keyboard 过滤器从"整个键盘类"
#  改为"只挂在内置 PS/2 键盘 (ACPI\MSFT0001) 这一个设备上"
#  效果: USB/蓝牙键盘的设备栈里完全没有过滤驱动 (物理隔离, 永不失灵)
#  需管理员
# =====================================================================
$ErrorActionPreference = 'Continue'
$out = 'C:\Project\Other_Project\笔记本键盘开关\_devfilter.txt'
function L($s) { Add-Content -LiteralPath $out -Value $s -Encoding UTF8 }
try { Remove-Item $out -ErrorAction SilentlyContinue } catch {}

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    exit
}

L ('=== 设备级过滤实验 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===')

# 1. 确认类级是干净的 (只有 kbdclass)
$kbCls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}'
$classFilters = @((Get-ItemProperty $kbCls -ErrorAction SilentlyContinue).UpperFilters) | Where-Object { $_ }
L ('  类级 UpperFilters = ' + ($classFilters -join ','))
if ($classFilters -contains 'keyboard') {
    Set-ItemProperty -Path $kbCls -Name UpperFilters -Value @($classFilters | Where-Object { $_ -ne 'keyboard' }) -Type MultiString
    L '  [!] 类级还挂着 keyboard, 已移除'
}

# 2. 写设备级 UpperFilters 到内置键盘的 Enum 键
$devKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\MSFT0001\4&3155e47&0'
if (-not (Test-Path $devKey)) {
    L ('  [X] 找不到设备键: ' + $devKey)
    Write-Host 'FAIL'
    exit 1
}
try {
    Set-ItemProperty -Path $devKey -Name UpperFilters -Value @('keyboard') -Type MultiString -ErrorAction Stop
    L '  [OK] 已写入设备级 UpperFilters = keyboard'
} catch {
    L ('  [X] 写入失败(权限): ' + $_.Exception.Message)
    Write-Host 'FAIL-PERM'
    exit 1
}
$chk = (Get-ItemProperty $devKey).UpperFilters
L ('  复核: ' + ($chk -join ','))

# 3. 重启内置键盘设备使过滤挂载
$o = pnputil /restart-device 'ACPI\MSFT0001\4&3155e47&0' 2>&1
L ('  restart ACPI keyboard exit=' + $LASTEXITCODE)
L (($o | Out-String).Trim())

# 4. 状态
Get-PnpDevice -Class Keyboard -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object {
    L ('  [{0}] {1}' -f $_.Status, $_.InstanceId)
}
L '=== 完成: 若 restart 未生效(3010/50)需重启电脑一次 ==='
Write-Host 'DONE'
