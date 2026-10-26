# =====================================================================
#  用户级卸载: 快捷方式 + 自启 + 守护进程 (无需管理员, 键盘自动放行)
#  要连驱动一起卸载, 请运行 uninstall-all.ps1
# =====================================================================
$ErrorActionPreference = 'SilentlyContinue'

# Ask this installation to release first, then stop only its remaining processes.
$scriptPath = Join-Path $PSScriptRoot 'app\KeyboardToggle.ahk'
$exeName = if ([Environment]::Is64BitOperatingSystem) { 'AutoHotkey64.exe' } else { 'AutoHotkey32.exe' }
$ahkPath = Join-Path $PSScriptRoot ('app\AutoHotkey\' + $exeName)
if ((Test-Path -LiteralPath $scriptPath) -and (Test-Path -LiteralPath $ahkPath)) {
    & $ahkPath $scriptPath release | Out-Null
}
$scriptPattern = '(?i)(?:^|[\s"])' + [regex]::Escape($scriptPath) + '(?=["\s]|$)'
Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
    Where-Object { $_.CommandLine -match $scriptPattern } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'LapKeySwitch'

$desktop = [Environment]::GetFolderPath('Desktop')
'键盘开关.lnk',
'切换内置键盘.lnk', '只留外接键盘.lnk', '恢复内置键盘.lnk',
'键盘状态面板.lnk', '紧急恢复键盘.lnk',
'关闭内置键盘.lnk', '开启内置键盘.lnk' |
    ForEach-Object { Remove-Item -LiteralPath (Join-Path $desktop $_) -Force -ErrorAction SilentlyContinue }

Write-Host '[OK] 快捷方式与开机自启已移除; 守护进程已退出, 内置键盘自动放行'
Write-Host ''
Write-Host '驱动仍在系统里 (不影响日常使用, 键盘直通)。'
Write-Host '如需彻底卸载驱动恢复系统原状, 运行 uninstall-all.ps1 (会弹 UAC)。'
exit 0
