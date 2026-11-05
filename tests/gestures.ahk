#Requires AutoHotkey v2.0
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
#SingleInstance Off
#Include ..\app\Lib\KeyGestures.ahk
#Include ..\app\Lib\GestureSettings.ahk
global passed := 0, failed := 0
class Fixture {
    __New(rules) {
        this.now := 0
        this.events := []
        this.g := KeyGestures((id, code, state) => this.events.Push(id ":" code ":" state), () => this.now)
        this.g.SetRules(rules)
    }
    Stroke(code, state, at, id := 1, shortcut := false) {
        this.now := at
        this.g.Stroke(id, code, state, shortcut)
    }
    Tick(at) {
        this.now := at
        this.g.Tick()
    }
    Output() {
        text := ""
        for event in this.events
            text .= (text = "" ? "" : ",") event
        return text
    }
}
Check(condition, name) {
    global passed, failed
    if condition
        passed++
    else
        failed++
    FileAppend((condition ? "PASS " : "FAIL ") name "`n", "*")
}
Hold() {
    return [{source: 45, target: 44, mode: "hold", delay: 600}]
}
f := Fixture(Hold())
f.Stroke(45, 1, 0), f.Stroke(45, 0, 100)
Check(f.Output() = "1:45:1,1:45:0", "short X preserves X")
f := Fixture(Hold())
f.Stroke(45, 1, 0), f.Tick(599)
Check(f.events.Length = 0, "hold threshold has no early output")
f.Tick(600), f.Tick(5000), f.Stroke(45, 1, 5100), f.Stroke(45, 0, 5200)
Check(f.Output() = "1:44:1,1:44:0", "long X emits one Z without X or repeats")
f := Fixture(Hold())
f.Stroke(45, 1, 0), f.Stroke(30, 1, 40), f.Stroke(45, 0, 60), f.Stroke(30, 0, 90)
Check(f.Output() = "1:45:1,1:30:1,1:45:0,1:30:0", "overlapping typing preserves event order")
f := Fixture(Hold())
f.Stroke(29, 1, 0), f.Stroke(45, 1, 10), f.Tick(1000), f.Stroke(45, 0, 1010), f.Stroke(29, 0, 1020)
Check(f.Output() = "1:29:1,1:45:1,1:45:0,1:29:0", "Ctrl+X remains a shortcut")
f := Fixture(Hold())
f.Stroke(45, 1, 0), f.Stroke(29, 1, 10), f.Stroke(45, 0, 20)
Check(f.Output() = "1:45:1,1:29:1,1:45:0", "modifier interruption cancels remap")
f := Fixture(Hold())
f.Stroke(45, 1, 0, 1, true), f.Tick(1000), f.Stroke(45, 0, 1100)
Check(f.Output() = "1:45:1,1:45:0", "external Ctrl modifier bypasses gesture")
f := Fixture([{source: 52, target: 53, mode: "hold", delay: 600}])
f.Stroke(42, 1, 0), f.Stroke(52, 1, 10), f.Tick(610), f.Stroke(52, 0, 620), f.Stroke(42, 0, 630)
Check(f.Output() = "1:42:1,1:53:1,1:53:0,1:42:0", "Shift stays held around slash target for question mark")
f := Fixture([{source: 4, target: 5, mode: "hold", delay: 600}])
f.Stroke(4, 1, 0), f.Tick(599)
Check(f.events.Length = 0, "3 to 4 waits full 600 milliseconds")
f.Tick(600), f.Stroke(4, 0, 610)
Check(f.Output() = "1:5:1,1:5:0", "3 held 600 milliseconds produces 4")
doubleRule := [{source: 45, target: 44, mode: "double", delay: 300}]
f := Fixture(doubleRule)
f.Stroke(45, 1, 0), f.Stroke(45, 0, 40), f.Tick(339)
Check(f.events.Length = 0, "single tap waits for double-tap window")
f.Tick(340)
Check(f.Output() = "1:45:1,1:45:0", "expired single tap preserves source")
f := Fixture(doubleRule)
f.Stroke(45, 1, 0), f.Stroke(45, 0, 40), f.Stroke(45, 1, 150), f.Stroke(45, 0, 200), f.Tick(1000)
Check(f.Output() = "1:44:1,1:44:0", "double tap emits target once")
f := Fixture(doubleRule)
f.Stroke(45, 1, 0), f.Stroke(45, 0, 20), f.Stroke(30, 1, 40)
Check(f.Output() = "1:45:1,1:45:0,1:30:1", "single tap flushed before unrelated key")
f := Fixture(doubleRule)
f.Stroke(45, 1, 0), f.Tick(300), f.Stroke(45, 1, 400), f.Stroke(45, 0, 500)
Check(f.Output() = "1:45:1,1:45:1,1:45:0", "held double-tap source keeps ordinary repeats")
f := Fixture(Hold())
f.Stroke(45, 1, 0, 1), f.Stroke(45, 1, 100, 2), f.Tick(600)
Check(f.Output() = "1:44:1,1:44:0", "gesture timers are isolated per device")
f.g.Cancel(), f.Tick(5000)
Check(f.events.Length = 2, "cancel discards deferred characters")
f := Fixture(Hold())
f.Stroke(45, 1, 0), f.Stroke(30, 1, 10), f.g.Cancel()
Check(f.Output() = "1:45:1,1:30:1,1:45:0", "cancel releases an emitted held source")
invalid := 0
for rule in [ {source: 0, target: 44, mode: "hold", delay: 600},
    {source: 45, target: 45, mode: "hold", delay: 600},
    {source: 29, target: 44, mode: "hold", delay: 600},
    {source: 45, target: 44, mode: "hold", delay: 0} ] {
    try KeyGestures.Validate([rule])
    catch
        invalid++
}
Check(invalid = 4, "invalid, Fn, same-key and modifier rules rejected")
temporary := A_Temp "\kb-gesture-test-" ProcessExist() ".ini"
try {
    GestureSettings.Save(temporary, GestureSettings.Defaults(), true)
    loaded := GestureSettings.Load(temporary)
    Check(loaded.enabled && loaded.rules.Length = 3 && loaded.rules[3].delay = 600, "settings round-trip preserves defaults")
} finally {
    try FileDelete(temporary)
}
; Construct hidden GUI; never show a window or install an input hook.
dialog := GestureSettingsWindow(GestureSettings.Defaults(), true, (*) => false)
dialog.window.Show("Hide AutoSize")
Check(dialog.list.GetCount() = 3 && dialog.enabled.Value = 1, "settings panel builds with all three rules")
dialog.delay.Value := "450"
dialog.Changed()
Check(dialog.CommitEditor() && dialog.rules[1].delay = 450, "time edit commits without separate update button")
dialog.SetKey("source", GetKeySC("v"))
dialog.SetKey("target", GetKeySC("b"))
Check(dialog.CommitEditor() && dialog.rules.Length = 3 && dialog.rules[1].source = GetKeySC("v"), "editing source replaces selected rule rather than adding duplicate")
dialog.NewRule()
dialog.SetKey("source", GetKeySC("a")), dialog.SetKey("target", GetKeySC("s")), dialog.delay.Value := "750"
dialog.Changed()
Check(dialog.CommitEditor() && dialog.rules.Length = 4 && dialog.rules[4].delay = 750, "new rule accepts custom time")
dialog.delay.Value := "0"
dialog.Changed()
Check(!dialog.CommitEditor() && dialog.rules[4].delay = 750 && InStr(dialog.feedback.Text, "未保存"), "invalid time keeps original rule and displays inline error")
dialog.delay.Value := "900", dialog.Changed()
dialog.Select(dialog.list, 2, true)
Check(dialog.rules[4].delay = 900 && dialog.editing = 2, "changing selection retains pending time edit")
dialog.Delete()
Check(dialog.rules.Length = 3, "delete is local until save")
saved := {rules: []}
dialog.onSave := (rules, enabled) => StoreSavedRules(saved, rules)
dialog.delay.Value := "800", dialog.Changed()
dialog.Save()
Check(saved.rules.Length = 3 && saved.rules[dialog.editing].delay = 800, "Save directly includes editor value")
StoreSavedRules(holder, rules) {
    holder.rules := rules.Clone()
    return false
}
dialog.window.GetClientPos(, , &w, &h)
fits := true
for ctrl in dialog.window {
    ctrl.GetPos(&x, &y, &cw, &ch)
    if (x < 0 || y < 0 || x + cw > w || y + ch > h)
        fits := false
}
Check(fits, "all replacement controls stay within the window")
dialog.window.Destroy()
FileAppend("TOTAL: " passed " passed, " failed " failed`n", "*")
ExitApp(failed ? 1 : 0)
