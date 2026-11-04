ShowGui(*) {
    global g_gui, g_ctlStatus, g_ctlStatusHint, g_ctlHk, g_ctlExempt, g_ctlAuto, g_ctlGestures, g_ctlToggle
    global g_ctlHkState, g_ctlHkPreview, g_ctlHkHint, g_btnHkRecord, g_btnHkSave, g_btnHkCancel
    if !IsObject(g_gui) {
        g_gui := Gui(, "笔记本键盘开关")
        AppTheme.Setup(g_gui)
        g := g_gui
        AppTheme.Text(g, "x24 y18 w420 h34", "笔记本键盘开关", 21, "17233B", 600)
        AppTheme.Text(g, "x486 y28 w130 h22 Right", "个人测试版本", 9, "64748B")
        AppTheme.Text(g, "x24 y60 w592 h22", "管理内置键盘输入，或用其他按键代替坏键。", 10, "64748B")
        AppTheme.Card(g, 24, 100, 592, 98)
        g_ctlStatus := AppTheme.Text(g, "x42 y116 w355 h28 BackgroundFFFFFF", "", 15, "17233B", 600)
        g_ctlStatusHint := AppTheme.Text(g, "x42 y154 w355 h28 BackgroundFFFFFF", "", 9, "64748B")
        g_ctlToggle := AppTheme.Button(g, "x420 y129 w178 h40", "暂停内置输入", (*) => SetBlocked(!core.blocked))
        AppTheme.Card(g, 24, 214, 592, 182)
        AppTheme.Text(g, "x42 y228 w200 h22 BackgroundFFFFFF", "切换快捷键", 11, "17233B", 600)
        g_ctlHkState := AppTheme.Text(g, "x272 y228 w144 h22 Right BackgroundFFFFFF", "", 9, "64748B")
        g_ctlHk := AppTheme.Text(g, "x42 y258 w360 h20 BackgroundFFFFFF", "", 9, "64748B")
        g_ctlHkPreview := AppTheme.Text(g, "x42 y284 w360 h32 BackgroundFFFFFF", "", 17, "2563EB", 600)
        g_ctlHkHint := AppTheme.Text(g, "x42 y330 w360 h52 BackgroundFFFFFF", "点击“录制组合键”开始设置。", 9, "64748B")
        g_btnHkRecord := AppTheme.Button(g, "x440 y238 w158 h34", "录制组合键", CaptureHotkeyFlow)
        g_btnHkSave := AppTheme.Button(g, "x440 y284 w158 h34", "保存快捷键", SaveCapturedShortcut)
        g_btnHkCancel := AppTheme.Button(g, "x440 y330 w158 h34", "取消录制", CancelShortcutCapture)
        AppTheme.Card(g, 24, 412, 592, 82)
        AppTheme.Text(g, "x42 y426 w300 h23 BackgroundFFFFFF", "按键替代", 11, "17233B", 600)
        g_ctlGestures := AppTheme.Text(g, "x42 y458 w365 h22 BackgroundFFFFFF", "", 9, "64748B")
        AppTheme.Button(g, "x440 y436 w158 h34", "管理替代规则", ShowGestureSettings)
        AppTheme.Card(g, 24, 510, 592, 78)
        AppTheme.Text(g, "x42 y522 w210 h22 BackgroundFFFFFF", "暂停时保留的按键", 11, "17233B", 600)
        g_ctlExempt := AppTheme.Text(g, "x42 y550 w250 h26 BackgroundFFFFFF", "", 9, "64748B")
        AppTheme.Button(g, "x318 y540 w132 h32", "选择保留按键", ScanKeysFlow)
        AppTheme.Button(g, "x466 y540 w132 h32", "清空保留列表", ClearExempt)
        g_ctlAuto := g.AddCheckBox("x24 y604 w190 h26 Checked" (IsAutostart() ? 1 : 0), "登录 Windows 后启动")
        g_ctlAuto.OnEvent("Click", OnAutoClick)
        AppTheme.Button(g, "x230 y600 w140 h32", "重新识别设备", ReidentifyFlow)
        AppTheme.Button(g, "x386 y600 w230 h32", "输入异常？停止处理并退出", EmergencyRelease)
        g.OnEvent("Close", ClosePanel)
        g.OnEvent("Escape", ClosePanel)
    }
    UpdateGui()
    g_gui.Show()
}

