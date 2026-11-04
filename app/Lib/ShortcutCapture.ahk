; Pure recorder state: no hook, hotkey registration or input synthesis.
class ShortcutCapture {
    __New() {
        this.down := Map()
        this.candidate := ""
        this.preview := "等待按键…"
        this.message := "请按住 Ctrl / Alt / Shift / Win，再按一个键。Esc 取消。"
        this.cancelled := false
    }
    static Modifier(code) {
        return Map(29, "^", 285, "^", 56, "!", 312, "!", 42, "+", 54, "+", 347, "#", 348, "#").Get(code, "")
    }
    Mods() {
        result := ""
        for symbol in ["^", "!", "+", "#"]
            for code, _ in this.down
                if (ShortcutCapture.Modifier(code) = symbol) {
                    result .= symbol
                    break
                }
        return result
    }
    static Pretty(hk) {
        text := ""
        for pair in [["^", "Ctrl"], ["!", "Alt"], ["+", "Shift"], ["#", "Win"]]
            if InStr(hk, pair[1])
                text .= pair[2] " + "
        key := RegExReplace(hk, "[\^!+#]")
        name := key != "" ? GetKeyName(key) : ""
        return RTrim(text (name != "" ? StrUpper(name) : StrUpper(key)), " +")
    }
    Key(code, state) {
        if state {
            if this.down.Has(code)
                return
            this.down[code] := true
            if (code = 1) {
                this.cancelled := true
                return
            }
            mods := this.Mods()
            if (ShortcutCapture.Modifier(code) != "") {
                if (this.candidate = "")
                    this.preview := ShortcutCapture.Pretty(mods) " + …"
                return
            }
            if (this.candidate != "")
                return
            if (mods = "") {
                this.preview := GetKeyName("SC" Format("{:03X}", code))
                this.message := "需要包含至少一个修饰键，请重新按组合键。"
                return
            }
            this.candidate := mods "SC" Format("{:03X}", code)
            this.preview := ShortcutCapture.Pretty(this.candidate)
            this.message := "已识别组合，请松开全部按键。"
        } else {
            if this.down.Has(code)
                this.down.Delete(code)
            if (this.candidate = "")
                this.preview := this.down.Count ? ShortcutCapture.Pretty(this.Mods()) " + …" : "等待按键…"
        }
    }
}
