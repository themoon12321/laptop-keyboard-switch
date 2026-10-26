# =====================================================================
#  用户级安装: 桌面快捷方式 + 开机自启 (无需管理员)
#  通常无需单独运行 —— setup.ps1 会自动调用本文件
# =====================================================================
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

# 按系统位数选择解释器
$exe = if ([Environment]::Is64BitOperatingSystem) { 'AutoHotkey64.exe' } else { 'AutoHotkey32.exe' }
$ahk       = Join-Path $dir "app\AutoHotkey\$exe"
$ahkScript = Join-Path $dir 'app\KeyboardToggle.ahk'
if ((-not (Test-Path $ahk)) -or (-not (Test-Path $ahkScript))) { throw "app 目录不完整 (缺 $ahk 或 KeyboardToggle.ahk)" }

# 解除网络锁定 (整个包经压缩包分发时可能带上)
Get-ChildItem -LiteralPath (Join-Path $dir 'app') -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ini 跨机器清理: 句柄缓存与开关状态只对写入它的那台机器有效
$ini = Join-Path $dir 'app\KeyboardToggle.ini'
if (Test-Path $ini) {
    $machine = ''
    try { $machine = (Get-ItemProperty $ini -ErrorAction Stop).machine } catch {
        # PS 5.1 没有 BOM 的 UTF-16/UTF-8 ini 解析不稳定, 用 IniRead 语义兜底
    }
    $envName = $env:COMPUTERNAME
    $iniMachine = ''
    try {
        $native = Add-Type -MemberDefinition '[DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern int GetPrivateProfileString(string s, string k, string d, System.Text.StringBuilder v, int size, string file);' -Name INI -Namespace Win32 -PassThru
        $sb = New-Object System.Text.StringBuilder 512
        [void]$native::GetPrivateProfileString('device', 'machine', '', $sb, 512, $ini)
        $iniMachine = $sb.ToString()
    } catch { }
    if ($iniMachine -ne '' -and $iniMachine -ne $envName) {
        # 换机器了: 清掉旧机缓存与状态, 新机首启重新识别
        ' ' | Set-Content $ini -Encoding Unicode
        Write-Host "[OK] 检测到 ini 来自其他机器 ($iniMachine), 已重置缓存"
    }
}

$desktop = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell

function New-KbShortcut([string]$name, [string]$arg, [string]$icon, [string]$hotkey) {
    $lnk = $ws.CreateShortcut((Join-Path $desktop $name))
    $lnk.TargetPath   = $ahk
    $lnk.Arguments    = ('"{0}" {1}' -f $ahkScript, $arg)
    $lnk.IconLocation = $icon
    $lnk.Description   = '笔记本内置键盘热开关'
    if ($hotkey) { $lnk.Hotkey = $hotkey }
    $lnk.Save()
}

# 桌面只保留一个入口: 打开软件面板 (切换用脚本全局热键 Ctrl+Alt+K, 不依赖快捷方式)
New-KbShortcut '键盘开关.lnk' 'gui' "$env:SystemRoot\System32\setupapi.dll,2" ''

# 清理历史遗留快捷方式 (旧版本创建过的)
'关闭内置键盘.lnk', '开启内置键盘.lnk', '只留外接键盘.lnk', '恢复内置键盘.lnk',
'键盘状态面板.lnk', '紧急恢复键盘.lnk', '切换内置键盘.lnk' | ForEach-Object {
    Remove-Item -LiteralPath (Join-Path $desktop $_) -Force -ErrorAction SilentlyContinue
}

# 开机自启 (当前用户): 直接用 AHK 启动, 由脚本自身保证单实例
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'LapKeySwitch' -Value ('"{0}" "{1}"' -f $ahk, $ahkScript)

Write-Host '[OK] 桌面快捷方式: 仅「键盘开关」(打开状态面板)'
Write-Host '[OK] 切换快捷键 Ctrl+Alt+K (全局生效, 无需快捷方式)'
Write-Host '[OK] 开机自启已设置 (托盘菜单可关闭)'
exit 0
