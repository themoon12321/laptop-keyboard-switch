; =====================================================================
;  KbCore v6 —— 拦截核心 (整设备订阅, 绝不使用 SetState(true))
;
;  与 v5 的本质区别 (v6 架构修复, 2026-10-25):
;    v5 在 Block 时调用 AHI.SetState(true) —— 该调用开启驱动的"全局过滤
;    位", 覆盖所有键盘槽位。进程被强杀后该位残留在内核中, 直到下次
;    SetState(false) 或重启, 造成"退出后主键区全部失灵"(实测复现:
;    功能键正常/主键区失灵, 摘除过滤驱动立即恢复)。
;
;    v6 完全不使用 SetState(true):
;      - 拦截 = 仅 SubscribeKeyboard(id, true, cb)  (只影响该设备)
;      - 放行 = UnsubscribeKeyboard(id)             (只影响该设备)
;      - SetState 只允许 false (安全方向, 用于初始化清理与放行)
;    因此任何进程死亡都不会残留"拦截中"状态: 设备级订阅由驱动在
;    客户端上下文销毁时自动释放。
;
;  其余保障保留: 豁免重注入 / 幽灵键修复 / 全或无 / 身份核验 / 蓝牙排除
; =====================================================================
class KbCore {
    __New(ahi, logFn := 0) {
        this.AHI := ahi
        this.logFn := logFn
        this.ids := []
        this.handles := []
        this.subs := Map()          ; id -> true
        this.blocked := false
        this.exempt := Map()
        this.chord := Map()
        this.chordKey := 0
        this.modsDown := Map()
        this.armed := true
        this.seenDown := Map()
        this.onChord := 0
        this.lastError := ""
        this.statReinject := 0
        this.statPhantom := 0
    }

    Log(s) {
        if (IsObject(this.logFn))
            this.logFn.Call(s)
    }

    SetExempt(m) {
        this.exempt := Map()
        for k, _ in m
            this.exempt[Integer(k)] := true
    }

    SetChord(mods, keyCode) {
        this.chord := Map()
        for sc, _ in mods
            this.chord[sc] := true
        this.chordKey := keyCode
        this.modsDown := Map()
        this.armed := true
    }

    SetOnChord(fn) {
        this.onChord := fn
    }

    IsBlocked() {
        return this.blocked
    }

    Reset() {
        this.Unblock()
        this.ids := []
        this.handles := []
    }

