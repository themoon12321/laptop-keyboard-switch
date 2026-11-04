; =====================================================================
;  笔记本内置键盘 热开关 + 内置键盘坏键替代
;
;  核心引擎见 lib\KbCore.ahk (整设备订阅 + 豁免重注入 + 幽灵键修复)
;  本文件负责: 单实例、识别 UI、托盘/面板、快捷键、看门狗、应急释放
;
;  用法:
;    直接运行                        -> 守护进程 (托盘)
;    KeyboardToggle.ahk off|on|toggle|status|gui|reidentify
;    KeyboardToggle.ahk release      -> 应急: 强杀守护进程 + 放行全部键盘
;    KeyboardToggle.ahk identify     -> 仅识别并显示结果
;
;  安全设计:
;    - 退出/应急 都会: SetState(false) + 退订 + 补发修饰键抬起
;    - 命名互斥锁防重复启动，PID 只用于命令转发并核实所属脚本
;    - 设备身份(编号+句柄)订阅前核验, 不符绝不订阅
; =====================================================================
#Requires AutoHotkey v2.0
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
#SingleInstance Off
Persistent
#include Lib\AutoHotInterception.ahk
#include lib\KbCore.ahk
#include Lib\AppTheme.ahk
#include Lib\GestureSettings.ahk
#include Lib\ShortcutCapture.ahk
#include Lib\ShortcutSettings.ahk
#include Lib\MainPanel.ahk

global WM_APP_CMD   := 0x8000
global CMD_TOGGLE   := 1
global CMD_OFF      := 2
global CMD_ON       := 3
global CMD_STATUS   := 4
global CMD_REID     := 5
global CMD_GUI      := 6
global CMD_PANIC    := 7
global iniFile      := A_ScriptDir "\KeyboardToggle.ini"
global logFile      := A_ScriptDir "\KeyboardToggle.log"

global AHI          := 0
global core         := 0
global g_hk         := "^!k"
global g_hkObj      := 0
global g_gui        := 0
global g_ctlStatus  := 0
global g_ctlHk      := 0
global g_ctlExempt  := 0
global g_ctlAuto    := 0
global g_ctlGestures := 0
global g_scanGui    := 0
global g_scanLb     := 0
global g_scanMap    := Map()
global g_scanOrder  := []
global g_scanDirty  := 0
global g_watchFails := 0
global g_lastInteractive := 0
global g_tick := 0
global g_exiting := false
global g_ready := false
global g_desiredBlocked := false
global gestureFile := A_ScriptDir "\KeyGestures.ini"
global g_gestureRules := []
global g_gesturesEnabled := false
global g_settingsWindow := 0
global g_instanceMutex := 0
global g_captureActive := false, g_captureHook := 0, g_captureState := 0, g_captureCandidate := "", g_captureUntil := 0
global g_ctlStatusHint := 0, g_ctlToggle := 0, g_ctlHkState := 0, g_ctlHkPreview := 0, g_ctlHkHint := 0
global g_btnHkRecord := 0, g_btnHkSave := 0, g_btnHkCancel := 0

; A fresh clone has no machine cache or personal mappings. Preserve all existing
; local files on upgrades; safe defaults are copied only when missing.
for configName in ["KeyboardToggle.ini", "KeyGestures.ini"] {
    configPath := A_ScriptDir "\" configName
    if !FileExist(configPath)
        FileCopy(A_ScriptDir "\Defaults\" configName, configPath)
}

AcquireDaemonLock() {
    global g_instanceMutex
    pathHash := 2166136261
    loop parse StrLower(A_ScriptFullPath)
        pathHash := ((pathHash ^ Ord(A_LoopField)) * 16777619) & 0xFFFFFFFF
    name := "Local\LapKeySwitch_" Format("{:08X}", pathHash)
    g_instanceMutex := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "Str", name, "Ptr")
    return g_instanceMutex && A_LastError != 183
}

IsOurCommandLine(command) {
    escaped := RegExReplace(A_ScriptFullPath, "([\\.*+?{}\[\]()|^$])", "\$1")
    return RegExMatch(command, 'i)(?:^|[\s"])' escaped '(?=["\s]|$)') != 0
}

RotateLog() {
    global logFile
    try {
        if (FileExist(logFile) && FileGetSize(logFile) > 1048576)
            FileMove(logFile, logFile ".old", 1)
    }
}

LogMsg(s) {
    global logFile
    try FileAppend("[" FormatTime(, "yyyy-MM-dd HH:mm:ss") "] " s "`n", logFile, "UTF-8")
}

; ---------------- 单实例 / 清理旧守护 (PID 文件定位, 不依赖窗口标题) ----------------
global pidFile := A_ScriptDir "\daemon.pid"

