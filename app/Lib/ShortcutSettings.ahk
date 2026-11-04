CaptureHotkeyFlow(*) {
    ShowGui()
    BeginShortcutCapture(InputHook("L0 T20"))
}

BeginShortcutCapture(hook) {
    global core, g_hk, g_captureActive, g_captureHook, g_captureState, g_captureCandidate, g_captureUntil, g_scanGui
    CancelShortcutCapture()
    for code in [29, 285, 56, 312, 42, 54, 347, 348]
        if GetKeyState("SC" Format("{:03X}", code), "P") {
            ShortcutHint("请先松开 Ctrl / Alt / Shift / Win，再点击录制。")
            return false
        }
    if IsObject(g_scanGui)
        EndScan(false)
    if !core.Stop() {
        ShortcutHint("无法开始录制：输入处理尚未成功停止。请使用“停止处理并退出”。")
        return false
    }
    try {
        g_captureActive := true
        g_captureHook := hook
        Hotkey(g_hk, , "Off")
        core.SetChord(Map(), 0)
        g_captureCandidate := ""
        g_captureState := ShortcutCapture()
        hook.KeyOpt("{All}", "NS")
        hook.OnKeyDown := (ih, vk, sc) => CaptureShortcutEvent(ih, sc, 1)
        hook.OnKeyUp := (ih, vk, sc) => CaptureShortcutEvent(ih, sc, 0)
        hook.OnEnd := CaptureHookEnded
        g_captureUntil := DllCall("GetTickCount64", "UInt64") + 20000
        hook.Start()
        SetTimer(ShortcutCaptureTick, 100)
        RenderShortcutCapture()
        UpdateGui()
        return true
    } catch as e {
        EndShortcutCapture("无法开始录制：" e.Message)
        return false
    }
}

CaptureShortcutEvent(hook, code, state) {
    global g_captureHook, g_captureActive, g_gui
    if (!g_captureActive || hook != g_captureHook)
        return
    if !WinActive("ahk_id " g_gui.Hwnd) {
        CancelShortcutCapture(, "面板失去焦点，录制已取消。")
        return
    }
    CaptureShortcutKey(code, state)
}

CaptureHookEnded(hook) {
    global g_captureHook, g_captureActive
    if (g_captureActive && hook = g_captureHook)
        EndShortcutCapture("录制超时或已结束，原快捷键未修改。")
}

CaptureShortcutKey(code, state) {
    global g_captureActive, g_captureState, g_captureCandidate
    if !g_captureActive
        return
    g_captureState.Key(code, state)
    if g_captureState.cancelled {
        CancelShortcutCapture()
        return
    }
    RenderShortcutCapture()
    if (g_captureState.candidate != "" && g_captureState.down.Count = 0) {
        g_captureCandidate := g_captureState.candidate
        EndShortcutCapture("已录制新组合。点击“保存快捷键”后生效。")
    }
}

ShortcutCaptureTick() {
    global g_gui, g_captureActive
    if !g_captureActive
        return
    if !WinActive("ahk_id " g_gui.Hwnd) {
        CancelShortcutCapture(, "面板失去焦点，录制已取消。")
        return
    }
    RenderShortcutCapture()
}

RenderShortcutCapture() {
    global g_captureActive, g_captureState, g_captureUntil, g_ctlHkState, g_ctlHkPreview, g_ctlHkHint
    if !g_captureActive
        return
    remaining := Max(0, Ceil((g_captureUntil - DllCall("GetTickCount64", "UInt64")) / 1000))
    g_ctlHkState.Text := "正在录制 · " remaining " 秒"
    g_ctlHkState.SetFont("c2563EB", "Microsoft YaHei UI")
    g_ctlHkPreview.Text := g_captureState.preview
    g_ctlHkHint.Text := g_captureState.message "`n录制期间暂时允许内置输入，切换快捷键暂停。"
}

ShortcutHint(message) {
    global g_ctlHkHint
    if IsObject(g_ctlHkHint)
        g_ctlHkHint.Text := message
}

EndShortcutCapture(message) {
    global core, g_hk, g_captureActive, g_captureHook, g_exiting, g_desiredBlocked
    wasActive := g_captureActive
    g_captureActive := false
    SetTimer(ShortcutCaptureTick, 0)
    if wasActive {
        try g_captureHook.Stop()
        g_captureHook := 0
        if !g_exiting {
            try Hotkey(g_hk, , "On")
            SyncChord()
            SetBlocked(g_desiredBlocked, false, false)
        }
    }
    UpdateGuiHkText()
    ShortcutHint(message)
}

CancelShortcutCapture(ctrl := 0, message := "已取消，原快捷键未修改。", *) {
    global g_captureCandidate
    g_captureCandidate := ""
    EndShortcutCapture(message)
}

SaveCapturedShortcut(*) {
    global g_captureCandidate, g_captureActive
    if (g_captureActive || g_captureCandidate = "")
        return
    try {
        ApplyHotkey(g_captureCandidate)
        g_captureCandidate := ""
        UpdateGuiHkText()
        ShortcutHint("快捷键已保存，下次启动也会保留。")
    } catch as e {
        ShortcutHint("未保存：" e.Message "。请重新录制一个组合。")
    }
}