    ; 蓝牙键盘天然是外接设备, 永远不纳入
    static IsBluetoothHandle(h) {
        h := StrLower(String(h))
        return (SubStr(h, 1, 6) = "bthle\"
             || SubStr(h, 1, 12) = "bthledevice\"
             || SubStr(h, 1, 8) = "bthenum\"
             || SubStr(h, 1, 4) = "bth\")
    }

    ; ---------------- 识别 ----------------
    Identify(list, cachedHandles := [], interactiveFn := 0) {
        this.lastError := ""
        if (!IsObject(list) || list.Count = 0) {
            this.lastError := "no keyboard devices visible to driver"
            return 0
        }
        hits := []
        if (cachedHandles.Length > 0) {
            for id, info in list {
                if (info.IsMouse || KbCore.IsBluetoothHandle(info.Handle))
                    continue
                h := StrLower(String(info.Handle))
                for c in cachedHandles {
                    if (h = StrLower(String(c))) {
                        hits.Push({id: id, handle: String(info.Handle)})
                        break
                    }
                }
            }
            if (hits.Length = 0)
                this.Log("cached handles not present, falling back to heuristic")
        }
        if (hits.Length = 0) {
            for id, info in list {
                if (info.IsMouse || KbCore.IsBluetoothHandle(info.Handle))
                    continue
                h := StrLower(String(info.Handle))
                if (InStr(h, "msft0001") || InStr(h, "acpi\"))
                    hits.Push({id: id, handle: String(info.Handle)})
            }
        }
        if (hits.Length = 0 && IsObject(interactiveFn)) {
            got := interactiveFn.Call(list)
            if (IsObject(got)) {
                for g in got
                    if (!KbCore.IsBluetoothHandle(g.handle))
                        hits.Push(g)
            }
        }
        if (hits.Length = 0) {
            this.lastError := "no internal keyboard matched"
            return 0
        }
        this.ids := []
        this.handles := []
        for h in hits {
            this.ids.Push(h.id)
            this.handles.Push(h.handle)
        }
        return this.ids.Length
    }

    ; ---------------- 截断 / 恢复 ----------------
    ; v6: 不调用 SetState(true)。设备级订阅由驱动在客户端死亡时自动释放,
    ;     不存在可残留的全局状态。
    Block() {
        this.lastError := ""
        if (this.ids.Length = 0) {
            this.lastError := "no internal device identified"
            return false
        }
        this.UnblockQuiet()
        ok := 0
        for i, id in this.ids {
            if (!this.VerifyIdentity(id, this.handles[i])) {
                this.lastError := "identity mismatch (id " id "), refusing to subscribe"
                this.Log("BLOCK SKIP: " this.lastError)
                continue
            }
            try {
                this.AHI.SubscribeKeyboard(id, true, this.OnStroke.Bind(this, id))
                this.subs[id] := true
                ok++
            } catch as e {
                this.lastError := "subscribe failed (id " id "): " e.Message
                this.Log("BLOCK ERROR: " this.lastError)
            }
        }
        if (ok = 0 || ok != this.ids.Length) {
            if (ok > 0)
                this.lastError := "partial subscribe " ok "/" this.ids.Length ", rolled back"
            this.UnblockQuiet()
            ; 回滚同时以安全方向关闭全局过滤 (false 永远不会产生拦截残留)
            try this.AHI.SetState(false)
            return false
        }
        this.blocked := true
        this.seenDown := Map()
        this.modsDown := Map()
        this.armed := true
        return true
    }

    Unblock() {
        this.UnblockQuiet()
        ; 安全方向的全局关闭 (放行), 不产生拦截残留
        try this.AHI.SetState(false)
        return true
    }

    UnblockQuiet() {
        for id, _ in this.subs {
            try this.AHI.UnsubscribeKeyboard(id)
            catch as e
                this.Log("UNSUB ERROR (id " id "): " e.Message)
        }
        this.subs := Map()
        this.blocked := false
        this.seenDown := Map()
        this.modsDown := Map()
        this.armed := true
    }

    Panic() {
        this.Unblock()
    }

    ; ---------------- 驱动回调 ----------------
    OnStroke(id, code, state) {
        if (!this.subs.Has(id))
            return
        this.TrackChord(code, state)
        if (this.exempt.Has(code)) {
            try {
                this.AHI.SendKeyEvent(id, code, state)
                this.statReinject++
            } catch as e {
                this.Log("REINJECT FAIL code=" code ": " e.Message)
            }
            return
        }
        key := id ":" code
        if (state = 1) {
            this.seenDown[key] := true
        } else {
            if (!this.seenDown.Has(key)) {
                try {
                    this.AHI.SendKeyEvent(id, code, 0)
                    this.statPhantom++
                    this.Log("phantom-up cleared: id=" id " code=" code)
                } catch as e {
                    this.Log("PHANTOM FIX FAIL: " e.Message)
                }
            } else {
                this.seenDown.Delete(key)
            }
        }
    }

    TrackChord(code, state) {
        if (this.chordKey = 0)
            return
        if (this.chord.Has(code)) {
            this.modsDown[code] := (state = 1)
            return
        }
        if (code = this.chordKey) {
            if (state = 1) {
                allDown := true
                for sc, _ in this.chord {
                    if (!this.modsDown.Get(sc, false))
                        allDown := false
                }
                if (allDown && this.armed) {
                    this.armed := false
                    if (IsObject(this.onChord))
                        this.onChord.Call()
                }
            } else {
                this.armed := true
            }
        }
    }

    ; ---------------- 身份核验 ----------------
    VerifyIdentity(id, handle) {
        lst := 0
        try lst := this.AHI.GetDeviceList()
        catch
            return false
        if (!IsObject(lst) || !lst.Has(id))
            return false
        try
            return StrLower(String(lst[id].Handle)) = StrLower(String(handle))
        catch
            return false
    }

    Revalidate() {
        if (this.ids.Length = 0)
            return "none"
        for i, id in this.ids {
            if (!this.VerifyIdentity(id, this.handles[i]))
                return "lost"
        }
        return "ok"
    }
}
