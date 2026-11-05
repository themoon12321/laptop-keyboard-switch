#Include %A_LineFile%\..\AppTheme.ahk
#Include %A_LineFile%\..\KeyboardPicker.ahk
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
            return "句号 / >"
        if (code = 0x35)
            return "斜杠 / ?"
        return name != "" ? name : "SC" Format("{:03X}", code)
    }
}

class GestureSettingsWindow {
    __New(rules, enabled, onSave) {
        this.rules := rules.Clone(), this.onSave := onSave
        this.editing := 0, this.dirty := false, this.loading := true
        this.sourceCode := 0, this.targetCode := 0, this.picker := 0
        this.window := Gui(, "按键替代设置")
        g := this.window
        AppTheme.Setup(g)
        AppTheme.Text(g, "x24 y18 w580 h34", "按键替代", 20, "17233B", 600)
        AppTheme.Text(g, "x24 y60 w580 h24", "用好用的按键代替坏键，只对内置键盘生效。", 10, "64748B")
        AppTheme.Card(g, 24, 100, 592, 58)
        this.enabled := g.AddCheckBox("x42 y118 w550 h24 BackgroundFFFFFF Checked" (enabled ? 1 : 0), "启用按键替代")
        this.list := g.AddListView("x24 y176 w592 h126 -Multi", ["代替键", "操作", "坏键（输入）", "时间（毫秒）"])
        for col in [1, 2, 3, 4]
            this.list.ModifyCol(col, col = 4 ? 140 : 144)
        this.list.OnEvent("ItemSelect", this.Select.Bind(this))
        AppTheme.Button(g, "x24 y312 w120 h32", "添加规则", this.NewRule.Bind(this))
        this.deleteButton := AppTheme.Button(g, "x154 y312 w120 h32", "删除规则", this.Delete.Bind(this))
        AppTheme.Card(g, 24, 360, 592, 152)
        this.editorTitle := AppTheme.Text(g, "x42 y374 w530 h24 BackgroundFFFFFF", "编辑规则", 11, "17233B", 600)
        AppTheme.Text(g, "x42 y408 w118 h20 BackgroundFFFFFF", "代替键（用来触发）", 9, "64748B")
        AppTheme.Text(g, "x180 y408 w112 h20 BackgroundFFFFFF", "操作", 9, "64748B")
        AppTheme.Text(g, "x312 y408 w118 h20 BackgroundFFFFFF", "坏键（要输入的键）", 9, "64748B")
        this.timeLabel := AppTheme.Text(g, "x450 y408 w150 h20 BackgroundFFFFFF", "长按时长（毫秒）", 9, "64748B")
        this.source := AppTheme.Button(g, "x42 y434 w118 h30", "选择代替键…", this.OpenPicker.Bind(this, "source"))
        this.trigger := g.AddDropDownList("x180 y434 w112 Choose1", ["长按", "双击"])
        this.target := AppTheme.Button(g, "x312 y434 w118 h30", "选择坏键…", this.OpenPicker.Bind(this, "target"))
        this.delay := g.AddEdit("x450 y434 w146 h28 Number", "600")
        g.AddUpDown("Range150-10000", 600)
        this.duration := AppTheme.Text(g, "x42 y478 w554 h22 BackgroundFFFFFF", "", 9, "64748B")
        this.feedback := AppTheme.Text(g, "x24 y528 w592 h40", "", 9, "64748B")
        AppTheme.Button(g, "x320 y580 w140 h36 Default", "保存并应用", this.Save.Bind(this))
        AppTheme.Button(g, "x476 y580 w140 h36", "取消", this.Close.Bind(this))
        AppTheme.Text(g, "x24 y580 w278 h36", "短按保留原键。快捷键优先保留原操作。", 9, "64748B")
        for ctrl in [this.trigger, this.delay]
            ctrl.OnEvent("Change", this.Changed.Bind(this))
        this.enabled.OnEvent("Click", (*) => this.Hint("开关修改将在保存后生效。"))
        g.OnEvent("Close", this.Close.Bind(this))
        g.OnEvent("Escape", this.Close.Bind(this))
        this.loading := false
        this.Refresh(this.rules.Length ? 1 : 0)
    }
    Show() {
        this.window.Show("w640 h638")
    }
    Hint(text, error := false) {
        this.feedback.Text := text
        this.feedback.SetFont(error ? "cB42318" : "c64748B", "Microsoft YaHei UI")
    }
    Changed(*) {
        if this.loading
            return
        this.dirty := true
        this.Describe()
        this.Hint("有未保存的修改；点击“保存并应用”即可生效。")
    }
    Describe() {
        this.timeLabel.Text := this.trigger.Value = 1 ? "长按时长（毫秒）" : "双击间隔（毫秒）"
        try seconds := Format("{:.2f}", Integer(this.delay.Value) / 1000)
        catch
            seconds := "—"
        this.duration.Text := "当前时间：" seconds " 秒 · 可输入 150–10000 毫秒。点击按键按钮，用鼠标选择。"
    }
    LoadRow(row) {
        this.loading := true
        this.editing := row
        if row {
            rule := this.rules[row]
            this.sourceCode := rule.source, this.targetCode := rule.target
            this.trigger.Choose(rule.mode = "hold" ? 1 : 2)
            this.delay.Value := rule.delay
            this.editorTitle.Text := "编辑规则 · " GestureSettings.Name(rule.source) " → " GestureSettings.Name(rule.target)
        } else {
            this.sourceCode := 0, this.targetCode := 0
            this.trigger.Choose(1), this.delay.Value := "600"
            this.editorTitle.Text := "新规则"
        }
        this.deleteButton.Enabled := row > 0
        this.dirty := false, this.loading := false
        this.UpdateKeyButtons()
        this.Describe()
    }
    Refresh(row := 0) {
        this.loading := true
        this.list.Delete()
        for rule in this.rules
            this.list.Add(, GestureSettings.Name(rule.source), rule.mode = "hold" ? "长按" : "双击", GestureSettings.Name(rule.target), rule.delay)
        if row
            this.list.Modify(row, "Select Focus Vis")
        this.loading := false
        this.LoadRow(row)
        this.Hint(this.rules.Length ? "选中规则即可修改按键和时间，保存后生效。" : "暂无规则。点击按钮选择代替键和坏键，设置时间后保存。")
    }
    Select(ctrl, row, selected) {
        if (this.loading || !selected || row < 1 || row > this.rules.Length || row = this.editing)
            return
        if (this.dirty && !this.CommitEditor()) {
            this.loading := true
            this.list.Modify(row, "-Select")
            if this.editing
                this.list.Modify(this.editing, "Select Focus")
            this.loading := false
            return
        }
        this.LoadRow(row)
    }
    CommitEditor() {
        if !this.dirty
            return true
        try {
            if (!this.sourceCode || !this.targetCode)
                throw Error("请先选择代替键和坏键。")
            rule := {source: this.sourceCode, target: this.targetCode,
                mode: this.trigger.Value = 1 ? "hold" : "double", delay: Integer(this.delay.Value)}
            rules := this.rules.Clone()
            if this.editing
                rules[this.editing] := rule
            else
                rules.Push(rule)
            if (rules.Length > 64)
                throw Error("最多配置 64 条规则。")
            KeyGestures.Validate(rules)
            this.rules := rules
            if !this.editing
                this.editing := rules.Length
            this.dirty := false
            this.loading := true
            if (this.list.GetCount() < this.rules.Length)
                this.list.Add(, GestureSettings.Name(rule.source), rule.mode = "hold" ? "长按" : "双击", GestureSettings.Name(rule.target), rule.delay)
            else
                this.list.Modify(this.editing, , GestureSettings.Name(rule.source), rule.mode = "hold" ? "长按" : "双击", GestureSettings.Name(rule.target), rule.delay)
            this.loading := false
            return true
        } catch as e {
            this.loading := false
            this.Hint("未保存：" e.Message, true)
            return false
        }
    }
    NewRule(*) {
        if !this.CommitEditor()
            return
        this.loading := true
        this.list.Modify(0, "-Select")
        this.loading := false
        this.LoadRow(0)
        this.source.Focus()
        this.Hint("用鼠标选择代替键和坏键，完成后直接保存；再次添加可继续编辑下一条。")
    }
    Delete(*) {
        if this.editing {
            row := this.editing
            this.rules.RemoveAt(row)
            this.dirty := false
            this.Refresh(this.rules.Length ? Min(row, this.rules.Length) : 0)
            this.Hint("规则已移除，点击保存后生效。")
        }
    }
    Save(*) {
        if !this.CommitEditor()
            return
        try {
            if this.onSave.Call(this.rules, this.enabled.Value = 1)
                this.Close()
        } catch as e {
            this.Hint("未保存：" e.Message, true)
        }
    }
    UpdateKeyButtons() {
        this.source.Text := this.sourceCode ? GestureSettings.Name(this.sourceCode) " …" : "选择代替键…"
        this.target.Text := this.targetCode ? GestureSettings.Name(this.targetCode) " …" : "选择坏键…"
    }
    SetKey(role, code) {
        if (!KeyboardPicker.Supported(code) || (role != "source" && role != "target"))
            return false
        if (role = "source")
            this.sourceCode := code
        else
            this.targetCode := code
        this.UpdateKeyButtons()
        this.Changed()
        return true
    }
    OpenPicker(role, *) {
        if (IsObject(this.picker) && !this.picker.closed) {
            this.picker.Show()
            return
        }
        current := role = "source" ? this.sourceCode : this.targetCode
        this.picker := KeyboardPicker(this.window, role, current, (code) => this.SetKey(role, code))
        this.picker.Show()
    }
    Close(*) {
        if (IsObject(this.picker) && !this.picker.closed)
            this.picker.Close()
        this.window.Destroy()
    }
}
