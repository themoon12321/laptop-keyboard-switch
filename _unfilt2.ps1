# =====================================================================
#  决定性实验: 摘除 keyboard 过滤驱动 (可逆, 有备份)
#  目的: 在"无过滤驱动"状态下测试 2.4G 键盘主键区是否恢复
#  需管理员
# =====================================================================
$ErrorActionPreference = 'Continue'
$out = 'C:\Project\Other_Project\笔记本键盘开关\_unfilt2.txt'
function L($s) { Add-Content -LiteralPath $out -Value $s -Encoding UTF8 }
try { Remove-Item $out -ErrorAction SilentlyContinue } catch {}

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
    exit
}

L ('=== 摘除 keyboard 过滤驱动 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===')

$kbCls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}'
$kbBefore = @((Get-ItemProperty $kbCls -ErrorAction SilentlyContinue).UpperFilters) | Where-Object { $_ }
L ('  键盘 UpperFilters 原值: ' + ($kbBefore -join ','))

# 备份
$dir = 'C:\Project\Other_Project\笔记本键盘开关\app\driver'
$bk = Join-Path $dir ('upperfilters-backup-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$msBefore = @((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue).UpperFilters) | Where-Object { $_ }
"keyboard=$($kbBefore -join ',')`nmouse=$($msBefore -join ',')" | Set-Content -LiteralPath $bk -Encoding UTF8
L ('  已备份: ' + $bk.Name)

$kbAfter = @($kbBefore | Where-Object { $_ -ne 'keyboard' })
if ($kbAfter.Count -eq 0) { $kbAfter = @('kbdclass') }
Set-ItemProperty -Path $kbCls -Name UpperFilters -Value $kbAfter -Type MultiString
L ('  键盘 UpperFilters 新值: ' + ($kbAfter -join ','))

# 重启键盘设备
$txt = pnputil /enum-devices /class Keyboard /connected | Out-String
$ids = [regex]::Matches($txt, '(ACPI|HID|USB)\\[^\r\n]+') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique
foreach ($id in $ids) {
    $o = pnputil /restart-device "$id" 2>&1
    L ("  restart " + $id + " exit=" + $LASTEXITCODE)
}

Start-Sleep -Seconds 2
Get-PnpDevice -Class Keyboard -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object {
    L ("  [{0}] {1}" -f $_.Status, $_.InstanceId)
}
L '=== 完成: 过滤驱动已摘除, 请立即测试 2.4G 键盘打字 ==='
Write-Host 'DONE'
