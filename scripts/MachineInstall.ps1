param([Parameter(Mandatory=$true)][ValidateSet('Install','Uninstall')][string]$Action,
    [string]$DeviceIds='', [switch]$SkipDriver, [switch]$KeepDriver, [string]$ExpectedSid)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'InstallState.psm1') -Force
$root=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot))
$stateDir=Get-KbStateDirectory $root
$receipt=Join-Path $stateDir 'machine.json'
$kbClass='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}'
$mouseClass='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}'
$maintenance=New-Object Threading.Mutex($false, 'Global\LapKeySwitch_DriverMaintenance')
$locked=$false
try {
    if (-not (Test-KbAdministrator)) {throw 'Administrator privileges required.'}
    if ($ExpectedSid -and $ExpectedSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {throw '请使用当前账户 UAC 提权，不支持另一管理员账户代为安装。'}
    try {$locked=$maintenance.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
    if (-not $locked) {throw '另一个安装/卸载正在操作驱动，请等待它完成。'}
    $state=$null
    if (Test-Path -LiteralPath $receipt) {
        $state=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-KbState $state $root
    }
    if ($Action -eq 'Install') {
        if ($state -and $state.phase -ne 'removed') {
            if ($state.phase -eq 'installed') {Write-Output '保留首次安装前的快照。'; exit 0}
            throw '上次安装未完成，先运行 uninstall-all.cmd 恢复。'
        }
        $preflight=Get-KbPreflight
        if ($preflight.architecture -eq 'ARM64' -or $preflight.hvci) {throw '架构或 HVCI 不兼容，不会关闭系统安全设置。'}
        if ($preflight.existingDriver -and -not $preflight.completeDriver) {throw '已有不完整的 Interception 服务，停止覆盖。'}
        if ($SkipDriver -and -not $preflight.completeDriver) {throw '-SkipDriver 要求已有完整驱动。'}
        $selected=@($DeviceIds -split '\|' | Where-Object {$_})
        if (-not $preflight.existingDriver) {
            foreach ($r in @(Get-KbFilterSnapshot)) {
                if (@($r.value) -contains 'keyboard' -or @($r.value) -contains 'mouse') {throw '存在无服务的过滤器残留，停止覆盖，请先诊断。'}
            }
            if (-not $selected.Count) {
                $acpi=@($preflight.devices | Where-Object {$_.InstanceId -match '^ACPI\\' -and $_.Status -eq 'OK'})
                if ($acpi.Count -ne 1) {throw '无法唯一确认内置设备，运行 diagnose.cmd 核对后使用 setup.ps1 -DeviceId 指定。'}
                $selected=@($acpi[0].InstanceId)
            }
            foreach ($id in $selected) {
                if (@($preflight.devices.InstanceId) -notcontains $id -or $id -match '^BTH' -or $id -notmatch '^[A-Za-z0-9_\\&{}#.-]+$') {throw "非当前键盘设备或 ID 非法: $id"}
            }
            foreach ($name in 'keyboard','mouse') {
                if (Test-Path -LiteralPath (Join-Path $env:SystemRoot ('System32\drivers\'+$name+'.sys'))) {throw '存在无服务的同名驱动文件，停止覆盖。'}
            }
        }
        $state=[pscustomobject]@{schema=1;root=$root;machine=(Get-KbMachineId);phase='prepared';created=(Get-Date -Format o);ownsDriver=(-not $preflight.existingDriver);selected=$selected;before=@(Get-KbFilterSnapshot);after=@()}
        # Persist the BEFORE-image before the official installer touches anything.
        Write-KbJson $receipt $state
        try {
            if ($state.ownsDriver) {
                Invoke-KbDriver $root '/install'
                foreach ($r in $state.before | Where-Object {$_.path -eq $kbClass -or $_.path -eq $mouseClass}) {Write-KbRegistryValue $r}
                foreach ($id in $selected) {
                    $path='HKLM:\SYSTEM\CurrentControlSet\Enum\'+$id
                    $current=Read-KbRegistryValue $path 'UpperFilters'
                    $filters=@($current.value | Where-Object {$_})
                    if ($filters -notcontains 'keyboard') {$filters+='keyboard'}
                    Set-KbFilter $path $filters
                }
                & sc.exe config keyboard start= system | Out-Host
                if ($LASTEXITCODE -ne 0) {throw '新建服务启动类型设置失败。'}
                $service=Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\keyboard'
                if ($service.Start -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\keyboard.sys'))) {throw '驱动校验失败。'}
            } else {Write-Output '复用已有驱动，不修改其服务、类过滤器和设备绑定。'}
            $state.after=@($state.before | ForEach-Object {Read-KbRegistryValue $_.path $_.name})
            $state.phase='installed'; Write-KbJson $receipt $state
        } catch {
            $state.after=@($state.before | ForEach-Object {Read-KbRegistryValue $_.path $_.name})
            $state.phase='failed'; Write-KbJson $receipt $state
            throw
        }
        exit 0
    }
    if (-not $state) {throw '没有安装前快照，不能承诺恢复初始状态，停止删除驱动。旧版迁移见 docs/INSTALL.md。'}
    if ($state.phase -eq 'removed') {Write-Output '驱动层已处理。'; exit 0}
    if (-not $state.ownsDriver -or $KeepDriver) {
        $state | Add-Member -NotePropertyName keptDriver -NotePropertyValue $true -Force
        $state.phase='removed'; Write-KbJson $receipt $state
        Write-Output '保留已有/共享驱动。'; exit 0
    }
    foreach ($file in Get-ChildItem -LiteralPath (Split-Path $stateDir) -Filter machine.json -Recurse -File) {
        if ($file.FullName -eq $receipt) {continue}
        $other=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($other.machine -eq $state.machine -and $other.phase -ne 'removed') {throw '其他副本仍在共享驱动，先卸载其他副本或使用 -KeepDriver。'}
    }
    $actions=@()
    foreach ($before in $state.before) {
        $after=@($state.after | Where-Object {$_.path -eq $before.path -and $_.name -eq $before.name})
        if (-not $after.Count) {
            # Interrupted before AFTER-image: only undo this known driver delta.
            $filterName=if ($before.path -eq $mouseClass) {'mouse'} else {'keyboard'}
            $after=@([pscustomobject]@{path=$before.path;name=$before.name;exists=$true;kind='MultiString';value=@(@($before.value | Where-Object {$_})+$filterName)})
        }
        $r=Get-KbRestoreRecord $before $after[0] (Read-KbRegistryValue $before.path $before.name)
        if ($null -ne $r) {$actions+=$r}
    }
    $all=@(Get-KbFilterSnapshot)
    foreach ($r in $all) {
        $planned=@($actions | Where-Object {$_.path -eq $r.path})
        $value=if ($planned.Count) {$planned[0].value} else {$r.value}
        if (@($value) -contains 'keyboard' -or @($value) -contains 'mouse') {throw '发现安装范围之外的驱动绑定，保留驱动；请诊断或使用 -KeepDriver。'}
    }
    foreach ($r in $actions) {Write-KbRegistryValue $r}
    $state.phase='removing'; Write-KbJson $receipt $state
    Invoke-KbDriver $root '/uninstall'
    # Preserve non-Interception third-party filters after the official tool runs.
    foreach ($r in $all | Where-Object {$_.path -eq $kbClass -or $_.path -eq $mouseClass}) {
        $planned=@($actions | Where-Object {$_.path -eq $r.path})
        if ($planned.Count) {Write-KbRegistryValue $planned[0]} else {Write-KbRegistryValue $r}
    }
    foreach ($r in $actions) {
        if (-not (Test-KbRecordEqual $r (Read-KbRegistryValue $r.path $r.name))) {throw '过滤器恢复校验失败，禁止删除安装目录。'}
    }
    $state | Add-Member -NotePropertyName keptDriver -NotePropertyValue $false -Force
    $state.phase='removed'; Write-KbJson $receipt $state
    Write-Output '卸载命令成功，必须重启并运行 verify-uninstall.cmd 验证。'
} catch {
    if (-not (Test-Path -LiteralPath $stateDir)) {New-Item -ItemType Directory -Path $stateDir -Force | Out-Null}
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $stateDir 'machine-error.txt') -Encoding UTF8
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($locked) {$maintenance.ReleaseMutex()}
    $maintenance.Dispose()
}
