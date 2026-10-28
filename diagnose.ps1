# Read-only. Does not instantiate AHI, install a driver, or subscribe to input.
param([switch]$Json)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\InstallState.psm1') -Force
$report = Get-KbPreflight
if ($Json) { $report | ConvertTo-Json -Depth 6 } else {
    Write-Output ('Architecture: ' + $report.architecture + '; HVCI: ' + $report.hvci + '; existing Interception: ' + $report.existingDriver)
    $report.devices | Format-Table -AutoSize
    Write-Output '设备 ID 只用于本机安装。无法确定内置设备时请勿猜测；先断开外接键盘后对比设备列表。'
}
