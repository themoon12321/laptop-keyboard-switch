# =====================================================================
#  鼠标侧过滤绑定管理 (排障工具; 正常安装请用根目录 setup.ps1, 会自动处理)
#    直接运行          -> 拆除鼠标侧过滤绑定 (interception 不再触碰鼠标栈)
#    -Revert           -> 从最近的 UpperFilters 备份恢复
#  需管理员。日志写到本目录。
# =====================================================================
param([switch]$Revert)
$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'mouse-filter.log'
function L([string]$s) { Add-Content -LiteralPath $log -Value ("[" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "] " + $s) -Encoding UTF8 }

$cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96f-e325-11ce-bfc1-08002be10318}'

if ($Revert) {
    L '--- REVERT from backup ---'
    $bk = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'upperfilters-backup-*.txt' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($bk) {
        $lines = Get-Content -LiteralPath $bk.FullName
        $mouseLine = $lines | Where-Object { $_ -like 'mouse=*' }
        if ($mouseLine) {
            $vals = @($mouseLine.Substring(6) -split ',' | Where-Object { $_ -ne '' })
            if ($vals.Count -gt 0) {
                Set-ItemProperty -Path $cls -Name UpperFilters -Value $vals -Type MultiString
                L ("restored from " + $bk.Name + " -> " + ($vals -join ','))
                Write-Host ("[OK] 已从备份恢复: " + ($vals -join ','))
            }
        }
    } else {
        Set-ItemProperty -Path $cls -Name UpperFilters -Value @('mouclass') -Type MultiString
        L 'no backup found, restored factory default mouclass'
        Write-Host '[OK] 无备份, 已恢复出厂默认 (mouclass)'
    }
} else {
    L '--- HARDEN: remove mouse filter from class binding ---'
    $cur = (Get-ItemProperty -Path $cls -Name UpperFilters -ErrorAction Stop).UpperFilters
    L ('before: ' + ($cur -join ','))
    $kbf = @((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96b-e325-11ce-bfc1-08002be10318}').UpperFilters) -join ','
    $backup = Join-Path $PSScriptRoot ('upperfilters-backup-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    "keyboard=$kbf`nmouse=$($cur -join ',')" | Set-Content -LiteralPath $backup -Encoding UTF8
    $new = @($cur | Where-Object { $_ -ne 'mouse' })
    if ($new.Count -eq 0) { $new = @('mouclass') }
    Set-ItemProperty -Path $cls -Name UpperFilters -Value $new -Type MultiString
    L ('after: ' + ((Get-ItemProperty -Path $cls -Name UpperFilters).UpperFilters -join ','))

    $txt = pnputil /enum-devices /class Mouse /connected | Out-String
    $ids = [regex]::Matches($txt, 'HID\\[^\r\n]+') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique
    foreach ($id in $ids) {
        $o = pnputil /restart-device "$id" 2>&1
        L ('restart ' + $id + ' exit=' + $LASTEXITCODE)
    }
    Write-Host '[OK] 鼠标侧绑定已拆除并重启鼠标设备'
}
