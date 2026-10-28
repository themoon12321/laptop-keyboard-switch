# Unique sandbox, fake AHI, disabled system hotkeys/Send and hidden GUIs.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$srcApp = Join-Path $root 'app'
$work = Join-Path ([IO.Path]::GetTempPath()) ('kbtest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$daemon = $null
try {
    Copy-Item (Join-Path $srcApp '*') $work -Recurse -Force -Exclude daemon.pid,*.log,*.log.old
    Copy-Item (Join-Path $PSScriptRoot 'fake-Lib\AutoHotInterception.ahk') (Join-Path $work 'Lib\AutoHotInterception.ahk') -Force
    $source = Get-Content -LiteralPath (Join-Path $work 'KeyboardToggle.ahk') -Raw -Encoding UTF8
    $source = $source -replace '(?<![A-Za-z0-9_])Hotkey\(', 'TestHotkey('
    $source = $source -replace '(?ms)^ReleaseModifiers\(\) \{.*?^\}', "ReleaseModifiers() {`n}"
    $source = $source -replace '(?ms)^SyncShortcutHotkey\(\) \{.*?^\}', "SyncShortcutHotkey() {`n}"
    $source = $source -replace '(?<![A-Za-z0-9_])TrayTip\(', 'TestTrayTip('
    $source = $source.Replace('g_gui.Show()', 'g_gui.Show("Hide AutoSize")')
    $source = $source.Replace('g_scanGui.Show()', 'g_scanGui.Show("Hide AutoSize")')
    $source = $source.Replace('a1 = "reidentify" || a1 = "gui")', 'a1 = "reidentify" || a1 = "gui" || a1 = "selftest")')
    $source = $source.Replace('"gui", CMD_GUI)', '"gui", CMD_GUI, "selftest", 100)')
    $source = $source.Replace('case CMD_PANIC:   EmergencyRelease()', "case 100: IntegrationSelfTest()`n        case CMD_PANIC:   EmergencyRelease()")
    $testFunctions = @'

TestHotkey(*) {
    return ""
}
TestTrayTip(*) {
}
IntegrationCheck(condition, label) {
    FileAppend((condition ? "PASS " : "FAIL ") label "`n", A_ScriptDir "\integration-results.txt", "UTF-8")
}
IntegrationSelfTest() {
    global core, AHI, iniFile, g_desiredBlocked, g_gestureRules, g_gesturesEnabled, g_gui
    try {
        savedCache := CachedHandles()
        IniWrite("", iniFile, "device", "handles")
        core.Reset()
        IntegrationCheck(!IdentifyFlow(true) && core.ids.Length = 0 && AHI._subs.Count = 0,
            "fresh machine cannot silently select heuristic keyboard")
        IniWrite(JoinArr(savedCache, ","), iniFile, "device", "handles")
        IdentifyFlow(true)
        SetBlocked(true, false)
        device := AHI._devs[1]
        AHI._devs.Delete(1)
        AHI._devs[4] := device
        OnTick()
        IntegrationCheck(core.blocked && core.ids[1] = 4 && IniRead(iniFile, "state", "blocked") = "1", "device renumber preserves blocked intent")
        AHI._devs[4].Handle := "USB\replacement"
        OnTick()
        IntegrationCheck(!core.blocked && g_desiredBlocked && core.ids.Length = 0, "missing internal releases without erasing intent")
        AHI._devs[4].Handle := "ACPI\VEN_MSFT&DEV_0001"
        loop 5
            OnTick()
        IntegrationCheck(core.blocked && core.ids[1] = 4, "returning internal reapplies intended block")
        SetBlocked(false, false)
        ApplyGestureSettings(GestureSettings.Defaults(), true)
        IntegrationCheck(core.mode = "remap" && core.subs.Count = 1 && core.subs.Has(4) && !AHI._subs.Has(2), "gestures subscribe internal only")
        AHI._sent := []
        core.gestures.clock := () => 1000
        AHI._subs[4].Call(45, 1)
        core.gestures.clock := () => 1600
        core.TickGestures()
        AHI._subs[4].Call(45, 0)
        IntegrationCheck(AHI._sent.Length = 2 && AHI._sent[1] = "4:44:1" && AHI._sent[2] = "4:44:0", "long X emits Z through core callback")
        SetBlocked(true, false)
        AHI._sent := []
        AHI._subs[4].Call(45, 1)
        AHI._subs[4].Call(45, 0)
        core.TickGestures()
        IntegrationCheck(AHI._sent.Length = 0, "block pauses gestures")
        SetBlocked(false, false)
        ScanKeysFlow()
        IntegrationCheck(core.mode = "observe", "scan temporarily suspends gesture delay")
        EndScan()
        IntegrationCheck(core.mode = "remap", "scan cancellation restores gestures")
        ApplyGestureSettings(GestureSettings.Defaults(), false)
        IntegrationCheck(core.mode = "pass" && core.subs.Count = 0 && AHI._subs.Count = 0, "disable gestures removes all subscriptions")
        ShowGui()
        g_gui.GetClientPos(, , &width, &height)
        fits := true
        for control in g_gui {
            control.GetPos(&cx, &cy, &cw, &ch)
            if (cx < 0 || cy < 0 || cx + cw > width || cy + ch > height)
                fits := false
        }
        IntegrationCheck(fits, "all main panel controls stay inside client bounds")
        g_gui.Hide()
        FileAppend("DONE`n", A_ScriptDir "\integration-results.txt", "UTF-8")
    } catch as err {
        FileAppend("FAIL exception: " err.Message " at line " err.Line "`nDONE`n", A_ScriptDir "\integration-results.txt", "UTF-8")
    }
}
'@
    $source += $testFunctions
    $script = Join-Path $work 'KbTest.ahk'
    Set-Content -LiteralPath $script -Value $source -Encoding UTF8
    '[gestures]' + "`nenabled=0`ncount=0" | Set-Content -LiteralPath (Join-Path $work 'KeyGestures.ini') -Encoding Unicode
    '[device]' + "`nmachine=$env:COMPUTERNAME`nhandles=ACPI\VEN_MSFT&DEV_0001`n[state]`nblocked=1" | Set-Content -LiteralPath (Join-Path $work 'KeyboardToggle.ini') -Encoding Unicode
    $ahkExe = Join-Path $work 'AutoHotkey\AutoHotkey64.exe'
    $stdout = Join-Path $work 'stdout.txt'
    $stderr = Join-Path $work 'stderr.txt'
    & $ahkExe /ErrorStdOut $script status | Out-Null
    if (Test-Path (Join-Path $work 'daemon.pid')) { throw 'status started a daemon' }
    $daemon = Start-Process -FilePath $ahkExe -ArgumentList ('/ErrorStdOut "{0}" toggle --daemon' -f $script) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Start-Sleep -Seconds 3
    if ($daemon.HasExited) { throw ('Daemon exited: ' + (Get-Content $stdout -Raw)) }
    if ((Get-Content (Join-Path $work 'KeyboardToggle.ini') -Raw) -notmatch 'blocked=0') { throw 'Cold toggle did not invert persisted state' }
    Write-Output 'PASS read-only status and cold toggle'
    function Send-KbCli([string]$command) {
        & $ahkExe /ErrorStdOut $script $command | Out-Null
        Start-Sleep -Milliseconds 800
    }
    Send-KbCli 'off'
    Send-KbCli 'on'
    $duplicate = Start-Process -FilePath $ahkExe -ArgumentList ('/ErrorStdOut "{0}"' -f $script) -PassThru -WindowStyle Hidden
    if (-not $duplicate.WaitForExit(5000)) { Stop-Process -Id $duplicate.Id -Force; throw 'Duplicate daemon did not exit' }
    if ($daemon.HasExited) { throw 'Duplicate start killed original daemon' }
    Send-KbCli 'selftest'
    $results = Join-Path $work 'integration-results.txt'
    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $results) -and (Get-Content $results -Raw) -match 'DONE') { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-Path $results)) { throw ('Selftest did not run: ' + (Get-Content $stdout -Raw)) }
    $text = Get-Content $results -Raw -Encoding UTF8
    Write-Output $text
    if ($text -notmatch 'DONE' -or $text -match '(?m)^FAIL') { throw 'Integration assertions failed' }
    $logText = Get-Content (Join-Path $work 'KeyboardToggle.log') -Raw -Encoding UTF8
    if ($logText -notmatch 'state -> blocked subs=1' -or $logText -notmatch 'state -> allowed subs=0') { throw 'CLI off/on forwarding failed' }
    $console = Get-Content $stdout -Raw -ErrorAction SilentlyContinue
    if ($console -match '==>') { throw ('AHK warning/error: ' + $console) }
    Write-Output 'PASS CLI forwarding and mutex single instance'
    Write-Output 'PASS integration: all assertions; real input untouched'
} finally {
    Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($work) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $resolvedWork = [IO.Path]::GetFullPath($work)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedWork.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolvedWork -Leaf) -match '^kbtest-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvedWork -Recurse -Force -ErrorAction SilentlyContinue
    }
}
