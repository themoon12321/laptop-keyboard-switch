; AutoHotInterception 桩 (干跑测试专用)
; 覆盖 app\Lib\AutoHotInterception.ahk 后运行守护进程,
; 不触碰任何真实输入设备, 只记录调用
class AutoHotInterception {
    static Calls := []
    __New() {
        this._subs := Map()
        this._sent := []
        this._devs := Map()
        ; 内置 PS/2 键盘 (命中启发式)
        this._devs[1] := {id: 1, vid: 0, pid: 0, IsMouse: false, Handle: "ACPI\VEN_MSFT&DEV_0001"}
        ; 外接 USB 键盘 (不应被选中)
        this._devs[2] := {id: 2, vid: 0x32C2, pid: 0x0018, IsMouse: false, Handle: "USB\VID_32C2&PID_0018"}
    }
    GetDeviceList() {
        return this._devs
    }
    SubscribeKeyboard(id, block, cb) {
        this._subs[id] := cb
        AutoHotInterception.Calls.Push("subkb:" id)
    }
    UnsubscribeKeyboard(id) {
        if this._subs.Has(id)
            this._subs.Delete(id)
        AutoHotInterception.Calls.Push("unsubkb:" id)
    }
    SubscribeKey(id, code, block, cb, concurrent := false) {
        AutoHotInterception.Calls.Push("sub:" id ":" code)
    }
    UnsubscribeKey(id, code) {
        AutoHotInterception.Calls.Push("unsub:" id ":" code)
    }
    SendKeyEvent(id, code, state) {
        this._sent.Push(id ":" code ":" state)
        AutoHotInterception.Calls.Push("send:" id ":" code ":" state)
    }
    SetState(s) {
        AutoHotInterception.Calls.Push("state:" s)
    }
}
