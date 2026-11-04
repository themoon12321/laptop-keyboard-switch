; Shared native Windows UI. All coordinates use AHK's DPI-scaled units.
class AppTheme {
    static Setup(g) {
        g.BackColor := "F3F5F9"
        g.MarginX := 24, g.MarginY := 20
        g.SetFont("s10 c243047 q5", "Microsoft YaHei UI")
    }
    static Text(g, options, text, size := 10, color := "243047", weight := 400) {
        c := g.AddText(options, text)
        c.SetFont("s" size " c" color " w" weight " q5", "Microsoft YaHei UI")
        return c
    }
    static Card(g, x, y, w, h) {
        return g.AddText("x" x " y" y " w" w " h" h " BackgroundFFFFFF", "")
    }
    static Button(g, options, text, callback) {
        c := g.AddButton(options, text)
        c.OnEvent("Click", callback)
        return c
    }
}