ReadDaemonPid() {
    global pidFile
    try {
        pid := Integer(Trim(FileRead(pidFile)))
        if (pid > 0 && ProcessExist(pid)) {
            wmi := ComObject("WbemScripting.SWbemLocator").ConnectServer()
            for process in wmi.ExecQuery("SELECT Name, CommandLine FROM Win32_Process WHERE ProcessId=" pid)
                if (InStr(process.Name, "AutoHotkey") = 1 && IsOurCommandLine(process.CommandLine))
                    return pid
        }
    }
    return 0
}

; 由 PID 找到守护进程的主窗口 (AHK 脚本都有隐藏主窗口)
FindDaemonWindow() {
    DetectHiddenWindows true
    pid := ReadDaemonPid()
    if (!pid)
        return 0
    return WinExist("ahk_pid " pid)
}

WriteDaemonPid() {
    global pidFile
    try FileDelete(pidFile)
    try FileAppend(String(ProcessExist()), pidFile)
}

ClearDaemonPid() {
    global pidFile
    try {
        if (Integer(Trim(FileRead(pidFile))) = ProcessExist())
            FileDelete(pidFile)
    }
}

; 杀掉本工具的全部进程 (守护 + 遗留 CLI 助手), 排除自己
KillDaemons() {
    me := ProcessExist()
    try {
        wmi := ComObject("WbemScripting.SWbemLocator").ConnectServer()
        for p in wmi.ExecQuery("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name LIKE 'AutoHotkey%'") {
            if (p.ProcessId = me)
                continue
            cmd := p.CommandLine
            if (!cmd || !IsOurCommandLine(cmd))
                continue
            try ProcessClose(p.ProcessId)
        }
    }
    ClearDaemonPid()
}

ReleaseModifiers() {
    ; 清除可能残留的修饰键/鼠标键按下状态 (系统级, 与驱动无关)
    try Send("{LWin up}{RWin up}{LCtrl up}{RCtrl up}{LAlt up}{RAlt up}{LShift up}{RShift up}{LButton up}{RButton up}{MButton up}")
}

; ---------------- 启动分流 ----------------
initState := ""
guiStart := false
isDaemonChild := false
for arg in A_Args
    if (arg = "--daemon")
        isDaemonChild := true

if (A_Args.Length >= 1 && !isDaemonChild) {
    a1 := StrLower(Trim(A_Args[1]))
    if (a1 = "release") {
        hwnd := FindDaemonWindow()
        if (hwnd)
            PostMessage(WM_APP_CMD, CMD_PANIC, 0, hwnd)
        Sleep 1200
        KillDaemons()
        Sleep 300
        ReleaseModifiers()
        LogMsg("RELEASE: daemons killed, modifiers released")
        ExitApp
    }
    if (a1 = "off" || a1 = "on" || a1 = "toggle" || a1 = "status" || a1 = "reidentify" || a1 = "gui") {
        hwnd := FindDaemonWindow()
        if (hwnd) {
            cmdMap := Map("toggle", CMD_TOGGLE, "off", CMD_OFF, "on", CMD_ON, "status", CMD_STATUS, "reidentify", CMD_REID, "gui", CMD_GUI)
            PostMessage(WM_APP_CMD, cmdMap[a1], 0, hwnd)
            Sleep 300
            ExitApp
        }
        if (a1 = "status") {
            TrayTip("键盘开关守护进程未运行", "键盘开关")
            Sleep 1000
            ExitApp
        }
        ; 没有守护进程: 派生一个独立的后台守护实例后立刻退出 (CLI 不阻塞)
        if (a1 = "gui") {
            Run('"' A_AhkPath '" "' A_ScriptFullPath '" --daemon', , "Hide")
            Sleep 2500
            hwnd := FindDaemonWindow()
            if (hwnd)
                PostMessage(WM_APP_CMD, CMD_GUI, 0, hwnd)
            ExitApp
        }
        Run('"' A_AhkPath '" "' A_ScriptFullPath '" ' a1 ' --daemon', , "Hide")
        ExitApp
    } else if (a1 = "identify") {
        RunIdentify()
        ExitApp
    }
}
if (isDaemonChild && A_Args.Length >= 1) {
    first := StrLower(Trim(A_Args[1]))
    if (first = "off" || first = "on" || first = "toggle")
        initState := first
}

; ---------------- 守护进程 ----------------
if (!AcquireDaemonLock()) {
    existing := FindDaemonWindow()
    if existing
        PostMessage(WM_APP_CMD, CMD_GUI, 0, existing)
    ExitApp
}
WriteDaemonPid()
OnMessage(WM_APP_CMD, CmdHandler)
OnMessage(0x0219, OnDeviceChange)     ; WM_DEVICECHANGE
OnExit((*) => DoCleanup())
RotateLog()

