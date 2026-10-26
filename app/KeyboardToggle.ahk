; =====================================================================
;  笔记本内置键盘 热开关 v5
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
;    - 启动时清理所有旧的守护进程 (含旧版本残留)
;    - 设备身份(编号+句柄)订阅前核验, 不符绝不订阅
; =====================================================================
#Requires AutoHotkey v2.0
#SingleInstance Off
Persistent
#include Lib\AutoHotInterception.ahk
#include lib\KbCore.ahk

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
global g_scanGui    := 0
global g_scanLb     := 0
global g_scanMap    := Map()
global g_scanOrder  := []
global g_scanDirty  := 0
global g_watchFails := 0
global g_lastInteractive := 0
global g_pendingInit := ""
global g_tick := 0
global g_needReval := 0
global g_exiting := false

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
        if (pid > 0 && ProcessExist(pid))
            return pid
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
    try FileDelete(pidFile)
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
            if (!cmd || !InStr(cmd, A_ScriptName))
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
KillDaemons()
Sleep 400
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

; 启动即安全化: 清掉任何历史残留的全局拦截位 (v5 时代 SetState(true) 的遗留)
try AHI.SetState(false)
LogMsg("boot: SetState(false) applied (clear any legacy global filter)")

core := KbCore(AHI, (s) => LogMsg(s))
core.SetOnChord((*) => PostMessage(WM_APP_CMD, CMD_TOGGLE, 0, A_ScriptHwnd))

try ApplyHotkey(IniRead(iniFile, "hotkey", "combo", "^!k"))
catch as e {
    LogMsg("saved hotkey invalid, fallback: " e.Message)
    ApplyHotkey("^!k")
}
core.SetExempt(ExemptMap())

g_pendingInit := initState
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
if (guiStart)
    ShowGui()
return

; ---------------- 定时维护 ----------------
OnTick() {
    global g_tick, g_needReval, g_watchFails, g_lastInteractive, core
    g_tick++
    ; 已识别: 每 2 秒核验一次设备身份/编号 (开销极小), 设备变化时立即可见
    if (core.ids.Length > 0) {
        r := core.Revalidate()
        if (r = "lost") {
            LogMsg("device identity lost -> re-identify")
            core.Reset()
            if (IdentifyFlow(true)) {
                if (core.blocked)
                    SetBlocked(true)
                else
                    SetBlocked(false)
            } else {
                SetBlocked(false)
                TrayTip("内置键盘设备已变化, 正在重新识别…", "键盘开关", 2)
            }
            UpdateGui()
        }
        return
    }
    ; 未识别: 每 2 秒一次的静默重试; 连续失败后每 5 分钟升级一次交互识别
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
    global g_needReval
    ; 设备到达/移除后 1.5 秒做一次核验 (避免枚举未完成的抖动)
    if (wParam = 0x8000 || wParam = 0x8004)
        SetTimer(() => (g_needReval := 1), -1500)
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
    n := core.Identify(lst, cached, silent ? 0 : ((list) => ObserveInternalDevices(list)))
    if (n > 0) {
        SaveHandles()
        LogMsg("identified " n " internal keyboard(s): " JoinArr(core.handles, " | "))
        return true
    }
    LogMsg("identify failed: " core.lastError)
    return false
}

JoinArr(arr, sep) {
    s := ""
    for v in arr
        s .= (s = "" ? "" : sep) v
    return s
}

; 交互识别: 要求在内置键盘上按 2 个不同按键 (排除鼠标/外设干扰), 并勾选确认
ObserveInternalDevices(list) {
    global AHI
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
    for id in kbs
        try AHI.SubscribeKeyboard(id, false, MakeObserver(id, &hits))
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
    for id in kbs
        try AHI.UnsubscribeKeyboard(id)
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
        chk := pg.AddCheckBox("w380 y+6 Checked", c.handle)
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
    global g_pendingInit, iniFile, core
    if (g_pendingInit != "") {
        p := g_pendingInit
        g_pendingInit := ""
        SetBlocked(p = "off" ? true : p = "on" ? false : !core.blocked)
        return
    }
    SetBlocked(IniRead(iniFile, "state", "blocked", "0") = "1")
}