ClosePanel(*) {
    global g_gui
    CancelShortcutCapture()
    g_gui.Hide()
}

UpdateGui(*) {
    global g_gui, g_ctlStatus, g_ctlStatusHint, core, g_ctlGestures, g_gesturesEnabled, g_gestureRules
    global g_ctlToggle, g_ctlExempt, g_ctlAuto, g_captureActive
    if !IsObject(g_gui)
        return
    if g_captureActive {
        g_ctlStatus.Text := "内置键盘：录制期间正常输入"
        g_ctlStatus.SetFont("c2563EB", "Microsoft YaHei UI")
        g_ctlStatusHint.Text := "录制结束后恢复之前的输入状态。"
    } else if (core.mode = "error") {
        g_ctlStatus.Text := "内置键盘：输入处理异常"
        g_ctlStatus.SetFont("cB42318", "Microsoft YaHei UI")
        g_ctlStatusHint.Text := "请点击下方“停止处理并退出”。"
    } else if (core.ids.Length = 0) {
        g_ctlStatus.Text := "内置键盘：等待识别"
        g_ctlStatus.SetFont("cA16207", "Microsoft YaHei UI")
        g_ctlStatusHint.Text := "可点击“重新识别设备”进行确认。"
    } else if core.blocked {
        g_ctlStatus.Text := "内置键盘：已暂停输入"
        g_ctlStatus.SetFont("cA16207", "Microsoft YaHei UI")
        g_ctlStatusHint.Text := "适合使用外接键盘时避免误触。"
    } else {
        g_ctlStatus.Text := "内置键盘：正常输入"
        g_ctlStatus.SetFont("c15803D", "Microsoft YaHei UI")
        g_ctlStatusHint.Text := "暂停后，可用切换快捷键恢复输入。"
    }
    g_ctlToggle.Text := core.blocked ? "允许内置输入" : "暂停内置输入"
    g_ctlToggle.Enabled := !g_captureActive
    n := ExemptCount()
    g_ctlExempt.Text := n ? "已保留 " n " 个键，暂停时仍可使用。" : "暂停时屏蔽所有普通按键。"
    g_ctlAuto.Value := IsAutostart() ? 1 : 0
    paused := g_gesturesEnabled && (core.blocked || g_captureActive || core.mode = "pass")
    g_ctlGestures.Text := g_gesturesEnabled ? (paused ? "已启用，当前暂停 · " : "已启用 · ") g_gestureRules.Length " 条规则" : "未启用 · 可自定义按键和触发时间"
    UpdateGuiHkText()
}

UpdateGuiHkText(*) {
    global g_gui, g_ctlHk, g_hk, g_captureActive, g_captureCandidate
    global g_ctlHkState, g_ctlHkPreview, g_btnHkRecord, g_btnHkSave, g_btnHkCancel
    if !IsObject(g_gui)
        return
    g_ctlHk.Text := "当前生效：" HotkeyPretty(g_hk)
    g_btnHkRecord.Enabled := !g_captureActive
    g_btnHkSave.Enabled := !g_captureActive && g_captureCandidate != ""
    g_btnHkCancel.Enabled := g_captureActive || g_captureCandidate != ""
    if g_captureActive {
        RenderShortcutCapture()
        return
    }
    g_ctlHkState.Text := g_captureCandidate != "" ? "待保存" : "未在录制"
    g_ctlHkState.SetFont("c64748B", "Microsoft YaHei UI")
    g_ctlHkPreview.Text := g_captureCandidate != "" ? HotkeyPretty(g_captureCandidate) : HotkeyPretty(g_hk)
}

OnAutoClick(*) {
    if IsAutostart()
        RemoveAutostart()
    else
        SetAutostart()
    UpdateGui()
}
