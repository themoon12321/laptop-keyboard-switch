; Render our own hidden test windows into BMP; never captures the desktop.
CaptureTestWindow(g, path) {
    ; Give native controls a paint pass outside the desktop, without activation.
    g.Show("x-30000 y-30000 NoActivate")
    Sleep 60
    g.GetClientPos(, , &width, &height)
    scale := A_ScreenDPI / 96
    width := Round(width * scale), height := Round(height * scale)
    dc := DllCall("GetDC", "Ptr", g.Hwnd, "Ptr")
    memory := DllCall("CreateCompatibleDC", "Ptr", dc, "Ptr")
    info := Buffer(40, 0)
    NumPut("UInt", 40, "Int", width, "Int", -height, "UShort", 1, "UShort", 32, info)
    bitmap := DllCall("CreateDIBSection", "Ptr", dc, "Ptr", info, "UInt", 0, "Ptr*", &bits := 0, "Ptr", 0, "UInt", 0, "Ptr")
    old := DllCall("SelectObject", "Ptr", memory, "Ptr", bitmap, "Ptr")
    try {
        if !DllCall("PrintWindow", "Ptr", g.Hwnd, "Ptr", memory, "UInt", 3)
            throw Error("Could not render test window")
        header := Buffer(54, 0)
        NumPut("UShort", 0x4D42, header)
        NumPut("UInt", 54 + width * height * 4, header, 2)
        NumPut("UInt", 54, header, 10)
        DllCall("RtlMoveMemory", "Ptr", header.Ptr + 14, "Ptr", info, "UPtr", 40)
        file := FileOpen(path, "w")
        file.RawWrite(header)
        file.RawWrite(bits, width * height * 4)
        file.Close()
    } finally {
        DllCall("SelectObject", "Ptr", memory, "Ptr", old)
        DllCall("DeleteObject", "Ptr", bitmap)
        DllCall("DeleteDC", "Ptr", memory)
        DllCall("ReleaseDC", "Ptr", g.Hwnd, "Ptr", dc)
        g.Hide()
    }
}