try AHI := AutoHotInterception()
catch as e {
    LogMsg("AHI init failed: " e.Message)
    TrayTip("键盘驱动初始化失败 (驱动未装好或未重启?): " e.Message, "键盘开关", 3)
    Sleep 3000
    ExitApp
}

; Best effort: release this context. This cannot repair other driver clients.
try AHI.SetState(false)
LogMsg("boot: context filters disabled before initialization")

core := KbCore(AHI, (s) => LogMsg(s))
core.SetOnChord((*) => PostMessage(WM_APP_CMD, CMD_TOGGLE, 0, A_ScriptHwnd))

try ApplyHotkey(IniRead(iniFile, "hotkey", "combo", "^!k"))
catch as e {
    LogMsg("saved hotkey invalid, fallback: " e.Message)
    ApplyHotkey("^!k")
}
core.SetExempt(ExemptMap())
try {
    settings := GestureSettings.Load(gestureFile)
    g_gestureRules := settings.rules
    g_gesturesEnabled := settings.enabled
    if !core.ConfigureGestures(g_gestureRules, g_gesturesEnabled)
        throw Error(core.lastError)
} catch as e {
    g_gesturesEnabled := false
    LogMsg("gesture configuration disabled: " e.Message)
}
g_desiredBlocked := IniRead(iniFile, "state", "blocked", "0") = "1"
if (initState != "") {
    g_desiredBlocked := initState = "off" ? true : initState = "on" ? false : !g_desiredBlocked
    IniWrite(g_desiredBlocked ? "1" : "0", iniFile, "state", "blocked")
}
g_ready := true

ok := IdentifyFlow(true)
tries := 0
while (!ok && tries < 5) {
    Sleep 2000
    ok := IdentifyFlow(true)
    tries++
}
if (ok) {
    ApplyPendingState()
} else {
    TrayTip("内置键盘暂未识别到; 看门狗会自动重试并在必要时弹出识别向导", "键盘开关", 2)
}

BuildTray()
LogMsg("daemon started, ids=" core.ids.Length " blocked=" core.blocked " hotkey=" g_hk)
SetTimer(OnTick, 2000)
SetTimer(PumpGestures, 15)
if (guiStart)
    ShowGui()
return

; ---------------- 定时维护 ----------------
PumpGestures() {
    global core
    before := core.mode
    pendingStop := core.needStop
    core.TickGestures()
    if (core.mode != before || pendingStop) {
        UpdateTrayIcon()
        UpdateGui()
        if (core.lastError != "")
            TrayTip("坏键替代已暂停: " core.lastError, "键盘开关", 3)
    }
}

OnTick() {
    global g_tick, g_watchFails, g_lastInteractive, core, g_desiredBlocked, g_scanGui, g_captureActive
    if (IsObject(g_scanGui) || g_captureActive)
        return
    g_tick++
    ; 已识别: 每 2 秒核验一次设备身份/编号 (开销极小), 设备变化时立即可见
    if (core.ids.Length > 0) {
        r := core.Revalidate()
        if (r = "lost") {
            LogMsg("device identity lost -> re-identify")
            if !core.Reset() {
                UpdateTrayIcon()
                UpdateGui()
                return
            }
            if (IdentifyFlow(true)) {
                SetBlocked(g_desiredBlocked, false, false)
            } else {
                TrayTip("内置键盘设备已变化, 正在重新识别…", "键盘开关", 2)
            }
            UpdateTrayIcon()
            UpdateGui()
        }
        return
    }
    ; 未识别: 每 10 秒静默重试；连续等待后最多每 5 分钟尝试一次识别向导。
    g_watchFails++
    if (g_watchFails >= 4 && A_TickCount - g_lastInteractive > 300000) {
        g_lastInteractive := A_TickCount
        if (IdentifyFlow(false)) {
            g_watchFails := 0
            TrayTip("已识别到内置键盘, 恢复上次状态…", "键盘开关")
            ApplyPendingState()
        }
        return
    }
    if (Mod(g_tick, 5) = 0 && IdentifyFlow(true)) {
        g_watchFails := 0
        ApplyPendingState()
    }
}

OnDeviceChange(wParam, lParam, msg, hwnd) {
    ; 设备到达/移除后 1.5 秒做一次核验 (避免枚举未完成的抖动)
    if (wParam = 0x8000 || wParam = 0x8004)
        SetTimer(() => OnTick(), -1500)
}

; ---------------- 识别流程 ----------------
CachedHandles() {
    global iniFile
    if (IniRead(iniFile, "device", "machine", "") != A_ComputerName)
        return []
    arr := []
    for v in StrSplit(IniRead(iniFile, "device", "handles", ""), ",")
        if (Trim(v) != "")
            arr.Push(Trim(v))
    return arr
}

