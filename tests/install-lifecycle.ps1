# Execute the real machine installer against in-memory registry/driver doubles.
# Every system-facing call below is replaced; only a unique temp receipt is real.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'scripts\InstallState.psm1') -Force
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('kb-lifecycle-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$script:passed=0
$kb='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}'
$ms='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}'
$device='HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI\MOCK\1'
function Check($Condition,[string]$Label) {if (-not $Condition) {throw "FAIL $Label"}; $script:passed++; Write-Output "PASS $Label"}
function Get-KbMachineId {return 'MOCK-MACHINE'}
function Assert-KbState($State,$Root) {if ($State.machine -ne 'MOCK-MACHINE' -or $State.root -ne $Root -or $State.schema -ne 1) {throw 'Invalid mock receipt'}}
function Test-KbAdministrator {return $true}
function Get-KbStateDirectory {return (Join-Path $sandbox $script:scenario)}
function Get-KbPreflight {
    return [pscustomobject]@{architecture='AMD64';hvci=$script:hvci;existingDriver=$script:existing;completeDriver=$script:existing;devices=@([pscustomobject]@{Status='OK';InstanceId='ACPI\MOCK\1'})}
}
function Read-KbRegistryValue($Path,$Name) {
    if ($script:registry.ContainsKey($Path)) {return $script:registry[$Path]}
    return [pscustomobject]@{path=$Path;name=$Name;exists=$false;kind='';value=$null}
}
function Write-KbRegistryValue($Record) {$script:registry[$Record.path]=$Record}
function Get-KbFilterSnapshot {return @((@($script:registry.Keys)+@($kb,$ms,$device) | Select-Object -Unique) | ForEach-Object {Read-KbRegistryValue $_ 'UpperFilters'})}
function Set-KbFilter($Path,$Values) {Write-KbRegistryValue ([pscustomobject]@{path=$Path;name='UpperFilters';exists=($Values.Count -gt 0);kind='MultiString';value=$Values})}
function Invoke-KbDriver($Root,$Operation) {
    $script:driverCalls.Add($Operation)
    if ($Operation -eq '/install') {
        # The before-image must already be durable when the real EXE would run.
        $receipt=Join-Path (Get-KbStateDirectory) 'machine.json'
        if (-not (Test-Path -LiteralPath $receipt) -or (Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json).phase -ne 'prepared') {throw 'before-image not durable'}
        Set-KbFilter $kb @('keyboard','kbdclass','vendor')
        Set-KbFilter $ms @('mouse','mouclass')
        if ($script:failInstall) {throw 'MOCK install failed after partial changes'}
    }
}
function Test-Path {
    [CmdletBinding()]param([string]$LiteralPath,[string]$Path)
    $value=if ($LiteralPath) {$LiteralPath} else {$Path}
    if ($value -match '\\System32\\drivers\\(keyboard|mouse)\.sys$') {return $script:driverCalls.Contains('/install')}
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-ItemProperty {
    param([string]$LiteralPath)
    if ($LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\keyboard') {return [pscustomobject]@{Start=1}}
    throw "Unmocked registry read: $LiteralPath"
}
function sc.exe {$global:LASTEXITCODE=0}
function New-Scenario([string]$Name,[bool]$Existing=$false) {
    $script:scenario=$Name; $script:existing=$Existing; $script:hvci=$false; $script:failInstall=$false
    $script:driverCalls=New-Object 'Collections.Generic.List[string]'
    $script:registry=@{}
    Set-KbFilter $kb @('kbdclass','vendor'); Set-KbFilter $ms @('mouclass')
}
$source=Get-Content -LiteralPath (Join-Path $root 'scripts\MachineInstall.ps1') -Raw -Encoding UTF8
$source=$source -replace '(?m)^Import-Module .*\r?\n',''
$source=$source.Replace('$root=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot))', ('$root='''+$root.Replace("'","''")+''''))
$source=$source.Replace('exit 0','return').Replace('exit 1','throw "MOCK child failed"')
$installer=[scriptblock]::Create($source)
try {
    New-Scenario 'fresh'
    & $installer -Action Install | Out-Null
    $receipt=Join-Path (Get-KbStateDirectory) 'machine.json'
    $state=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($state.phase -eq 'installed' -and $state.ownsDriver) 'fresh install records ownership'
    Check (($script:registry[$kb].value -join ',') -eq 'kbdclass,vendor') 'class keyboard binding restored after official install'
    Check (($script:registry[$ms].value -join ',') -eq 'mouclass') 'mouse class unaffected after install'
    Check (($script:registry[$device].value -join ',') -eq 'keyboard') 'only selected PnP device receives filter'
    & $installer -Action Install | Out-Null
    Check ($script:driverCalls.Count -eq 1) 'repeat setup does not reinstall or overwrite baseline'
    Set-KbFilter $kb @('kbdclass','vendor','third-party')
    & $installer -Action Uninstall | Out-Null
    Check (-not $script:registry[$device].exists) 'uninstall removes only added device filter property'
    Check (($script:registry[$kb].value -join ',') -eq 'kbdclass,vendor,third-party') 'uninstall preserves later third-party filter'
    Check ($script:driverCalls.Count -eq 2 -and $script:driverCalls[1] -eq '/uninstall') 'owned driver is uninstalled'
    & $installer -Action Uninstall | Out-Null
    Check ($script:driverCalls.Count -eq 2) 'repeated uninstall is idempotent'

    New-Scenario 'shared' $true
    Set-KbFilter $device @('keyboard')
    & $installer -Action Install | Out-Null
    & $installer -Action Uninstall | Out-Null
    Check ($script:driverCalls.Count -eq 0 -and $script:registry[$device].exists) 'pre-existing driver and bindings survive full uninstall'

    New-Scenario 'failed'
    $script:failInstall=$true; $failed=$false
    try {& $installer -Action Install 2>$null | Out-Null} catch {$failed=$true}
    Check $failed 'partial installer failure propagates'
    $state=Get-Content -LiteralPath (Join-Path (Get-KbStateDirectory) 'machine.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($state.phase -eq 'failed' -and $state.before.Count -eq 3) 'partial failure retains original before-image'
    & $installer -Action Uninstall | Out-Null
    Check (($script:registry[$kb].value -join ',') -eq 'kbdclass,vendor' -and ($script:registry[$ms].value -join ',') -eq 'mouclass') 'partial install can restore original filters'

    New-Scenario 'hvci'
    $script:hvci=$true; $failed=$false
    try {& $installer -Action Install 2>$null | Out-Null} catch {$failed=$true}
    Check ($failed -and $script:driverCalls.Count -eq 0) 'HVCI stops before driver mutation'
    New-Scenario 'foreign-binding'
    & $installer -Action Install | Out-Null
    Set-KbFilter 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB\OTHER\1' @('keyboard')
    $failed=$false
    try {& $installer -Action Uninstall 2>$null | Out-Null} catch {$failed=$true}
    Check ($failed -and $script:driverCalls.Count -eq 1) 'unowned external binding blocks driver removal'
    & $installer -Action Uninstall -KeepDriver | Out-Null
    Check ($script:driverCalls.Count -eq 1) 'explicit KeepDriver preserves shared driver'
    Write-Output "TOTAL: $script:passed passed"
} finally {
    $resolved=[IO.Path]::GetFullPath($sandbox)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^kb-lifecycle-[a-f0-9]{32}$') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