; ---------------- 状态切换 ----------------
SetBlocked(block) {
    global core
    if (core.ids.Length = 0) {
        if (!IdentifyFlow(false)) {
            TrayTip("未识别到内置键盘, 无法切换 (看门狗会继续重试)", "键盘开关", 3)
            return
        }
    }
    if (block) {
        if (!core.Block()) {
            ReleaseModifiers()
            LogMsg("BLOCK FAILED: " core.lastError)
            TrayTip("截断失败: " core.lastError "`n当前状态: 已放行", "键盘开关", 3)
            UpdateTrayIcon()
            UpdateGui()
            return
        }
    } else {
        core.Unblock()
        ReleaseModifiers()   ; 清除可能的残留按下状态
    }
    IniWrite(core.blocked ? "1" : "0", iniFile, "state", "blocked")
    TrayTip(core.blocked ? "内置键盘已截断 (" core.ids.Length " 个设备)`n只保留外接键盘" : "内置键盘已恢复", "键盘开关")
    UpdateTrayIcon()
    UpdateGui()
    LogMsg("state -> " (core.blocked ? "blocked" : "allowed") " subs=" core.subs.Count)
}

; ---------------- 快捷键 ----------------
ApplyHotkey(hk) {
    global g_hk, g_hkObj, core
    hk := Trim(hk)
    if (hk = "")
        hk := "^!k"
    if (!RegExMatch(hk, "[\^\!\+\#]"))
        throw Error("快捷键必须至少含一个修饰键 (Ctrl/Alt/Shift/Win)")
    newObj := Hotkey(hk, (*) => SetBlocked(!core.blocked), "On")
    if (g_hk != "" && g_hk != hk) {
        removed := false
        if (IsObject(g_hkObj)) {
            try {
                g_hkObj.Delete()
                removed := true
            }
        }
        if (!removed)
            try Hotkey(g_hk, , "Off")
    }
    g_hkObj := newObj
    g_hk := hk
    IniWrite(hk, iniFile, "hotkey", "combo")
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
    s := ""
    if InStr(hk, "^")
        s .= "Ctrl+"
    if InStr(hk, "!")
        s .= "Alt+"
    if InStr(hk, "+")
        s .= "Shift+"
    if InStr(hk, "#")
        s .= "Win+"
    return s StrUpper(RegExReplace(hk, "[\^\!\+\#]"))
}