SaveHandles() {
    global iniFile, core
    csv := ""
    for h in core.handles
        csv .= (csv = "" ? "" : ",") h
    IniWrite(csv, iniFile, "device", "handles")
    IniWrite(A_ComputerName, iniFile, "device", "machine")
}

IdentifyFlow(silent) {
    global AHI, core
    lst := 0
    try lst := AHI.GetDeviceList()
    catch as e {
        LogMsg("GetDeviceList failed: " e.Message)
        return false
    }
    if (!IsObject(lst) || lst.Count = 0) {
        static lastLog := 0
        if (A_TickCount - lastLog > 300000) {
            lastLog := A_TickCount
            LogMsg("devlist empty (driver not attached? run setup + reboot)")
        }
        return false
    }
    cached := CachedHandles()
    observed := {used: false}
    n := core.Identify(lst, cached, silent ? 0 : ((list) => ObserveForIdentification(list, observed)))
    if (n > 0) {
        needsConfirmation := false
        for handle in core.handles {
            known := false
            for old in cached
                if (StrLower(handle) = StrLower(old))
                    known := true
            if !known
                needsConfirmation := true
        }
        if (needsConfirmation && !observed.used) {
            candidates := []
            for i, id in core.ids
                candidates.Push({id: id, handle: core.handles[i]})
            core.ids := [], core.handles := []
            if silent {
                core.lastError := "device confirmation required"
                return false
            }
            confirmed := ConfirmDevices(candidates)
            if (!confirmed.Length)
                return false
            ; Only explicitly confirmed handles become trusted local cache.
            n := core.Identify(lst, [], (*) => confirmed, false)
            if (!n)
                return false
        }
        SaveHandles()
        LogMsg("identified " n " internal keyboard(s): " JoinArr(core.handles, " | "))
        return true
    }
    LogMsg("identify failed: " core.lastError)
    return false
}

ObserveForIdentification(list, observed) {
    observed.used := true
    return ObserveInternalDevices(list)
}

JoinArr(arr, sep) {
    s := ""
    for v in arr
        s .= (s = "" ? "" : sep) v
    return s
}

; 交互识别: 要求在内置键盘上按 2 个不同按键 (排除鼠标/外设干扰), 并勾选确认
ObserveInternalDevices(list) {
    global AHI, core
    kbs := []
    for id, info in list {
        if (info.IsMouse)
            continue
        h := String(info.Handle)
        ; 蓝牙键盘是外接设备, 不参与识别
        if (KbCore.IsBluetoothHandle(h))
            continue
        kbs.Push(id)
    }
    if (kbs.Length = 0)
        return []
    hits := Map()      ; id -> Map(codes)
    for id in kbs {
        ; Track attempts in the same ownership ledger as normal subscriptions.
        ; Non-blocking observation must still clean up a partially failed API.
        core.subs[id] := String(list[id].Handle)
        try AHI.SubscribeKeyboard(id, false, MakeObserver(id, &hits))
        catch as e {
            LogMsg("identification subscribe failed: " e.Message)
            core.Stop()
            return []
        }
    }
    TrayTip("识别向导: 请按【内置键盘】上的任意两个不同按键`n(15 秒内, 不要按外接键盘)", "键盘开关", 0)
    start := A_TickCount
    found := false
    while (A_TickCount - start < 15000) {
        for id, codes in hits {
            if (codes.Count >= 2) {
                found := true
                break
            }
        }
        if (found)
            break
        Sleep 100
    }
    if !core.Stop() {
        TrayTip("识别订阅释放未确认，请使用“停止处理并退出”", "键盘开关", 3)
        return []
    }
    if (!found) {
        TrayTip("识别向导超时, 请稍后重试 (面板 → 重新识别)", "键盘开关", 3)
        return []
    }
    cand := []
    for id, codes in hits {
        if (codes.Count >= 2)
            cand.Push({id: id, handle: String(list[id].Handle)})
    }
    return ConfirmDevices(cand)
}

MakeObserver(id, &hits) {
    fn(code, state) {
        if (state != 1)
            return
        if (!hits.Has(id))
            hits[id] := Map()
        hits[id][code] := true
    }
    return fn
}

