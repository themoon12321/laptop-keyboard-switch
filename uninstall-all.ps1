param([switch]$KeepDriver, [switch]$Purge)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'scripts\InstallState.psm1') -Force
try {
    & (Join-Path $PSScriptRoot 'uninstall.ps1') -Purge:$Purge
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $args_=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $PSScriptRoot 'scripts\MachineInstall.ps1')),'-Action','Uninstall','-ExpectedSid',$sid)
    if ($KeepDriver) {$args_+='-KeepDriver'}
    $options=@{FilePath='powershell.exe';ArgumentList=$args_;Wait=$true;PassThru=$true;WindowStyle='Hidden'}
    if (-not (Test-KbAdministrator)) {$options.Verb='RunAs'}
    $process=Start-Process @options
    if ($process.ExitCode -ne 0) {throw '驱动恢复未完成，保留目录和记录，详情见 machine-error.txt。'}
    Write-Output '卸载步骤完成。重启后运行 verify-uninstall.cmd，通过后再删除项目文件夹。'
} catch {Write-Error $_ -ErrorAction Continue; exit 1}
