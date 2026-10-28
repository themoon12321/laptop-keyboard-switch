class GestureSettings {
    static Defaults() {
        return [
            {source: GetKeySC("x"), target: GetKeySC("z"), mode: "hold", delay: 600},
            {source: 0x34, target: 0x35, mode: "hold", delay: 600},
            {source: GetKeySC("3"), target: GetKeySC("4"), mode: "hold", delay: 600}
        ]
    }
    static Load(path) {
        enabled := IniRead(path, "gestures", "enabled", "0") = "1"
        count := Integer(IniRead(path, "gestures", "count", "0"))
        if (count < 0 || count > 64)
            throw Error("坏键替代规则数量须在 0–64 之间")
        rules := []
        loop count {
            section := "rule" A_Index
            rules.Push({source: GetKeySC(IniRead(path, section, "source")),
                target: GetKeySC(IniRead(path, section, "target")),
                mode: IniRead(path, section, "mode"),
                delay: Integer(IniRead(path, section, "delay"))})
        }
        KeyGestures.Validate(rules)
        return {enabled: enabled, rules: rules}
    }
    static Save(path, rules, enabled) {
        KeyGestures.Validate(rules)
        text := "[gestures]`nenabled=" (enabled ? 1 : 0) "`ncount=" rules.Length "`n"
        for i, rule in rules {
            text .= "`n[rule" i "]`nsource=SC" Format("{:03X}", rule.source)
                . "`ntarget=SC" Format("{:03X}", rule.target) "`nmode=" rule.mode "`ndelay=" rule.delay "`n"
        }
        temporary := path ".tmp"
        try {
            f := FileOpen(temporary, "w", "UTF-16")
            f.Write(text)
            f.Close()
            FileMove(temporary, path, 1)
        } finally {
            try FileDelete(temporary)
        }
    }
    static Name(code) {
        name := GetKeyName("SC" Format("{:03X}", code))
        if (code = 0x34)
            return ". / >"
        if (code = 0x35)
            return "/ / ?"
        return name != "" ? name : "SC" Format("{:03X}", code)
    }
}

class GestureSettingsWindow {
    __New(rules, enabled, onSave) {
        this.rules := rules.Clone()
        this.onSave := onSave
        this.window := Gui(, "坏键替代 · 仅内置键盘")
        g := this.window
        g.SetFont("s10", "Microsoft YaHei UI")
        g.MarginX := 16, g.MarginY := 14
        this.enabled := g.AddCheckBox("xm w600 Checked" (enabled ? 1 : 0), "启用坏键替代（只作用于已识别的内置键盘）")
        g.AddText("xm y+10 w600", "短按保留原键；长按或双击输入目标键。Shift/CapsLock 照常决定大小写。`nCtrl/Alt/Win 组合及连续打字会优先保留原键。Fn 不支持，可选择 F1–F12。")
        this.list := g.AddListView("xm y+12 w600 r8 -Multi", ["原键", "触发方式", "输入目标键", "时间 (毫秒)"])
        for col in [1, 2, 3, 4]
            this.list.ModifyCol(col, 145)
        this.list.OnEvent("ItemSelect", this.Select.Bind(this))
        g.AddText("xm y+12 w120", "原键（如 x）")
        g.AddText("x+10 yp w120", "触发方式")
        g.AddText("x+10 yp w120", "目标键（如 z）")
        g.AddText("x+10 yp w120", "时间（毫秒）")
        this.source := g.AddEdit("xm y+6 w120", "x")
        this.trigger := g.AddDropDownList("x+10 yp w120 Choose1", ["长按", "双击"])
        this.target := g.AddEdit("x+10 yp w120", "z")
        this.delay := g.AddEdit("x+10 yp w120 Number", "600")
        g.AddButton("xm y+12 w190 h32", "添加 / 更新原键规则").OnEvent("Click", this.Upsert.Bind(this))
        g.AddButton("x+12 yp w190 h32", "删除选中规则").OnEvent("Click", this.Delete.Bind(this))
        g.AddButton("x+12 yp w196 h32", "恢复三条示例规则").OnEvent("Click", this.Defaults.Bind(this))
        g.AddText("xm y+12 w600", "三条默认长按规则均为 600 毫秒，双击建议 300 毫秒。`n启用时内置键盘需经过输入处理；外接键盘保持原样。截断内置时替代功能暂停。")
        g.AddButton("xm y+14 w294 h36 Default", "保存并应用").OnEvent("Click", this.Save.Bind(this))
        g.AddButton("x+12 yp w294 h36", "取消").OnEvent("Click", (*) => g.Destroy())
        g.OnEvent("Close", (*) => g.Destroy())
        this.Refresh()
    }
    Show() {
        this.window.Show()
    }
    Refresh() {
        this.list.Delete()
        for rule in this.rules
            this.list.Add(, GestureSettings.Name(rule.source), rule.mode = "hold" ? "长按" : "双击", GestureSettings.Name(rule.target), rule.delay)
    }
    Select(ctrl, row, selected) {
        if (!selected || row < 1 || row > this.rules.Length)
            return
        rule := this.rules[row]
        this.source.Value := "SC" Format("{:03X}", rule.source)
        this.target.Value := "SC" Format("{:03X}", rule.target)
        this.trigger.Choose(rule.mode = "hold" ? 1 : 2)
        this.delay.Value := rule.delay
    }
    Upsert(*) {
        try {
            rule := {source: GetKeySC(Trim(this.source.Value)), target: GetKeySC(Trim(this.target.Value)),
                mode: this.trigger.Value = 1 ? "hold" : "double", delay: Integer(this.delay.Value)}
            rules := this.rules.Clone()
            replaced := false
            for i, old in rules
                if (old.source = rule.source) {
                    rules[i] := rule
                    replaced := true
                    break
                }
            if (!replaced)
                rules.Push(rule)
            if (rules.Length > 64)
                throw Error("最多配置 64 条规则")
            KeyGestures.Validate(rules)
            this.rules := rules
            this.Refresh()
        } catch as e {
            MsgBox(e.Message, "规则未添加", "Icon!")
        }
    }
    Delete(*) {
        row := this.list.GetNext()
        if row {
            this.rules.RemoveAt(row)
            this.Refresh()
        }
    }
    Defaults(*) {
        this.rules := GestureSettings.Defaults()
        this.Refresh()
    }
    Save(*) {
        try {
            if this.onSave.Call(this.rules, this.enabled.Value = 1)
                this.window.Destroy()
        } catch as e {
            MsgBox(e.Message, "设置未保存", "Icon!")
        }
    }
}