ConfirmDevices(cand) {
    if (cand.Length = 0)
        return []
    st := {done: false, result: []}
    pg := Gui("", "确认内置键盘设备")
    pg.MarginX := 14
    pg.MarginY := 12
    pg.SetFont("s9")
    pg.AddText("w380", "以下设备收到了你的按键。请勾选所有【内置】键盘设备`n(外接键盘请不要勾选):")
    boxes := []
    for c in cand {
        chk := pg.AddCheckBox("w380 y+6", c.handle)
        boxes.Push({dev: c, chk: chk})
    }
    pg.AddButton("w380 h32 y+10", "确认并保存").OnEvent("Click", ConfirmClick.Bind(st, boxes, pg))
    pg.AddButton("w380 h28", "取消").OnEvent("Click", CancelClick.Bind(st, pg))
    pg.OnEvent("Close", CloseClick.Bind(st, pg))
    pg.Show()
    while (!st.done)
        Sleep 50
    return st.result
}

CloseClick(st, pg, guiObj) {
    st.done := true
    pg.Destroy()
}

ConfirmClick(st, boxes, pg, ctrl, info) {
    out := []
    for b in boxes
        if (b.chk.Value)
            out.Push(b.dev)
    st.result := out
    st.done := true
    pg.Destroy()
}

CancelClick(st, pg, ctrl, info) {
    st.done := true
    pg.Destroy()
}

ApplyPendingState() {
    global g_desiredBlocked
    SetBlocked(g_desiredBlocked, false, false)
}

; ---------------- 状态切换 ----------------
SetBlocked(block, notify := true, persist := true) {
    global core, g_desiredBlocked, iniFile, g_scanGui, g_captureActive
    if g_captureActive
        CancelShortcutCapture()
    if IsObject(g_scanGui)
        EndScan(false)
    if persist {
        g_desiredBlocked := block
        IniWrite(block ? "1" : "0", iniFile, "state", "blocked")
    }
    if (block && core.ids.Length = 0) {
        if (!IdentifyFlow(false)) {
            if notify
                TrayTip("未识别到内置键盘，已记住目标状态；看门狗会继续重试", "键盘开关", 3)
            UpdateTrayIcon()
            UpdateGui()
            return false
        }
    }
    if (block) {
        if (!core.Block()) {
            ReleaseModifiers()
            LogMsg("BLOCK FAILED: " core.lastError)
            if notify
                TrayTip("暂停输入失败：" core.lastError, "键盘开关", 3)
            UpdateTrayIcon()
            UpdateGui()
            return false
        }
    } else {
        if !core.Unblock() {
            LogMsg("RELEASE/REMAP FAILED: " core.lastError)
            if notify
                TrayTip("恢复未确认: " core.lastError, "键盘开关", 3)
            UpdateTrayIcon()
            UpdateGui()
            return false
        }
        ReleaseModifiers()   ; 清除可能的残留按下状态
    }
    if notify
        TrayTip(core.blocked ? "内置键盘已暂停输入 (" core.ids.Length " 个设备)`n只保留外接键盘" : "内置键盘已恢复", "键盘开关")
    UpdateTrayIcon()
    UpdateGui()
    LogMsg("state -> " (core.blocked ? "blocked" : "allowed") " subs=" core.subs.Count)
    return true
}

; ---------------- 坏键替代设置 ----------------
ShowGestureSettings(*) {
    CancelShortcutCapture()
    global g_settingsWindow, g_gestureRules, g_gesturesEnabled
    if IsObject(g_settingsWindow) {
        try {
            g_settingsWindow.Show()
            return
        }
    }
    g_settingsWindow := GestureSettingsWindow(g_gestureRules, g_gesturesEnabled, ApplyGestureSettings)
    g_settingsWindow.Show()
}

ApplyGestureSettings(rules, enabled) {
    global core, gestureFile, g_gestureRules, g_gesturesEnabled, g_desiredBlocked
    KeyGestures.Validate(rules)
    oldRules := g_gestureRules, oldEnabled := g_gesturesEnabled
    if !core.ConfigureGestures(rules, enabled)
        throw Error(core.lastError)
    try {
        if (core.ids.Length > 0 && !SetBlocked(g_desiredBlocked, false, false))
            throw Error(core.lastError)
        GestureSettings.Save(gestureFile, rules, enabled)
    } catch as e {
        core.ConfigureGestures(oldRules, oldEnabled)
        if core.ids.Length
            SetBlocked(g_desiredBlocked, false, false)
        throw e
    }
    g_gestureRules := rules.Clone()
    g_gesturesEnabled := enabled
    UpdateGui()
    TrayTip(enabled ? "坏键替代已启用（仅内置键盘）" : "坏键替代已关闭", "键盘开关")
    LogMsg("gesture settings saved: enabled=" enabled " rules=" rules.Length)
    return true
}

