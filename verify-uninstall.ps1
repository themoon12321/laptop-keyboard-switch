param([switch]$PurgeReceipts)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\InstallState.psm1') -Force
$root=[IO.Path]::GetFullPath($PSScriptRoot)
$machineFile=Join-Path (Get-KbStateDirectory $root) 'machine.json'
$userFile=Join-Path (Get-KbStateDirectory $root -User) 'user.json'
if (-not (Test-Path -LiteralPath $machineFile)) {throw '缺少机器层安装记录，无法验证完整恢复。'}
$machine=Get-Content -LiteralPath $machineFile -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-KbState $machine $root
if ($machine.phase -ne 'removed') {throw '驱动卸载步骤尚未完成。'}
if ($machine.ownsDriver -and -not $machine.keptDriver) {
    foreach ($name in 'keyboard','mouse') {
        if ((Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$name)) -or (Test-Path -LiteralPath (Join-Path $env:SystemRoot ('System32\drivers\'+$name+'.sys')))) {throw '驱动仍存在，请先重启；重启后仍存在则保留记录排查。'}
    }
    foreach ($r in @(Get-KbFilterSnapshot)) {
        if (@($r.value) -contains 'keyboard' -or @($r.value) -contains 'mouse') {throw '存在驱动绑定残留。'}
    }
}
if (Test-Path -LiteralPath $userFile) {
    $user=Get-Content -LiteralPath $userFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-KbState $user $root
    if ($user.phase -ne 'removed') {throw '用户组件未卸载。'}
    if (-not (Test-KbRecordEqual $user.beforeRun (Read-KbRegistryValue $user.beforeRun.path $user.beforeRun.name))) {throw '自启项与安装前不同，请核对。'}
    if ($null -ne $user.beforeLink) {
        if (-not (Test-Path -LiteralPath $user.link) -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($user.link)) -ne $user.beforeLink) {throw '原始快捷方式未恢复。'}
    } elseif (Test-Path -LiteralPath $user.link) {throw '快捷方式尚有残留，请核对。'}
}
$scriptPath=Join-Path $root 'app\KeyboardToggle.ahk'
$pattern='(?i)(?:^|[\s"])'+[regex]::Escape($scriptPath)+'(?=["\s]|$)'
if (@(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" | Where-Object {$_.CommandLine -match $pattern}).Count) {throw '守护仍在运行。'}
if ($PurgeReceipts) {
    if (-not (Test-KbAdministrator)) {throw '-PurgeReceipts 需当前账户提权，请使用管理员 PowerShell。'}
    foreach ($file in @($machineFile,$userFile,(Join-Path (Split-Path $machineFile) 'machine-error.txt'))) {
        if (Test-Path -LiteralPath $file) {Remove-Item -LiteralPath $file -Force}
    }
    # Remove only empty receipt directories. Never recursively delete ProgramData.
    foreach ($dir in @((Split-Path $machineFile),(Split-Path $userFile))) {
        if ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) {[IO.Directory]::Delete($dir)}
    }
    foreach ($base in @($env:ProgramData,[Environment]::GetFolderPath('LocalApplicationData'))) {
        foreach ($relative in @('LapKeySwitch\installs','LapKeySwitch')) {
            $dir=Join-Path $base $relative
            if ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) {[IO.Directory]::Delete($dir)}
        }
    }
}
Write-Output 'PASS: 本项目进程、入口及拥有的驱动已清理；共享驱动按记录保留。可删除项目文件夹。'