CaptureHotkeyFlow(*) {
    TrayTip("请按下新的快捷键组合 (必须含 Ctrl/Alt/Shift/Win 至少一个,`nEsc 取消, 10 秒内有效)", "键盘开关: 自定义快捷键", 0)
    ih := InputHook("L1 T10")
    ih.KeyOpt("{All}", "E")
    ih.KeyOpt("{LCtrl}{RCtrl}{LAlt}{RAlt}{LShift}{RShift}{LWin}{RWin}", "-E")
    ih.Start()
    ih.Wait()
    if (ih.EndReason = "Timeout" || (ih.EndReason = "EndKey" && StrLower(ih.EndKey) = "esc")) {
        TrayTip("已取消, 快捷键未修改", "键盘开关")
        return
    }
    mods := ""
    if (GetKeyState("LCtrl", "P") || GetKeyState("RCtrl", "P"))
        mods .= "^"
    if (GetKeyState("LAlt", "P") || GetKeyState("RAlt", "P"))
        mods .= "!"
    if (GetKeyState("LShift", "P") || GetKeyState("RShift", "P"))
        mods .= "+"
    if (GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        mods .= "#"
    if (mods = "") {
        TrayTip("已拒绝: 快捷键必须至少含一个修饰键, 单键会导致打字误触发", "键盘开关", 3)
        UpdateGuiHkText()
        return
    }
    newHK := mods ih.EndKey
    try {
        ApplyHotkey(newHK)
        TrayTip("快捷键已设置: " HotkeyPretty(newHK), "键盘开关")
    } catch {
        TrayTip("组合 " newHK " 无法注册, 快捷键未修改", "键盘开关", 3)
    }
    UpdateGuiHkText()
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
    global AHI, core, g_scanGui, g_scanLb, g_scanMap, g_scanOrder, g_scanDirty
    if (core.ids.Length = 0) {
        TrayTip("内置键盘未识别, 无法扫描", "键盘开关", 3)
        return
    }
    if (core.blocked) {
        TrayTip("请先恢复内置键盘再扫描, 否则按键无反应", "键盘开关", 3)
        return
    }
    subOK := true
    for id in core.ids {
        try AHI.SubscribeKeyboard(id, false, ScanCbFn)
        catch
            subOK := false
    }
    if (!subOK) {
        TrayTip("扫描订阅失败, 见日志", "键盘开关", 3)
        return
    }
    g_scanMap := Map()
    g_scanOrder := []
    g_scanDirty := 0
    g_scanGui := Gui("", "扫描内置键盘按键")
    g_scanGui.MarginX := 14
    g_scanGui.MarginY := 12
    g_scanGui.SetFont("s9")
    g_scanGui.AddText("w300", "请逐个按一遍内置键盘上的按键 (含滚轮/多媒体键),`n按过的键会实时出现在列表里。")
    g_scanLb := g_scanGui.AddListBox("w300 r10")
    g_scanGui.AddButton("w300 h32 y+10", "完成扫描, 选择要豁免的键").OnEvent("Click", FinishScan)
    g_scanGui.AddButton("w300 h28", "取消").OnEvent("Click", CancelScan)
    g_scanGui.OnEvent("Close", CancelScan)
    g_scanGui.Show()
    SetTimer(ScanTimer, 150)
}

CancelScan(*) {
    global AHI, core, g_scanGui
    SetTimer(ScanTimer, 0)
    for id in core.ids
        try AHI.UnsubscribeKeyboard(id)
    if (IsObject(g_scanGui)) {
        g_scanGui.Destroy()
        g_scanGui := 0
    }
}

FinishScan(*) {
    global AHI, core, g_scanGui, g_scanOrder
    SetTimer(ScanTimer, 0)
    for id in core.ids
        try AHI.UnsubscribeKeyboard(id)
    codes := g_scanOrder.Clone()
    if (IsObject(g_scanGui)) {
        g_scanGui.Destroy()
        g_scanGui := 0
    }
    if (codes.Length = 0) {
        TrayTip("没有按任何键, 豁免清单未修改", "键盘开关")
        return
    }
    ShowExemptPicker(codes)
}

ShowExemptPicker(codes) {
    exempt := ExemptMap()
    pg := Gui("", "选择要豁免的键")
    pg.MarginX := 14
    pg.MarginY := 12
    pg.SetFont("s9")
    pg.AddText("w300", "勾选 = 截断键盘时该键照常工作 (豁免)`n(紧急组合键永远受保护)")
    boxes := []
    for _, code in codes {
        chk := pg.AddCheckBox(Format("w300 y+6 Checked{}", exempt.Has(code) ? 1 : 0), ScanKeyName(code) "    (code " code ")")
        boxes.Push({code: code, chk: chk})
    }
    pg.AddButton("w300 h32 y+10", "保存豁免").OnEvent("Click", SaveExemptClick.Bind(boxes, pg))
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
    TrayTip("豁免已保存: " checked.Count " 个键在截断时照常工作", "键盘开关")
    LogMsg("exempt saved: " csv)
}

ClearExempt(*) {
    global iniFile
    IniWrite("", iniFile, "exempt", "codes")
    ApplyExempt()
    TrayTip("豁免清单已清空", "键盘开关")
    LogMsg("exempt cleared")
}

; ---------------- 面板 ----------------
ShowGui(*) {
    global g_gui, g_ctlStatus, g_ctlHk, g_ctlExempt, g_ctlAuto
    if (!IsObject(g_gui)) {
        g_gui := Gui("", "内置键盘开关")
        g_gui.MarginX := 16
        g_gui.MarginY := 14
        g_gui.SetFont("s11 w700")
        g_ctlStatus := g_gui.AddText("w330 Center", "")
        g_gui.SetFont("s9 w400 norm")
        g_ctlHk := g_gui.AddText("w330 Center", "")
        g_ctlExempt := g_gui.AddText("w330 Center", "")
        g_gui.AddButton("w330 h34 y+12", "切换内置键盘").OnEvent("Click", (*) => SetBlocked(!core.blocked))
        g_gui.AddButton("w158 h32 y+10 Section", "只留外接").OnEvent("Click", (*) => SetBlocked(true))
        g_gui.AddButton("w158 h32 ys x+14", "恢复内置").OnEvent("Click", (*) => SetBlocked(false))
        g_gui.AddButton("w158 h32 y+10", "扫描按键(豁免)…").OnEvent("Click", ScanKeysFlow)
        g_gui.AddButton("w158 h32 ys x+14", "自定义快捷键…").OnEvent("Click", CaptureHotkeyFlow)
        g_gui.AddButton("w158 h32 y+10", "重新识别内置键盘").OnEvent("Click", ReidentifyFlow)
        g_gui.AddButton("w158 h32 ys x+14", "清除全部豁免").OnEvent("Click", ClearExempt)
        g_ctlAuto := g_gui.AddCheckBox("w158 h26 y+10 Checked" (IsAutostart() ? 1 : 0), "开机自动启动")
        g_ctlAuto.OnEvent("Click", OnAutoClick)
        g_gui.AddButton("w158 h26 ys x+14", "紧急恢复键盘").OnEvent("Click", EmergencyRelease)
        g_gui.OnEvent("Close", (g) => g.Hide())
    }
    UpdateGui()
    g_gui.Show()
}

UpdateGui(*) {
    global g_gui, g_ctlStatus, core
    if (!IsObject(g_gui))
        return
    if (core.ids.Length = 0) {
        g_ctlStatus.Text := "内置键盘：未识别（重试中）"
        g_ctlStatus.SetFont("cB8860B")
    } else if (core.blocked) {
        g_ctlStatus.Text := "内置键盘：已截断（" core.ids.Length " 个设备）"
        g_ctlStatus.SetFont("cC00000")
    } else {
        g_ctlStatus.Text := "内置键盘：已恢复（" core.ids.Length " 个设备）"
        g_ctlStatus.SetFont("c1A7A1A")
    }
    g_ctlStatus.Redraw()
    UpdateGuiHkText()
    n := ExemptCount()
    g_ctlExempt.Text := n > 0 ? "豁免按键: " n " 个（截断时照常工作）" : "豁免按键: 无"
    want := IsAutostart() ? 1 : 0
    if (g_ctlAuto.Value != want)
        g_ctlAuto.Value := want
}

UpdateGuiHkText(*) {
    global g_gui, g_ctlHk, g_hk
    if (!IsObject(g_gui))
        return
    g_ctlHk.Text := "快捷键: " HotkeyPretty(g_hk) "（内置键盘截断时同组合也可切换）"
}

OnAutoClick(*) {
    if (IsAutostart())
        RemoveAutostart()
    else
        SetAutostart()
    UpdateGui()
}

; ---------------- 重新识别 / 应急 ----------------
ReidentifyFlow(*) {
    global core
    if (core.blocked)
        core.Unblock()
    core.Reset()
    IniWrite("", iniFile, "device", "handles")
    IniWrite("", iniFile, "device", "machine")
    if (IdentifyFlow(false)) {
        TrayTip("识别成功: " core.ids.Length " 个内置键盘设备", "键盘开关")
    } else {
        TrayTip("识别失败: " core.lastError "（看门狗会继续重试）", "键盘开关", 3)
    }
    UpdateGui()
}

EmergencyRelease(*) {
    core.Panic()
    ReleaseModifiers()
    LogMsg("EMERGENCY RELEASE")
    TrayTip("已强制放行全部键盘" , "键盘开关")
    SetTimer(() => ExitApp(), -800)
}

DoCleanup() {
    global core, g_exiting
    if (g_exiting)
        return
    g_exiting := true
    try core.Panic()
    try ReleaseModifiers()
    ClearDaemonPid()
    LogMsg("daemon exiting, keyboard released")
}

; ---------------- 托盘 ----------------
BuildTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("状态面板", (*) => ShowGui())
    A_TrayMenu.Add()
    A_TrayMenu.Add("切换内置键盘", (*) => SetBlocked(!core.blocked))
    A_TrayMenu.Add("只留外接 (截断内置)", (*) => SetBlocked(true))
    A_TrayMenu.Add("恢复内置键盘", (*) => SetBlocked(false))
    A_TrayMenu.Add()
    A_TrayMenu.Add("扫描按键(豁免)…", ScanKeysFlow)
    A_TrayMenu.Add("自定义快捷键…", CaptureHotkeyFlow)
    A_TrayMenu.Add("重新识别内置键盘", ReidentifyFlow)
    A_TrayMenu.Add("清除全部豁免", ClearExempt)
    A_TrayMenu.Add("开机自动启动", ToggleAutostart)
    A_TrayMenu.Add()
    A_TrayMenu.Add("紧急恢复键盘 (强制放行)", EmergencyRelease)
    A_TrayMenu.Add("退出 (自动放行内置键盘)", (*) => ExitApp())
    A_TrayMenu.Default := "状态面板"
    if (IsAutostart())
        A_TrayMenu.Check("开机自动启动")
    UpdateTrayIcon()
}

UpdateTrayIcon(*) {
    global core
    if (core.ids.Length = 0) {
        TraySetIcon("shell32.dll", 78)
        A_IconTip := "键盘开关：未识别到内置键盘"
    } else if (core.blocked) {
        TraySetIcon("shell32.dll", 109)
        A_IconTip := "键盘开关：内置键盘已截断"
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
    RegWrite('"' A_AhkPath '" "' A_ScriptFullPath '"', "REG_SZ", "HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "LapKeySwitch")
}

RemoveAutostart() {
    try RegDelete("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "LapKeySwitch")
}

IsAutostart() {
    try {
        v := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Run", "LapKeySwitch")
        return (v != "")
    } catch {
        return false
    }
}

CmdHandler(wParam, lParam, msg, hwnd) {
    global core
    switch wParam {
        case CMD_TOGGLE:  SetBlocked(!core.blocked)
        case CMD_OFF:     SetBlocked(true)
        case CMD_ON:      SetBlocked(false)
        case CMD_STATUS:  TrayTip("状态: " (core.blocked ? "已截断" : "正常") " | 设备 " core.ids.Length " | 豁免 " ExemptCount() " | 热键 " HotkeyPretty(g_hk), "键盘开关")
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