; ---------------- 快捷键 ----------------
ApplyHotkey(hk) {
    global g_hk, g_hkObj, core, iniFile
    hk := Trim(hk)
    if (hk = "")
        hk := "^!k"
    if (!RegExMatch(hk, "[\^\!\+\#]"))
        throw Error("快捷键必须至少含一个修饰键 (Ctrl/Alt/Shift/Win)")
    oldHK := g_hk
    try {
        Hotkey(hk, (*) => SetBlocked(!core.blocked), "On")
        IniWrite(hk, iniFile, "hotkey", "combo")
        if (oldHK != "" && oldHK != hk)
            Hotkey(oldHK, , "Off")
    } catch as e {
        if (hk != oldHK)
            try Hotkey(hk, , "Off")
        try Hotkey(oldHK, , "On")
        try IniWrite(oldHK, iniFile, "hotkey", "combo")
        throw e
    }
    g_hkObj := 0
    g_hk := hk
    SyncChord()
    SyncShortcutHotkey()
}

SyncChord() {
    global core, g_hk
    mods := Map()
    if InStr(g_hk, "^")
        mods[GetKeySC("LCtrl")] := true
    if InStr(g_hk, "!")
        mods[GetKeySC("LAlt")] := true
    if InStr(g_hk, "+")
        mods[GetKeySC("LShift")] := true
    if InStr(g_hk, "#")
        mods[GetKeySC("LWin")] := true
    keyPart := RegExReplace(g_hk, "[\^\!\+\#]")
    keyCode := 0
    if (keyPart != "")
        keyCode := GetKeySC(keyPart)
    core.SetChord(mods, keyCode)
    LogMsg("chord: key=" keyCode " mods=" mods.Count)
}

SyncShortcutHotkey() {
    global g_hk
    try {
        lnkPath := A_Desktop "\切换内置键盘.lnk"
        if (!FileExist(lnkPath))
            return
        ws := ComObject("WScript.Shell")
        lnk := ws.CreateShortcut(lnkPath)
        try {
            lnk.Hotkey := HotkeyPretty(g_hk)
            lnk.Save()
        } catch {
            lnk.Hotkey := ""
            lnk.Save()
        }
    } catch as e {
        LogMsg("shortcut sync failed: " e.Message)
    }
}

HotkeyPretty(hk) {
    return ShortcutCapture.Pretty(hk)
}

; ---------------- 扫描 / 豁免 ----------------
ExemptMap() {
    global iniFile
    m := Map()
    for v in StrSplit(IniRead(iniFile, "exempt", "codes", ""), ",") {
        v := Trim(v)
        if (v = "")
            continue
        try m[Integer(v)] := true
        catch
            continue
    }
    return m
}

ExemptCount() {
    n := 0
    for _ in ExemptMap()
        n++
    return n
}

ApplyExempt() {
    global core, iniFile
    m := ExemptMap()
    core.SetExempt(m)
    if (core.blocked) {
        ; 回调实时读取豁免表, 无需重建订阅
        LogMsg("exempt applied live: " m.Count " keys")
    }
    UpdateGui()
}

ScanKeyName(code) {
    try {
        n := GetKeyName("SC" Format("{:X}", code))
        if (n != "")
            return n
    }
    return Format("0x{:X}", code)
}

ScanCbFn(code, state) {
    global g_scanMap, g_scanOrder, g_scanDirty
    if (state != 1 || g_scanMap.Has(code))
        return
    g_scanMap[code] := true
    g_scanOrder.Push(code)
    g_scanDirty := 1
}

ScanTimer() {
    global g_scanDirty, g_scanOrder, g_scanLb, g_scanGui
    if (!g_scanDirty || !IsObject(g_scanGui))
        return
    g_scanDirty := 0
    g_scanLb.Delete()
    for _, code in g_scanOrder
        g_scanLb.Add([ScanKeyName(code) "    (code " code ")"])
}

ScanKeysFlow(*) {
    CancelShortcutCapture()
    global AHI, core, g_scanGui, g_scanLb, g_scanMap, g_scanOrder, g_scanDirty
    if (core.ids.Length = 0) {
        TrayTip("内置键盘未识别, 无法扫描", "键盘开关", 3)
        return
    }
    if (core.blocked) {
        TrayTip("请先恢复内置键盘再扫描, 否则按键无反应", "键盘开关", 3)
        return
    }
    if IsObject(g_scanGui) {
        g_scanGui.Show()
        return
    }
    g_scanMap := Map()
    g_scanOrder := []
    g_scanDirty := 0
    core.onObserve := ScanCbFn
    if !core.SubscribeMode("observe") {
        core.onObserve := 0
        TrayTip("扫描订阅失败, 见日志", "键盘开关", 3)
        return
    }
    g_scanGui := Gui("", "扫描内置键盘按键")
    g_scanGui.MarginX := 14
    g_scanGui.MarginY := 12
    AppTheme.Setup(g_scanGui)
    g_scanGui.AddText("w360", "请按下想保留的内置按键，例如音量键。`n扫描期间按键正常输入，完成后选择需要保留的项。")
    g_scanLb := g_scanGui.AddListBox("w300 r10")
    g_scanGui.AddButton("w360 h36 y+10", "完成扫描并选择按键").OnEvent("Click", FinishScan)
    g_scanGui.AddButton("w300 h28", "取消").OnEvent("Click", CancelScan)
    g_scanGui.OnEvent("Close", CancelScan)
    g_scanGui.Show()
    SetTimer(ScanTimer, 150)
}

