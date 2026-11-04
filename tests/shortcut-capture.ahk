#Requires AutoHotkey v2.0
#Warn All, StdOut
#Include ..\app\Lib\ShortcutCapture.ahk
passed := 0
Check(ok, message) {
    global passed
    if !ok
        throw Error("FAIL " message)
    passed++
    FileAppend("PASS " message "`n", "*")
}
s := ShortcutCapture()
s.Key(29, 1)
Check(s.preview = "Ctrl + …" && s.candidate = "", "modifier preview appears before main key")
s.Key(42, 1), s.Key(45, 1)
Check(s.candidate = "^+SC02D" && s.preview = "Ctrl + Shift + X", "chord captures modifiers at keydown")
s.Key(45, 1), s.Key(46, 1)
Check(s.candidate = "^+SC02D", "repeat or additional keys cannot overwrite captured chord")
s.Key(29, 0), s.Key(42, 0), s.Key(45, 0), s.Key(46, 0)
Check(s.down.Count = 0 && s.candidate = "^+SC02D", "fast release does not lose captured modifiers")
s := ShortcutCapture()
s.Key(45, 1), s.Key(45, 0)
Check(s.candidate = "" && InStr(s.message, "修饰键"), "single key rejected with inline explanation")
s.Key(312, 1), s.Key(45, 1)
Check(s.candidate = "!SC02D", "retry after rejected single key succeeds")
s := ShortcutCapture()
s.Key(29, 1), s.Key(285, 1), s.Key(29, 0), s.Key(45, 1)
Check(s.candidate = "^SC02D", "both Ctrl keys remain independently tracked")
s := ShortcutCapture()
s.Key(347, 1), s.Key(33, 1)
Check(s.candidate = "#SC021", "Win combinations supported")
s.Key(1, 1)
Check(s.cancelled, "Escape cancels recording")
Check(ShortcutCapture.Pretty("^!k") = "Ctrl + Alt + K", "old configured shortcut names remain readable")
FileAppend("TOTAL: " passed " passed`n", "*")
