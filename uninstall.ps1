param([switch]$Purge)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\InstallState.psm1') -Force
$root=[IO.Path]::GetFullPath($PSScriptRoot)
$scriptPath=Join-Path $root 'app\KeyboardToggle.ahk'
$exeName=if ([Environment]::Is64BitOperatingSystem) {'AutoHotkey64.exe'} else {'AutoHotkey32.exe'}
$ahk=Join-Path $root ('app\AutoHotkey\'+$exeName)
$pattern='(?i)(?:^|[\s"])'+[regex]::Escape($scriptPath)+'(?=["\s]|$)'
$processes=@(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" | Where-Object {$_.CommandLine -match $pattern})
if ($processes.Count) {
    $release=Start-Process -FilePath $ahk -ArgumentList ('"{0}" release' -f $scriptPath) -PassThru -WindowStyle Hidden
    if (-not $release.WaitForExit(8000)) {Stop-Process -Id $release.Id -Force; throw '释放助手超时，停止卸载，请先紧急恢复键盘。'}
    $remaining=@(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" | Where-Object {$_.CommandLine -match $pattern})
    if ($remaining.Count) {throw '守护进程尚未退出，不继续删除。'}
}
$receipt=Join-Path (Get-KbStateDirectory $root -User) 'user.json'
if (Test-Path -LiteralPath $receipt) {
    $state=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-KbState $state $root
    if ($state.phase -ne 'removed') {
        $run=Read-KbRegistryValue $state.beforeRun.path $state.beforeRun.name
        if ($run.exists -and $run.value -eq $state.command) {Write-KbRegistryValue $state.beforeRun}
        elseif (-not (Test-KbRecordEqual $run $state.beforeRun)) {throw '自启项已被其他程序更改，不会覆盖；请核对。'}
        if (Test-Path -LiteralPath $state.link) {
            if (-not $state.afterLink -or (Get-FileHash -LiteralPath $state.link -Algorithm SHA256).Hash -ne $state.afterLink) {throw '快捷方式已被修改，保留它及备份，请核对。'}
            if ($null -ne $state.beforeLink) {[IO.File]::WriteAllBytes($state.link,[Convert]::FromBase64String($state.beforeLink))}
            else {Remove-Item -LiteralPath $state.link -Force}
        } elseif ($null -ne $state.beforeLink) {[IO.File]::WriteAllBytes($state.link,[Convert]::FromBase64String($state.beforeLink))}
        $state.phase='removed'; Write-KbJson $receipt $state
    }
} else {
    $run=Read-KbRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'LapKeySwitch'
    if ($run.exists -and $run.value -match $pattern) {Remove-ItemProperty -LiteralPath $run.path -Name $run.name}
    $link=Join-Path ([Environment]::GetFolderPath('Desktop')) '键盘开关.lnk'
    if (Test-Path -LiteralPath $link) {
        $ws=New-Object -ComObject WScript.Shell; $shortcut=$ws.CreateShortcut($link)
        if ($shortcut.TargetPath -eq $ahk -and $shortcut.Arguments -match $pattern) {Remove-Item -LiteralPath $link -Force}
    }
    Write-Warning '旧版无安装前备份，只清理已确认属于本项目的入口。'
}
if ($Purge) {
    foreach ($name in 'KeyboardToggle.ini','KeyGestures.ini','daemon.pid','KeyboardToggle.log','KeyboardToggle.log.old') {
        $path=Join-Path $root ('app\'+$name)
        if (Test-Path -LiteralPath $path) {Remove-Item -LiteralPath $path -Force}
    }
}
Write-Output '用户组件已卸载，驱动保留。完整卸载请运行 uninstall-all.cmd。'
