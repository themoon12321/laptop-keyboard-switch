; =====================================================================
;  键盘测试器 v2 (可视化 + 文件日志) —— 只监听, 绝不拦截
;  每次按键实时显示在窗口, 同时追加写入 tools\keylog.txt
; =====================================================================
#Requires AutoHotkey v2.0
#SingleInstance Off
Persistent

global gCount := 0
global gCtlBig := 0
global gCtlCount := 0
global gCtlList := 0
global gRecent := []
global gLogFile := A_ScriptDir "\keylog.txt"

g := Gui("+AlwaysOnTop", "键盘测试器 — 按任意键试试")
g.SetFont("s10")
g.MarginX := 16
g.MarginY := 14

g.SetFont("s9")
g.AddText("w420", "按任意键盘的任意键。数字变化 = 按键到达了系统。")
g.AddText("w420 cGray", "本窗口只监听，不拦截不修改输入。日志: tools\keylog.txt")

g.SetFont("s36 w700")
gCtlBig := g.AddText("w420 h70 Center", "—")

g.SetFont("s11")
gCtlCount := g.AddText("w420 Center", "已捕获 0 次按键")

g.SetFont("s9")
g.AddText("w420 y+10", "最近按键:")
gCtlList := g.AddEdit("w420 r8 ReadOnly -VScroll", "")

g.SetFont("s9")
g.AddButton("w200 h30 y+10", "清零").OnEvent("Click", ResetCount)
g.AddButton("w208 h30 x+12", "关闭").OnEvent("Click", (*) => ExitApp())
g.OnEvent("Close", (*) => ExitApp())

g.Show()

try FileDelete(gLogFile)
LogLine("=== 测试器启动 " FormatTime(, "yyyy-MM-dd HH:mm:ss") " ===")

ih := InputHook("T3600")
ih.KeyOpt("{All}", "N")
ih.OnKeyDown := OnDown
ih.OnKeyUp := OnUp
ih.Start()
return

LogLine(s) {
    global gLogFile
    try FileAppend(s "`n", gLogFile, "UTF-8")
}

OnDown(hook, vk, sc) {
    global gCount, gCtlBig, gCtlCount, gCtlList, gRecent
    gCount++
    name := ""
    try name := GetKeyName(Format("vk{:X}", vk))
    if (name = "")
        name := Format("vk=0x{:X}", vk)

    mods := ""
    mods .= GetKeyState("LCtrl", "P") || GetKeyState("RCtrl", "P") ? "Ctrl+" : ""
    mods .= GetKeyState("LAlt", "P") || GetKeyState("RAlt", "P") ? "Alt+" : ""
    mods .= GetKeyState("LShift", "P") || GetKeyState("RShift", "P") ? "Shift+" : ""
    mods .= GetKeyState("LWin", "P") || GetKeyState("RWin", "P") ? "Win+" : ""

    gCtlBig.Text := name
    gCtlCount.Text := "已捕获 " gCount " 次按键"

    line := FormatTime(, "HH:mm:ss") "  " mods name "   (vk=" vk " sc=" sc ")"
    gRecent.InsertAt(1, line)
    if (gRecent.Length > 12)
        gRecent.Pop()
    txt := ""
    for l in gRecent
        txt .= l "`r`n"
    gCtlList.Value := txt
    LogLine(line)
}

OnUp(hook, vk, sc) {
}

ResetCount(*) {
    global gCount, gCtlBig, gCtlCount, gCtlList, gRecent
    gCount := 0
    gRecent := []
    gCtlBig.Text := "—"
    gCtlCount.Text := "已捕获 0 次按键"
    gCtlList.Value := ""
}
