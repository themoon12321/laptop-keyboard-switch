# Unique sandbox, fake AHI, disabled system hotkeys/Send and hidden GUIs.
param([string]$PreviewDirectory='')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$srcApp = Join-Path $root 'app'
$work = Join-Path ([IO.Path]::GetTempPath()) ('kbtest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$daemon = $null
try {
    Copy-Item (Join-Path $srcApp '*') $work -Recurse -Force -Exclude daemon.pid,*.log,*.log.old
    Copy-Item (Join-Path $PSScriptRoot 'fake-Lib\AutoHotInterception.ahk') (Join-Path $work 'Lib\AutoHotInterception.ahk') -Force
    foreach ($relative in @('Lib\MainPanel.ahk','Lib\ShortcutSettings.ahk')) {
        $libPath=Join-Path $work $relative
        $libSource=Get-Content -LiteralPath $libPath -Raw -Encoding UTF8
        $libSource=$libSource -replace '(?<![A-Za-z0-9_])Hotkey\(', 'TestHotkey('
        $libSource=$libSource -replace '(?<![A-Za-z0-9_])GetKeyState\(', 'TestKeyState('
        $libSource=$libSource -replace '(?<![A-Za-z0-9_])WinActive\(', 'TestWinActive('
        $libSource=$libSource.Replace('g_gui.Show()', 'g_gui.Show("Hide AutoSize")')
        Set-Content -LiteralPath $libPath -Value $libSource -Encoding UTF8
    }
    $source = Get-Content -LiteralPath (Join-Path $work 'KeyboardToggle.ahk') -Raw -Encoding UTF8
    $source = '#Include ' + (Join-Path $PSScriptRoot 'fake-Lib\FakeInputHook.ahk') + "`n" + $source
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

TestHotkey(hk, callback := 0, options := "") {
    global g_failRegistration
    if (IsSet(g_failRegistration) && hk = g_failRegistration && options = "On")
        throw Error("simulated hotkey conflict")
    return ""
}
TestKeyState(*) {
    return false
}
TestWinActive(*) {
    global g_testFocus
    return IsSet(g_testFocus) ? g_testFocus : true
}
TestTrayTip(*) {
}
IntegrationCheck(condition, label) {
    FileAppend((condition ? "PASS " : "FAIL ") label "`n", A_ScriptDir "\integration-results.txt", "UTF-8")
}
IntegrationSelfTest() {
    global core, AHI, iniFile, g_desiredBlocked, g_gestureRules, g_gesturesEnabled, g_gui
    global g_hk, g_captureActive, g_captureCandidate, g_ctlHkPreview, g_ctlHkState, g_ctlHkHint, g_failRegistration, g_testFocus
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
        oldHK := g_hk
        SetBlocked(true, false)
        hook := FakeInputHook()
        BeginShortcutCapture(hook)
        IntegrationCheck(g_captureActive && core.mode = "pass" && g_desiredBlocked && InStr(g_ctlHkState.Text, "正在录制"), "recording state is visible and releases blocked internal input")
        hook.OnKeyDown.Call(hook, 0, 29)
        IntegrationCheck(InStr(g_ctlHkPreview.Text, "Ctrl"), "panel previews modifiers before main key")
        hook.OnKeyDown.Call(hook, 0, 42), hook.OnKeyDown.Call(hook, 0, 45)
        hook.OnKeyUp.Call(hook, 0, 45), hook.OnKeyUp.Call(hook, 0, 42), hook.OnKeyUp.Call(hook, 0, 29)
        IntegrationCheck(!g_captureActive && core.blocked && g_hk = oldHK && g_captureCandidate = "^+SC02D", "recorded chord waits for Save and restores previous blocking state")
        SaveCapturedShortcut()
        IntegrationCheck(g_hk = "^+SC02D" && IniRead(iniFile, "hotkey", "combo") = g_hk, "explicit Save registers and persists recorded shortcut")
        hook := FakeInputHook(), BeginShortcutCapture(hook)
        hook.OnKeyDown.Call(hook, 0, 1)
        IntegrationCheck(!g_captureActive && core.blocked && g_captureCandidate = "", "Escape cancels recording and restores blocking")
        stale := hook
        hook := FakeInputHook(), BeginShortcutCapture(hook)
        CaptureHookEnded(stale)
        IntegrationCheck(g_captureActive, "late end event from old recorder cannot cancel new recording")
        g_testFocus := false
        ShortcutCaptureTick()
        g_testFocus := true
        IntegrationCheck(!g_captureActive && core.blocked, "focus loss cancels recorder and restores previous input state")
        g_failRegistration := "^SC02E", g_captureCandidate := "^SC02E"
        SaveCapturedShortcut()
        IntegrationCheck(g_hk = "^+SC02D" && InStr(g_ctlHkHint.Text, "未保存"), "registration failure leaves current shortcut unchanged with inline error")
        g_failRegistration := ""
        CancelShortcutCapture()
        ApplyHotkey(oldHK)
        SetBlocked(false, false)
        g_gui.GetClientPos(, , &width, &height)
        fits := true
        for control in g_gui {
            control.GetPos(&cx, &cy, &cw, &ch)
            if (cx < 0 || cy < 0 || cx + cw > width || cy + ch > height)
                fits := false
        }
        IntegrationCheck(fits, "all main panel controls stay inside client bounds")
        ; PREVIEW_INSERT
        g_gui.Hide()
        FileAppend("DONE`n", A_ScriptDir "\integration-results.txt", "UTF-8")
    } catch as err {
        FileAppend("FAIL exception: " err.Message " at line " err.Line "`nDONE`n", A_ScriptDir "\integration-results.txt", "UTF-8")
    }
}
'@
    if ($PreviewDirectory) {
        $PreviewDirectory=[IO.Path]::GetFullPath($PreviewDirectory)
        New-Item -ItemType Directory -Path $PreviewDirectory -Force | Out-Null
        $preview=$PreviewDirectory.Replace('`','``').Replace('"','`"')
        $render=@'
        CaptureTestWindow(g_gui, "PREVIEW_PATH\main.bmp")
        BeginShortcutCapture(FakeInputHook())
        CaptureShortcutKey(29, 1), CaptureShortcutKey(42, 1), CaptureShortcutKey(45, 1)
        CaptureTestWindow(g_gui, "PREVIEW_PATH\recording.bmp")
        CancelShortcutCapture()
        settingsPreview := GestureSettingsWindow(GestureSettings.Defaults(), true, (*) => false)
        settingsPreview.window.Show("Hide AutoSize")
        settingsPreview.delay.Value := "450", settingsPreview.Changed()
        CaptureTestWindow(settingsPreview.window, "PREVIEW_PATH\settings.bmp")
        keyPreview := KeyboardPicker(settingsPreview.window, "target", GetKeySC("z"), (*) => 0)
        keyPreview.window.Show("Hide AutoSize")
        CaptureTestWindow(keyPreview.window, "PREVIEW_PATH\keyboard-picker.bmp")
        keyPreview.Close()
        settingsPreview.window.Destroy()
'@
        $testFunctions=$testFunctions.Replace('; PREVIEW_INSERT',$render.Replace('PREVIEW_PATH',$preview))
        $source += "`n#Include " + (Join-Path $PSScriptRoot 'window-capture.ahk') + "`n"
    }
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
