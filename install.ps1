param([switch]$AutoStart)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\InstallState.psm1') -Force
$root=[IO.Path]::GetFullPath($PSScriptRoot)
$exeName=if ([Environment]::Is64BitOperatingSystem) {'AutoHotkey64.exe'} else {'AutoHotkey32.exe'}
$ahk=Join-Path $root ('app\AutoHotkey\'+$exeName)
$script=Join-Path $root 'app\KeyboardToggle.ahk'
if (-not (Test-Path -LiteralPath $ahk) -or -not (Test-Path -LiteralPath $script)) {throw '程序文件不完整。'}
$receipt=Join-Path (Get-KbStateDirectory $root -User) 'user.json'
$runPath='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$command='"{0}" "{1}"' -f $ahk,$script
$link=Join-Path ([Environment]::GetFolderPath('Desktop')) '键盘开关.lnk'
$state=$null
if (Test-Path -LiteralPath $receipt) {
    $state=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-KbState $state $root
    if ($state.phase -eq 'removed') {$state=$null}
}
if (-not $state) {
    $original=Read-KbRegistryValue $runPath 'LapKeySwitch'
    if ($original.exists -and $original.value -ne $command) {throw '其他副本占用了 LapKeySwitch 自启项，请先卸载该副本。'}
    $backup=if (Test-Path -LiteralPath $link) {[Convert]::ToBase64String([IO.File]::ReadAllBytes($link))} else {$null}
    $state=[pscustomobject]@{schema=1;root=$root;machine=(Get-KbMachineId);phase='prepared';beforeRun=$original;command=$command;link=$link;beforeLink=$backup;afterLink=$null}
    Write-KbJson $receipt $state
}
Get-ChildItem -LiteralPath (Join-Path $root 'app') -Recurse -File | Unblock-File
foreach ($name in 'KeyboardToggle.ini','KeyGestures.ini') {
    $destination=Join-Path $root ('app\'+$name)
    if (-not (Test-Path -LiteralPath $destination)) {Copy-Item -LiteralPath (Join-Path $root ('app\Defaults\'+$name)) -Destination $destination}
}
$ws=New-Object -ComObject WScript.Shell
$shortcut=$ws.CreateShortcut($link)
$shortcut.TargetPath=$ahk; $shortcut.Arguments=('"{0}" gui' -f $script)
$shortcut.WorkingDirectory=Join-Path $root 'app'
$shortcut.Description='内置键盘开关与坏键替代'; $shortcut.Save()
$state.afterLink=(Get-FileHash -LiteralPath $link -Algorithm SHA256).Hash
if ($AutoStart) {New-ItemProperty -LiteralPath $runPath -Name LapKeySwitch -Value $command -PropertyType String -Force | Out-Null}
$state.phase='installed'; Write-KbJson $receipt $state
Write-Output '用户组件安装完成，安装前入口已备份。自启默认关闭，已有配置保留。'
