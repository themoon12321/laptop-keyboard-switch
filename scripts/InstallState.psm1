Set-StrictMode -Version 2
$script:KbClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}'
$script:MouseClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}'

function Get-KbInstallId([string]$Root) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant())))).Replace('-', '').Substring(0, 16) }
    finally { $sha.Dispose() }
}
function Get-KbStateDirectory([string]$Root, [switch]$User) {
    $base = if ($User) { [Environment]::GetFolderPath('LocalApplicationData') } else { $env:ProgramData }
    return Join-Path $base ('LapKeySwitch\installs\' + (Get-KbInstallId $Root))
}
function Get-KbMachineId {
    return [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
}
function Write-KbJson([string]$Path, $Value) {
    $parent = Split-Path $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Read-KbRegistryValue([string]$Path, [string]$Name) {
    $key = $null
    try { $key = Get-Item -LiteralPath $Path -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { }
    if ($null -eq $key -or $key.GetValueNames() -notcontains $Name) {
        return [pscustomobject]@{ path=$Path; name=$Name; exists=$false; kind=''; value=$null }
    }
    return [pscustomobject]@{ path=$Path; name=$Name; exists=$true; kind=[string]$key.GetValueKind($Name); value=$key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
}
function Write-KbRegistryValue($Record) {
    if ($Record.exists) {
        if (-not (Test-Path -LiteralPath $Record.path)) { throw "Registry key disappeared: $($Record.path)" }
        New-ItemProperty -LiteralPath $Record.path -Name $Record.name -Value $Record.value -PropertyType $Record.kind -Force -ErrorAction Stop | Out-Null
    } else {
        $current = Read-KbRegistryValue $Record.path $Record.name
        if ($current.exists) { Remove-ItemProperty -LiteralPath $Record.path -Name $Record.name -ErrorAction Stop }
    }
}
function Test-KbRecordEqual($A, $B) {
    return ($A.exists -eq $B.exists -and $A.kind -eq $B.kind -and (ConvertTo-Json -InputObject $A.value -Compress) -ceq (ConvertTo-Json -InputObject $B.value -Compress))
}
# Restore only our delta. Concurrent additions to a MultiString (other drivers)
# survive; changed scalars are a conflict, never silently overwritten.
function Get-KbRestoreRecord($Before, $Installed, $Current) {
    if (Test-KbRecordEqual $Before $Installed) { return $null }
    if (Test-KbRecordEqual $Before $Current) { return $null }
    if (Test-KbRecordEqual $Installed $Current) { return $Before }
    if (($Before.kind -eq 'MultiString' -or -not $Before.exists) -and $Installed.kind -eq 'MultiString' -and ($Current.kind -eq 'MultiString' -or -not $Current.exists)) {
        $added = @($Installed.value | Where-Object { @($Before.value) -notcontains $_ })
        $removed = @($Before.value | Where-Object { $null -ne $_ -and @($Installed.value) -notcontains $_ })
        $merged = @($Current.value | Where-Object { $null -ne $_ -and $added -notcontains $_ })
        foreach ($item in $removed) { if ($merged -notcontains $item) { $merged += $item } }
        return [pscustomobject]@{ path=$Before.path; name=$Before.name; exists=($Before.exists -or $merged.Count -gt 0); kind='MultiString'; value=[string[]]$merged }
    }
    throw "Concurrent change, refusing to overwrite: $($Before.path) / $($Before.name)"
}
function Get-KbFilterSnapshot {
    $values = @((Read-KbRegistryValue $script:KbClass 'UpperFilters'), (Read-KbRegistryValue $script:MouseClass 'UpperFilters'))
    # Include disconnected devices as well; the official installer touches classes.
    foreach ($device in @(Get-PnpDevice -Class Keyboard -ErrorAction Stop)) {
        $values += Read-KbRegistryValue ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $device.InstanceId) 'UpperFilters'
    }
    return $values
}
function Set-KbFilter([string]$Path, [string[]]$Values) {
    Write-KbRegistryValue ([pscustomobject]@{path=$Path; name='UpperFilters'; exists=($Values.Count -gt 0); kind='MultiString'; value=$Values})
}
function Assert-KbState($State, [string]$Root) {
    if ($State.schema -ne 1 -or $State.machine -ne (Get-KbMachineId) -or $State.root -ne [IO.Path]::GetFullPath($Root)) { throw 'Installation receipt belongs to a different machine/path, or has an unsupported schema.' }
}
function Invoke-KbDriver([string]$Root, [ValidateSet('/install','/uninstall')][string]$Operation) {
    $exe = Join-Path $Root 'app\driver\install-interception.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Missing driver installer: $exe" }
    & $exe $Operation | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Driver installer $Operation failed: exit=$LASTEXITCODE. Receipt retained; reboot/retry if necessary." }
}
function Test-KbAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-KbArchitecture {
    if ($env:PROCESSOR_ARCHITEW6432) { return $env:PROCESSOR_ARCHITEW6432 }
    return $env:PROCESSOR_ARCHITECTURE
}
function Get-KbPreflight {
    $devices = @(Get-PnpDevice -Class Keyboard -PresentOnly -ErrorAction Stop | Select-Object Status,FriendlyName,InstanceId)
    $hvci = $false
    $v = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction SilentlyContinue
    if ($v -and $v.PSObject.Properties['Enabled'] -and $v.Enabled -eq 1) { $hvci = $true }
    try { if ((Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop).SecurityServicesRunning -contains 2) { $hvci = $true } } catch { }
    $services = @('keyboard','mouse' | ForEach-Object { Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $_) })
    return [pscustomobject]@{ architecture=(Get-KbArchitecture); hvci=$hvci; devices=$devices; existingDriver=($services -contains $true); completeDriver=($services -notcontains $false) }
}
Export-ModuleMember -Function *-Kb*