CancelScan(*) {
    EndScan()
}

EndScan(resume := true) {
    global core, g_scanGui, g_desiredBlocked
    SetTimer(ScanTimer, 0)
    core.onObserve := 0
    core.Stop()
    if (IsObject(g_scanGui)) {
        g_scanGui.Destroy()
        g_scanGui := 0
    }
    if resume
        SetBlocked(g_desiredBlocked, false, false)
}

FinishScan(*) {
    global AHI, core, g_scanGui, g_scanOrder
    codes := g_scanOrder.Clone()
    EndScan()
    if (codes.Length = 0) {
        TrayTip("未检测到按键，保留列表未修改", "键盘开关")
        return
    }
    ShowExemptPicker(codes)
}

ShowExemptPicker(codes) {
    exempt := ExemptMap()
    pg := Gui("", "暂停时仍可使用的按键")
    pg.MarginX := 14
    pg.MarginY := 12
    AppTheme.Setup(pg)
    pg.AddText("w360", "勾选后，暂停内置键盘时这些键仍可使用。`n切换快捷键不受此列表影响。")
    boxes := []
    for _, code in codes {
        chk := pg.AddCheckBox(Format("w360 y+6 Checked{}", exempt.Has(code) ? 1 : 0), ScanKeyName(code))
        boxes.Push({code: code, chk: chk})
    }
    pg.AddButton("w360 h36 y+10", "保存保留按键").OnEvent("Click", SaveExemptClick.Bind(boxes, pg))
    pg.AddButton("w300 h28", "取消").OnEvent("Click", (ctrl, *) => ctrl.Gui.Destroy())
    pg.Show()
}

SaveExemptClick(boxes, pg, ctrl, info) {
    global iniFile
    old := ExemptMap()
    scanned := Map()
    checked := Map()
    for b in boxes {
        scanned[b.code] := true
        if (b.chk.Value)
            checked[b.code] := true
    }
    for code, _ in old
        if (!scanned.Has(code))
            checked[code] := true
    csv := ""
    for code, _ in checked
        csv .= (csv = "" ? "" : ",") code
    IniWrite(csv, iniFile, "exempt", "codes")
    pg.Destroy()
    ApplyExempt()
    TrayTip("保留列表已保存：" checked.Count " 个键在暂停输入时仍可使用", "键盘开关")
    LogMsg("exempt saved: " csv)
}

ClearExempt(*) {
    global iniFile
    IniWrite("", iniFile, "exempt", "codes")
    ApplyExempt()
    TrayTip("保留按键列表已清空", "键盘开关")
    LogMsg("exempt cleared")
}

; ---------------- 面板 ----------------
; ---------------- 重新识别 / 应急 ----------------
ReidentifyFlow(*) {
    CancelShortcutCapture()
    global core, g_desiredBlocked, g_scanGui, iniFile
    if IsObject(g_scanGui)
        EndScan(false)
    if !core.Reset() {
        TrayTip("旧订阅未成功清理，请使用“停止处理并退出”", "键盘开关", 3)
        return
    }
    IniWrite("", iniFile, "device", "handles")
    IniWrite("", iniFile, "device", "machine")
    if (IdentifyFlow(false)) {
        SetBlocked(g_desiredBlocked, false, false)
        TrayTip("识别成功: " core.ids.Length " 个内置键盘设备", "键盘开关")
    } else {
        TrayTip("识别失败: " core.lastError "（看门狗会继续重试）", "键盘开关", 3)
    }
    UpdateGui()
    UpdateTrayIcon()
}

EmergencyRelease(*) {
    global g_captureActive, g_captureCandidate
    g_captureCandidate := ""
    if g_captureActive {
        ; End recording without briefly restoring the old blocking state.
        g_captureActive := false
        SetTimer(ShortcutCaptureTick, 0)
        try g_captureHook.Stop()
    }
    core.Panic()
    ReleaseModifiers()
    LogMsg("EMERGENCY RELEASE")
    TrayTip("已尝试停止输入处理，程序即将退出" , "键盘开关")
    SetTimer(() => ExitApp(), -800)
}

