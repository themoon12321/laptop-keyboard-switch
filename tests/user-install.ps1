# Real user install/uninstall control flow, but all registry, COM, process and
# profile paths are mocked. No live shortcut/autostart/input is touched.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
Import-Module (Join-Path $root 'scripts\InstallState.psm1') -Force
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('kb-user-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$script:passed=0
function Check($Condition,$Label) {if (-not $Condition) {throw "FAIL $Label"};$script:passed++;Write-Output "PASS $Label"}
function Get-KbStateDirectory {return (Join-Path $sandbox 'receipts')}
function Get-KbMachineId {return 'MOCK'}
function Assert-KbState($State,$Root) {if ($State.root -ne $Root -or $State.machine -ne 'MOCK') {throw 'Invalid mock state'}}
function Read-KbRegistryValue($Path,$Name) {return $script:run}
function Write-KbRegistryValue($Record) {$script:run=$Record}
function New-ItemProperty($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force) {$script:run=[pscustomobject]@{path=$LiteralPath;name=$Name;exists=$true;kind='String';value=$Value}}
function Get-CimInstance {return @()}
function Unblock-File {process {}}
function New-Object {
    param([Parameter(Position=0)][string]$TypeName,[Parameter(Position=1)][object[]]$ArgumentList,[string]$ComObject)
    if (-not $ComObject) {return (Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList)}
    if ($ComObject -ne 'WScript.Shell') {throw "Unexpected COM call $ComObject"}
    $shell=[pscustomobject]@{}
    $shell | Add-Member ScriptMethod CreateShortcut {
        param($Path)
        $shortcut=[pscustomobject]@{Path=$Path;TargetPath='';Arguments='';WorkingDirectory='';Description=''}
        $shortcut | Add-Member ScriptMethod Save {[IO.File]::WriteAllText($this.Path,($this.TargetPath+'|'+$this.Arguments))}
        return $shortcut
    }
    return $shell
}
function Load-TestScript($Name) {
    $text=Get-Content -LiteralPath (Join-Path $root $Name) -Raw -Encoding UTF8
    $text=$text -replace '(?m)^Import-Module .*\r?\n',''
    $literal="'"+$sandbox.Replace("'","''")+"'"
    $text=$text.Replace('$root=[IO.Path]::GetFullPath($PSScriptRoot)',('$root='+$literal))
    $text=$text.Replace("[Environment]::GetFolderPath('Desktop')",("'"+(Join-Path $sandbox 'desktop').Replace("'","''")+"'"))
    return [scriptblock]::Create($text)
}
try {
    foreach ($folder in 'desktop','app\AutoHotkey','app\Defaults') {New-Item -ItemType Directory -Path (Join-Path $sandbox $folder) -Force | Out-Null}
    foreach ($name in 'AutoHotkey64.exe','AutoHotkey32.exe') {[IO.File]::WriteAllText((Join-Path $sandbox ('app\AutoHotkey\'+$name)),'NOT EXECUTABLE')}
    [IO.File]::WriteAllText((Join-Path $sandbox 'app\KeyboardToggle.ahk'),'TEST')
    foreach ($name in 'KeyboardToggle.ini','KeyGestures.ini') {Copy-Item -LiteralPath (Join-Path $root ('app\Defaults\'+$name)) -Destination (Join-Path $sandbox ('app\Defaults\'+$name))}
    $link=Join-Path $sandbox 'desktop\键盘开关.lnk'
    [IO.File]::WriteAllText($link,'ORIGINAL SHORTCUT')
    $script:run=[pscustomobject]@{path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';name='LapKeySwitch';exists=$false;kind='';value=$null}
    $install=Load-TestScript 'install.ps1'; $uninstall=Load-TestScript 'uninstall.ps1'
    & $install | Out-Null
    Check (-not $script:run.exists) 'autostart disabled by default'
    Check ((Get-Content -LiteralPath (Join-Path $sandbox 'app\KeyGestures.ini') -Raw) -match 'enabled=0') 'new user gestures disabled'
    [IO.File]::WriteAllText((Join-Path $sandbox 'app\KeyGestures.ini'),'PERSONAL CONFIG')
    & $install -AutoStart | Out-Null
    Check ($script:run.exists) 'autostart opt-in writes owned command'
    Check ((Get-Content -LiteralPath (Join-Path $sandbox 'app\KeyGestures.ini') -Raw) -eq 'PERSONAL CONFIG') 'upgrade preserves personal mappings'
    $state=Get-Content -LiteralPath (Join-Path (Get-KbStateDirectory) 'user.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($state.beforeLink)) -eq 'ORIGINAL SHORTCUT') 'repeat install retains original shortcut backup'
    & $uninstall -Purge | Out-Null
    Check (-not $script:run.exists) 'uninstall removes owned autostart'
    Check ([IO.File]::ReadAllText($link) -eq 'ORIGINAL SHORTCUT') 'uninstall restores overwritten shortcut byte-for-byte'
    Check (-not (Test-Path -LiteralPath (Join-Path $sandbox 'app\KeyGestures.ini'))) 'purge removes live mappings'
    Check (Test-Path -LiteralPath (Join-Path $sandbox 'app\Defaults\KeyGestures.ini')) 'purge keeps distribution defaults'
    & $uninstall | Out-Null
    Check ([IO.File]::ReadAllText($link) -eq 'ORIGINAL SHORTCUT') 'repeated user uninstall is idempotent'
    & $install -AutoStart | Out-Null
    $script:run.value='OTHER TOOL'
    $failed=$false
    try {& $uninstall -Purge | Out-Null} catch {$failed=$true}
    Check ($failed -and $script:run.value -eq 'OTHER TOOL') 'concurrent autostart owner blocks overwrite'
    Check (Test-Path -LiteralPath (Join-Path $sandbox 'app\KeyGestures.ini')) 'conflict stops before purge'
    Write-Output "TOTAL: $script:passed passed"
} finally {
    $resolved=[IO.Path]::GetFullPath($sandbox)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^kb-user-[a-f0-9]{32}$') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
