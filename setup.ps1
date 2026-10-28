param([string[]]$DeviceId=@(), [switch]$SkipDriver, [switch]$AutoStart, [switch]$DryRun, [switch]$YesToAll)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\InstallState.psm1') -Force
try {
    & (Join-Path $PSScriptRoot 'diagnose.ps1')
    if ($DryRun) {Write-Output 'DryRun: 未修改驱动、注册表、自启或快捷方式。'; exit 0}
    $preflight=Get-KbPreflight
    if ($preflight.architecture -eq 'ARM64' -or $preflight.hvci) {throw '架构或 HVCI 配置不兼容，停止安装。'}
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'app') -Recurse -File | Unblock-File
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $args_=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $PSScriptRoot 'scripts\MachineInstall.ps1')),'-Action','Install','-ExpectedSid',$sid)
    if ($DeviceId.Count) {
        foreach ($id in $DeviceId) {if ($id -notmatch '^[A-Za-z0-9_\\&{}#.-]+$') {throw '设备 ID 格式非法。'}}
        $args_+=@('-DeviceIds',('"{0}"' -f ($DeviceId -join '|')))
    }
    if ($SkipDriver) {$args_+='-SkipDriver'}
    $options=@{FilePath='powershell.exe';ArgumentList=$args_;Wait=$true;PassThru=$true;WindowStyle='Hidden'}
    if (-not (Test-KbAdministrator)) {$options.Verb='RunAs'}
    $process=Start-Process @options
    if ($process.ExitCode -ne 0) {throw '机器安装未完成，详情见 ProgramData\LapKeySwitch\installs 下的 machine-error.txt。'}
    & (Join-Path $PSScriptRoot 'install.ps1') -AutoStart:$AutoStart
    Write-Output '安装完成。新驱动需重启，然后运行 start.cmd 并确认内置设备。自启默认关闭，没有自动屏蔽键盘。'
} catch {Write-Error $_ -ErrorAction Continue; exit 1}