DoCleanup() {
    global core, g_exiting
    if (g_exiting)
        return
    g_exiting := true
    CancelShortcutCapture()
    try core.Panic()
    try ReleaseModifiers()
    ClearDaemonPid()
    if g_instanceMutex
        DllCall("CloseHandle", "Ptr", g_instanceMutex)
    LogMsg("daemon exiting, keyboard released")
}

; ---------------- 托盘 ----------------
BuildTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("状态面板", (*) => ShowGui())
    A_TrayMenu.Add()
    A_TrayMenu.Add("切换内置键盘", (*) => SetBlocked(!core.blocked))
    A_TrayMenu.Add("暂停内置键盘输入", (*) => SetBlocked(true))
    A_TrayMenu.Add("允许内置键盘输入", (*) => SetBlocked(false))
    A_TrayMenu.Add()
    A_TrayMenu.Add("选择暂停时保留的按键…", ScanKeysFlow)
    A_TrayMenu.Add("录制切换快捷键…", CaptureHotkeyFlow)
    A_TrayMenu.Add("按键替代设置…", ShowGestureSettings)
    A_TrayMenu.Add("重新识别内置键盘", ReidentifyFlow)
    A_TrayMenu.Add("清空保留按键列表", ClearExempt)
    A_TrayMenu.Add("开机自动启动", ToggleAutostart)
    A_TrayMenu.Add()
    A_TrayMenu.Add("输入异常：停止处理并退出", EmergencyRelease)
    A_TrayMenu.Add("退出并停止输入处理", (*) => ExitApp())
    A_TrayMenu.Default := "状态面板"
    if (IsAutostart())
        A_TrayMenu.Check("开机自动启动")
    UpdateTrayIcon()
}

UpdateTrayIcon(*) {
    global core
    if (core.mode = "error") {
        TraySetIcon("shell32.dll", 78)
        A_IconTip := "键盘开关：处理状态异常，请停止处理并退出"
    } else if (core.ids.Length = 0) {
        TraySetIcon("shell32.dll", 78)
        A_IconTip := "键盘开关：未识别到内置键盘"
    } else if (core.blocked) {
        TraySetIcon("shell32.dll", 109)
        A_IconTip := "键盘开关：内置键盘已暂停输入"
    } else {
        TraySetIcon("setupapi.dll", 2)
        A_IconTip := "键盘开关：内置键盘正常"
    }
}

ToggleAutostart(*) {
    if (IsAutostart())
        RemoveAutostart()
    else
        SetAutostart()
    if (IsAutostart())
        A_TrayMenu.Check("开机自动启动")
    else
        A_TrayMenu.Uncheck("开机自动启动")
    UpdateGui()
}

SetAutostart() {
    path := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
    existing := RegRead(path, "LapKeySwitch", "")
    if (existing != "" && !IsOurCommandLine(existing)) {
        MsgBox("其他安装正在使用这个自启项，请先卸载该副本。", "无法启用自启")
        return
    }
    RegWrite('"' A_AhkPath '" "' A_ScriptFullPath '"', "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "LapKeySwitch")
}

RemoveAutostart() {
    if IsAutostart()
        try RegDelete("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "LapKeySwitch")
}

IsAutostart() {
    try {
        v := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "LapKeySwitch")
        return IsOurCommandLine(v)
    } catch {
        return false
    }
}

CmdHandler(wParam, lParam, msg, hwnd) {
    global core, g_ready
    if (!g_ready || !IsObject(core)) {
        SetTimer(() => CmdHandler(wParam, lParam, msg, hwnd), -200)
        return
    }
    switch wParam {
        case CMD_TOGGLE:  SetBlocked(!core.blocked)
        case CMD_OFF:     SetBlocked(true)
        case CMD_ON:      SetBlocked(false)
        case CMD_STATUS:  TrayTip("状态: " (core.mode = "error" ? "未确认" : core.ids.Length = 0 ? "未识别" : core.blocked ? "已截断" : core.mode = "remap" ? "正常（坏键替代启用）" : "正常") " | 设备 " core.ids.Length " | 豁免 " ExemptCount() " | 热键 " HotkeyPretty(g_hk), "键盘开关")
        case CMD_GUI:     ShowGui()
        case CMD_REID:    ReidentifyFlow()
        case CMD_PANIC:   EmergencyRelease()
    }
}

RunIdentify() {
    global AHI, core
    try AHI := AutoHotInterception()
    catch as e {
        MsgBox("驱动初始化失败: " e.Message)
        ExitApp
    }
    core := KbCore(AHI, (s) => LogMsg(s))
    if (IdentifyFlow(false))
        MsgBox("识别成功: " JoinArr(core.handles, " | "))
    else
        MsgBox("识别失败: " core.lastError)
    ExitApp
}
