param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot))
if (-not $OutputDirectory) {$OutputDirectory=Join-Path $root 'dist'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$staging=Join-Path ([IO.Path]::GetTempPath()) ('kb-release-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    # Allowlist avoids local device IDs, live mappings, logs and repair experiments.
    $files=@('README.md','THIRD_PARTY.md','setup.cmd','setup.ps1','install.ps1','start.cmd',
        'diagnose.cmd','diagnose.ps1','uninstall.cmd','uninstall.ps1','uninstall-all.cmd','uninstall-all.ps1',
        'verify-uninstall.cmd','verify-uninstall.ps1','docs/INSTALL.md','docs/RECOVERY.md',
        'scripts/InstallState.psm1','scripts/MachineInstall.ps1',
        'app/KeyboardToggle.ahk','app/Defaults/KeyboardToggle.ini','app/Defaults/KeyGestures.ini',
        'app/AutoHotkey/AutoHotkey32.exe','app/AutoHotkey/AutoHotkey64.exe','app/AutoHotkey/license.txt',
        'app/Lib/AutoHotInterception.ahk','app/Lib/AutoHotInterception.dll','app/Lib/CLR.ahk',
        'app/Lib/GestureSettings.ahk','app/Lib/KbCore.ahk','app/Lib/KeyGestures.ahk',
        'app/Lib/KeyboardPicker.ahk',
        'app/Lib/AppTheme.ahk','app/Lib/MainPanel.ahk','app/Lib/ShortcutCapture.ahk','app/Lib/ShortcutSettings.ahk',
        'app/Lib/x64/interception.dll','app/Lib/x86/interception.dll','app/driver/install-interception.exe')
    $files+=@(Get-ChildItem -LiteralPath (Join-Path $root 'licenses') -File | ForEach-Object {'licenses/'+$_.Name})
    $manifest=@()
    foreach ($relative in $files) {
        $src=Join-Path $root $relative; $dest=Join-Path $staging $relative
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $dest
        $manifest+=[pscustomobject]@{file=$relative;sha256=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash}
    }
    [IO.File]::WriteAllText((Join-Path $staging 'SHA256SUMS.json'),($manifest | ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    $zip=Join-Path $output ('KeyboardToggle-'+(Get-Date -Format yyyyMMdd)+'.zip')
    if (Test-Path -LiteralPath $zip) {throw "分发包已存在，请更换输出目录：$zip"}
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip
    Write-Output $zip
    Get-FileHash -LiteralPath $zip -Algorithm SHA256
} finally {
    $resolved=[IO.Path]::GetFullPath($staging)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^kb-release-[a-f0-9]{32}$') {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
