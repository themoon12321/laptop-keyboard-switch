#Requires AutoHotkey v2.0
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
#Include ..\app\Lib\KeyGestures.ahk
#Include ..\app\Lib\GestureSettings.ahk
#Include window-capture.ahk
passed := 0
OnError(TestError)
TestError(e, *) {
    FileAppend("FAIL " e.Message " at " e.File ":" e.Line "`n", "*")
    ExitApp(1)
}
Check(ok, message) {
    global passed
    if !ok
        throw Error("FAIL " message)
    passed++
    FileAppend("PASS " message "`n", "*")
}
owner := GestureSettingsWindow(GestureSettings.Defaults(), true, (*) => false)
owner.window.Show("Hide AutoSize")
Check(owner.source.Type = "Button" && owner.target.Type = "Button", "both key fields are mouse-selectable buttons")
picked := {code: 0}
picker := KeyboardPicker(owner.window, "target", GetKeySC("z"), (code) => picked.code := code)
picker.window.Show("Hide AutoSize")
Check(picker.selected = GetKeySC("z") && picker.confirmButton.Enabled, "current broken key is preselected")
Check(picker.keys.Length >= 104 && picker.buttons.Has(GetKeySC("F12")) && picker.buttons.Has(GetKeySC("NumpadEnter")), "layout contains full keyboard with function and numpad keys")
Check(picker.buttons.Has(GetKeySC("Left")) && picker.buttons.Has(GetKeySC("Delete")) && picker.buttons.Has(0x35), "navigation and slash keys available")
Check(!picker.Choose(GetKeySC("LCtrl")) && !picker.Choose(GetKeySC("NumLock")) && !picker.Choose(0), "modifiers locks and Fn cannot be selected")
Check(picker.selected = GetKeySC("z"), "unsupported selection leaves current choice intact")
picker.Choose(0x35)
Check(picked.code = 0, "key click previews without applying before confirmation")
Check(picker.Confirm() && picked.code = 0x35 && picker.closed, "confirm returns physical slash key without typing")
Check(!picker.Confirm(), "closed picker cannot apply twice")
picker := KeyboardPicker(owner.window, "target", 0, (code) => picked.code := code)
Check(!picker.confirmButton.Enabled && !picker.Confirm(), "empty picker cannot confirm until a key is selected")
picker.Choose(GetKeySC("4"))
picker.Close()
Check(picked.code = 0x35, "cancel discards preview selection")
picker := KeyboardPicker(owner.window, "target", owner.targetCode, (code) => owner.SetKey("target", code))
picker.Choose(GetKeySC("4")), picker.Confirm()
Check(owner.targetCode = GetKeySC("4") && owner.dirty, "broken key selection updates editor draft")
picker := KeyboardPicker(owner.window, "source", owner.sourceCode, (code) => owner.SetKey("source", code))
picker.Choose(GetKeySC("Numpad3")), picker.Confirm()
Check(owner.sourceCode = GetKeySC("Numpad3") && owner.sourceCode != GetKeySC("3"), "numpad and top-row digit codes remain distinct")
Check(owner.CommitEditor() && owner.rules[1].source = GetKeySC("Numpad3") && owner.rules[1].target = GetKeySC("4"), "mouse-selected pair commits without name parsing")
picker := KeyboardPicker(owner.window, "source", 0, (code) => 0)
picker.window.Show("Hide AutoSize")
picker.window.GetClientPos(, , &w, &h)
fits := true
for ctrl in picker.window {
    ctrl.GetPos(&x, &y, &cw, &ch)
    if (x < 0 || y < 0 || x + cw > w || y + ch > h)
        fits := false
}
Check(fits, "full keyboard controls fit within window")
owner.window.Opt("+Disabled")
picker.Close()
Check(!(DllCall("GetWindowLong", "Ptr", owner.window.Hwnd, "Int", -16, "UInt") & 0x08000000), "closing picker restores owner interaction")
if A_Args.Length {
    preview := KeyboardPicker(owner.window, "target", GetKeySC("z"), (*) => 0)
    preview.window.Show("Hide AutoSize")
    CaptureTestWindow(preview.window, A_Args[1])
    preview.Close()
}
owner.picker := KeyboardPicker(owner.window, "target", 0, (code) => 0)
lastPicker := owner.picker
owner.Close()
Check(lastPicker.closed, "closing editor also closes its picker")
FileAppend("TOTAL: " passed " passed`n", "*")
