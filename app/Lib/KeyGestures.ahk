; Pure input state machine. No hooks, drivers, UI or timers are installed here.
; The owner supplies a sender and calls Tick with a monotonic clock.
class KeyGestures {
    __New(sender, clock := 0) {
        this.sender := sender
        this.clock := IsObject(clock) ? clock : (() => DllCall("GetTickCount64", "UInt64"))
        this.rules := Map()
        this.pending := Map()
        this.modifiers := Map()
    }

    static Validate(rules) {
        out := Map()
        reserved := Map(29, 1, 285, 1, 42, 1, 54, 1, 56, 1, 312, 1, 347, 1, 348, 1, 58, 1, 69, 1, 70, 1)
        for r in rules {
            source := Integer(r.source), target := Integer(r.target), delay := Integer(r.delay)
            if (source < 1 || source > 511 || target < 1 || target > 511)
                throw Error("按键必须有有效扫描码 (1..511)，Fn 不支持")
            if (reserved.Has(source) || reserved.Has(target))
                throw Error("暂不支持把修饰键或锁定键作为替代规则的源键/目标键")
            if (source = target || out.Has(source))
                throw Error("源键与目标键不能相同，每个源键只能配置一条规则")
            if (r.mode != "hold" && r.mode != "double")
                throw Error("触发方式必须为长按或双击")
            if (delay < 150 || delay > 10000)
                throw Error("时间必须在 150–10000 毫秒之间")
            out[source] := {source: source, target: target, mode: r.mode, delay: delay}
        }
        return out
    }

    SetRules(rules) {
        validated := KeyGestures.Validate(rules)
        this.Cancel()
        this.rules := validated
    }

    Emit(id, code, state) {
        this.sender.Call(id, code, state)
    }

    Tap(id, code) {
        this.Emit(id, code, 1)
        this.Emit(id, code, 0)
    }

    ShortcutHeld(id) {
        for sc in [29, 285, 56, 312, 347, 348]
            if (this.modifiers.Get(id ":" sc, false))
                return true
        return false
    }

    ; Emit a deferred original key before a different key, keeping typing order
    ; and shortcuts intact. A held source becomes an ordinary held key.
    FlushOthers(id, exceptCode := 0) {
        remove := []
        for key, p in this.pending {
            if (p.id != id || p.code = exceptCode || p.phase != "pending")
                continue
            if (p.held) {
                this.Emit(p.id, p.code, 1)
                p.phase := "pass"
            } else {
                this.Tap(p.id, p.code)
                remove.Push(key)
            }
        }
        for key in remove
            this.pending.Delete(key)
    }

    Stroke(id, code, state, shortcutHeld := false) {
        now := this.clock.Call()
        this.Tick(now)
        key := id ":" code
        if (state = 1)
            this.FlushOthers(id, code)
        if (code = 29 || code = 285 || code = 56 || code = 312 || code = 347 || code = 348)
            this.modifiers[key] := (state = 1)

        if (!this.rules.Has(code)) {
            this.Emit(id, code, state)
            return
        }
        if (this.pending.Has(key)) {
            p := this.pending[key]
            if (state = 1) {
                if (p.phase = "pass")
                    this.Emit(id, code, 1) ; preserve hardware auto-repeat
                else if (!p.held && p.rule.mode = "double") {
                    p.held := true
                    p.phase := "fired"
                    this.Tap(id, p.rule.target)
                }
                return
            }
            p.held := false
            if (p.phase = "pass") {
                this.Emit(id, code, 0)
                this.pending.Delete(key)
            } else if (p.phase = "fired") {
                this.pending.Delete(key)
            } else if (p.rule.mode = "hold") {
                this.Tap(id, code)
                this.pending.Delete(key)
            } else {
                p.at := now ; double-tap interval is measured after first release
            }
            return
        }
        if (state = 0) {
            this.Emit(id, code, 0) ; release keys held before feature activation
            return
        }
        rule := this.rules[code]
        if (shortcutHeld || this.ShortcutHeld(id)) {
            this.pending[key] := {id: id, code: code, rule: rule, at: now, held: true, phase: "pass"}
            this.Emit(id, code, 1)
            return
        }
        this.pending[key] := {id: id, code: code, rule: rule, at: now, held: true, phase: "pending"}
    }

    Tick(now := -1) {
        if (now < 0)
            now := this.clock.Call()
        remove := []
        for key, p in this.pending {
            if (p.phase != "pending" || now - p.at < p.rule.delay)
                continue
            if (p.rule.mode = "hold" && p.held) {
                p.phase := "fired"
                this.Tap(p.id, p.rule.target)
            } else if (p.held) {
                p.phase := "pass"
                this.Emit(p.id, p.code, 1)
            } else {
                this.Tap(p.id, p.code)
                remove.Push(key)
            }
        }
        for key in remove
            this.pending.Delete(key)
    }

    Cancel() {
        ; Never generate a delayed character during block, disconnect or exit.
        for key, p in this.pending
            if (p.phase = "pass" && p.held)
                try this.Emit(p.id, p.code, 0)
        this.pending := Map()
        this.modifiers := Map()
    }
}
