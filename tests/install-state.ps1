# Pure restoration decisions and temp-file serialization. No registry writes,
# driver calls, shortcuts, elevation, Send, or live input hooks.
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'scripts\InstallState.psm1') -Force
$script:passed=0
function Check($Condition,[string]$Label) {
    if (-not $Condition) {throw "FAIL $Label"}
    $script:passed++; Write-Output "PASS $Label"
}
function Record($Value,[bool]$Exists=$true,[string]$Kind='MultiString') {
    return [pscustomobject]@{path='MOCK:\keyboard';name='UpperFilters';exists=$Exists;kind=$Kind;value=$Value}
}
$before=Record @('kbdclass','vendor')
$installed=Record @('keyboard','kbdclass','vendor')
$restored=Get-KbRestoreRecord $before $installed $installed
Check (Test-KbRecordEqual $restored $before) 'exact filter restoration preserves order'
$current=Record @('keyboard','kbdclass','vendor','third-party')
$restored=Get-KbRestoreRecord $before $installed $current
Check (($restored.value -join ',') -eq 'kbdclass,vendor,third-party') 'concurrent third-party addition survives uninstall'
$beforeMissing=Record $null $false ''
$installedDevice=Record @('keyboard')
$restored=Get-KbRestoreRecord $beforeMissing $installedDevice $installedDevice
Check (-not $restored.exists) 'absent device property is removed rather than replaced with empty value'
$restored=Get-KbRestoreRecord $beforeMissing $installedDevice (Record @('keyboard','other'))
Check ($restored.exists -and ($restored.value -join ',') -eq 'other') 'unowned device filter survives'
Check ($null -eq (Get-KbRestoreRecord $before $before $current)) 'reused driver has no restoration delta'
Check ($null -eq (Get-KbRestoreRecord $before $installed $before)) 'restoration is idempotent'
$removed=Record @('kbdclass')
$restored=Get-KbRestoreRecord $before $removed (Record @('kbdclass','other'))
Check (($restored.value -join ',') -eq 'kbdclass,other,vendor') 'removed original filter is restored without dropping later additions'
$conflict=$false
try {Get-KbRestoreRecord (Record 3 $true 'DWord') (Record 1 $true 'DWord') (Record 2 $true 'DWord') | Out-Null} catch {$conflict=$true}
Check $conflict 'concurrent scalar change blocks overwrite'
$roundTrip=Join-Path ([IO.Path]::GetTempPath()) ('kb-state-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    Write-KbJson $roundTrip ([pscustomobject]@{before=$before;phase='prepared';label='安装前'})
    $loaded=Get-Content -LiteralPath $roundTrip -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($loaded.phase -eq 'prepared' -and (Test-KbRecordEqual $loaded.before $before)) 'durable before-image round-trip'
    Write-KbJson $roundTrip ([pscustomobject]@{phase='installed'})
    Check ((Get-Content -LiteralPath $roundTrip -Raw | ConvertFrom-Json).phase -eq 'installed') 'atomic update replaces snapshot'
} finally {if (Test-Path -LiteralPath $roundTrip) {Remove-Item -LiteralPath $roundTrip -Force}}
Check ((Get-KbInstallId 'C:\Example\Keyboard') -eq (Get-KbInstallId 'c:\example\keyboard\')) 'install identity ignores path case and trailing slash'
Check ((Get-KbInstallId 'C:\Example\Keyboard') -ne (Get-KbInstallId 'C:\Other\Keyboard')) 'different copies have different receipts'
Write-Output "TOTAL: $script:passed passed"
