#Include %A_LineFile%\..\AppTheme.ahk
; Mouse-only key selection. Never hooks, presses or sends a physical key.
class KeyboardPicker {
    static Supported(code) {
        if (!code || code = GetKeySC("NumLock"))
            return false
        try {
            KeyGestures.Validate([{source: code, target: code = 45 ? 44 : 45, mode: "hold", delay: 600}])
            return true
        } catch {
            return false
        }
    }
    static Key(label, name, units := 1) {
        return {label: label, name: name, code: name = "Fn" ? 0 : GetKeySC(name), units: units}
    }
    static Row(keys, x, y, specs) {
        for spec in specs {
            spec.x := x, spec.y := y
            spec.w := Round(spec.units * 36) - 4, spec.h := 32
            keys.Push(spec)
            x += spec.units * 36
        }
    }
    static Layout() {
        keys := []
        k := KeyboardPicker.Key.Bind(KeyboardPicker)
        KeyboardPicker.Row(keys, 24, 108, [k("Esc", "Esc")])
        for group in [0, 1, 2] {
            row := []
            loop 4 {
                number := group * 4 + A_Index
                row.Push(k("F" number, "F" number))
            }
            KeyboardPicker.Row(keys, 96 + group * 162, 108, row)
        }
        KeyboardPicker.Row(keys, 578, 108, [k("截屏", "PrintScreen"), k("滚锁", "ScrollLock"), k("暂停", "Pause")])
        row := [k("~", "SC029")]
        for label in ["1 !", "2 @", "3 #", "4 $", "5 %", "6 ^", "7 &", "8 *", "9 (", "0 )"]
            row.Push(k(label, SubStr(label, 1, 1)))
        row.Push(k("- _", "SC00C"), k("= +", "SC00D"), k("退格", "Backspace", 2))
        KeyboardPicker.Row(keys, 24, 160, row)
        row := [k("Tab", "Tab", 1.5)]
        for letter in StrSplit("QWERTYUIOP")
            row.Push(k(letter, letter))
        row.Push(k("[ {", "SC01A"), k("] }", "SC01B"), k("\ |", "SC02B", 1.5))
        KeyboardPicker.Row(keys, 24, 200, row)
        row := [k("Caps", "CapsLock", 1.75)]
        for letter in StrSplit("ASDFGHJKL")
            row.Push(k(letter, letter))
        row.Push(k("; :", "SC027"), k("引号", "SC028"), k("Enter", "Enter", 2.25))
        KeyboardPicker.Row(keys, 24, 240, row)
        row := [k("Shift", "LShift", 2.25)]
        for letter in StrSplit("ZXCVBNM")
            row.Push(k(letter, letter))
        row.Push(k(", <", "SC033"), k(". >", "SC034"), k("/ ?", "SC035"), k("Shift", "RShift", 2.75))
        KeyboardPicker.Row(keys, 24, 280, row)
        KeyboardPicker.Row(keys, 24, 320, [k("Ctrl", "LCtrl", 1.25), k("Win", "LWin", 1.25), k("Alt", "LAlt", 1.25),
            k("空格", "Space", 6.25), k("Alt", "RAlt", 1.25), k("Win", "RWin", 1.25), k("菜单", "AppsKey", 1.25), k("Ctrl", "RCtrl", 1.25)])
        KeyboardPicker.Row(keys, 578, 160, [k("Ins", "Insert"), k("起始", "Home"), k("PgUp", "PgUp")])
        KeyboardPicker.Row(keys, 578, 200, [k("Del", "Delete"), k("End", "End"), k("PgDn", "PgDn")])
        KeyboardPicker.Row(keys, 614, 280, [k("↑", "Up")])
        KeyboardPicker.Row(keys, 578, 320, [k("←", "Left"), k("↓", "Down"), k("→", "Right")])
        KeyboardPicker.Row(keys, 700, 108, [k("音量−", "Volume_Down", 4/3), k("音量+", "Volume_Up", 4/3), k("静音", "Volume_Mute", 4/3)])
        KeyboardPicker.Row(keys, 700, 160, [k("Num", "NumLock"), k("/", "NumpadDiv"), k("*", "NumpadMult"), k("−", "NumpadSub")])
        KeyboardPicker.Row(keys, 700, 200, [k("7", "Numpad7"), k("8", "Numpad8"), k("9", "Numpad9"), k("+", "NumpadAdd")])
        keys[keys.Length].h := 72
        KeyboardPicker.Row(keys, 700, 240, [k("4", "Numpad4"), k("5", "Numpad5"), k("6", "Numpad6")])
        KeyboardPicker.Row(keys, 700, 280, [k("1", "Numpad1"), k("2", "Numpad2"), k("3", "Numpad3"), k("Enter", "NumpadEnter")])
        keys[keys.Length].h := 72
        KeyboardPicker.Row(keys, 700, 320, [k("0", "Numpad0", 2), k(".", "NumpadDot")])
        KeyboardPicker.Row(keys, 792, 376, [k("Fn", "Fn", 1.5)])
        return keys
    }
    __New(owner, role, current, onPick) {
        this.owner := owner, this.onPick := onPick
        this.selected := 0, this.closed := false
        this.buttons := Map(), this.keys := KeyboardPicker.Layout()
        title := role = "source" ? "选择代替键" : "选择坏键"
        this.window := Gui("+Owner" owner.Hwnd, title)
        g := this.window
        AppTheme.Setup(g)
        AppTheme.Text(g, "x24 y18 w820 h32", title, 20, "17233B", 600)
        explanation := role = "source" ? "选择能正常使用的键；以后长按或双击它，就能输入坏键。" : "选择需要代替的坏键，无需实际按下它。"
        AppTheme.Text(g, "x24 y62 w820 h24", explanation, 10, "64748B")
        for spec in this.keys {
            button := g.AddButton("x" Round(spec.x) " y" spec.y " w" spec.w " h" spec.h, StrReplace(spec.label, "&", "&&"))
            button.SetFont("s8 w400", "Microsoft YaHei UI")
            if KeyboardPicker.Supported(spec.code) {
                if this.buttons.Has(spec.code)
                    throw Error("键盘布局中出现重复键位")
                this.buttons[spec.code] := button
                button.OnEvent("Click", this.Choose.Bind(this, spec.code))
            } else {
                button.Enabled := false
            }
        }
        AppTheme.Text(g, "x24 y378 w740 h28", "点击键帽选择，再点击确认。灰色按键暂不支持（修饰键、锁定键、Fn 等）。", 9, "64748B")
        AppTheme.Text(g, "x24 y406 w820 h18", "符号按实际键位选择，例如 / 和 ? 共用一键；Shift、NumLock 照常决定输入结果。", 9, "64748B")
        this.summary := AppTheme.Text(g, "x24 y430 w520 h30", "尚未选择按键", 13, "2563EB", 600)
        AppTheme.Button(g, "x578 y426 w120 h36", "取消", this.Close.Bind(this))
        this.confirmButton := AppTheme.Button(g, "x714 y426 w130 h36 Default Disabled", "确认选择", this.Confirm.Bind(this))
        g.OnEvent("Close", this.Close.Bind(this))
        g.OnEvent("Escape", this.Close.Bind(this))
        this.Choose(current)
    }
    Show() {
        this.owner.Opt("+Disabled")
        try this.window.Show("w868 h486")
        catch as e {
            this.Close()
            throw e
        }
    }
    Choose(code, *) {
        if (this.closed || !this.buttons.Has(code))
            return false
        if this.buttons.Has(this.selected)
            this.buttons[this.selected].SetFont("w400", "Microsoft YaHei UI")
        this.selected := code
        this.buttons[code].SetFont("w700", "Microsoft YaHei UI")
        this.summary.Text := "已选择：" GestureSettings.Name(code)
        this.confirmButton.Enabled := true
        return true
    }
    Confirm(*) {
        if (this.closed || !this.buttons.Has(this.selected))
            return false
        this.onPick.Call(this.selected)
        this.Close()
        return true
    }
    Close(*) {
        if this.closed
            return
        wasActive := WinActive("ahk_id " this.window.Hwnd)
        this.closed := true
        this.window.Destroy()
        try this.owner.Opt("-Disabled")
        if wasActive
            try WinActivate("ahk_id " this.owner.Hwnd)
    }
}
