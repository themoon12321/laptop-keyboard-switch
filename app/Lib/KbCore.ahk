; Device ownership and filtering are restricted to identified internal keyboards.
; AHI Subscribe/Unsubscribe also enable filters internally. SetState(false) is
; a best-effort fail-open operation for THIS AHI context, not a global repair.
#include %A_LineFile%\..\KeyGestures.ahk
class KbCore {
    __New(ahi, logFn := 0) {
        this.AHI := ahi
        this.logFn := logFn
        this.ids := []
        this.handles := []
        this.subs := Map() ; id -> verified handle, retained on cleanup failure
        this.blocked := false
        this.mode := "pass"
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
        this.gesturesEnabled := false
        this.gestures := KeyGestures(this.EmitGesture.Bind(this))
        this.onObserve := 0
        this.needReidentify := false
        this.needStop := false
        this.dispatchId := 0
    }
    Log(s) {
        if IsObject(this.logFn)
            this.logFn.Call(s)
    }
    SetExempt(m) {
        this.exempt := Map()
        for k, _ in m
            this.exempt[Integer(k)] := true
    }
    SetChord(mods, keyCode) {
        this.chord := mods.Clone()
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
        ok := this.Stop()
        this.ids := []
        this.handles := []
        return ok
    }
    static IsBluetoothHandle(h) {
        return RegExMatch(String(h), "i)^(bthle|bthledevice|bthenum|bth)\\") != 0
    }
    Identify(list, cachedHandles := [], interactiveFn := 0) {
        this.lastError := ""
        if (!IsObject(list) || list.Count = 0) {
            this.lastError := "no keyboard devices visible to driver"
            return 0
        }
        hits := [], heuristic := []
        for id, info in list {
            if (info.IsMouse || KbCore.IsBluetoothHandle(info.Handle))
                continue
            h := StrLower(String(info.Handle))
            selected := false
            for cached in cachedHandles
                if (h = StrLower(String(cached)))
                    selected := true
            if selected
                hits.Push({id: id, handle: String(info.Handle)})
            if (InStr(h, "msft0001") || InStr(h, "acpi\"))
                heuristic.Push({id: id, handle: String(info.Handle)})
        }
        if (hits.Length = 0)
            hits := heuristic
        else {
            ; Expand a partial ACPI cache, while respecting manually selected USB devices.
            allAcpi := true, seen := Map()
            for hit in hits {
                seen[hit.id] := true
                if !InStr(StrLower(hit.handle), "acpi\")
                    allAcpi := false
            }
            if allAcpi
                for candidate in heuristic
                    if !seen.Has(candidate.id)
                        hits.Push(candidate)
        }
        if (hits.Length = 0 && IsObject(interactiveFn)) {
            got := interactiveFn.Call(list)
            if IsObject(got)
                for g in got
                    if (!KbCore.IsBluetoothHandle(g.handle) && list.Has(g.id) && !list[g.id].IsMouse
                        && StrLower(String(list[g.id].Handle)) = StrLower(String(g.handle)))
                        hits.Push(g)
        }
        if (hits.Length = 0) {
            this.lastError := "no internal keyboard matched"
            return 0
        }
        this.ids := []
        this.handles := []
        for hit in hits {
            this.ids.Push(hit.id)
            this.handles.Push(hit.handle)
        }
        this.needReidentify := false
        return this.ids.Length
    }
    ConfigureGestures(rules, enabled) {
        validated := KeyGestures.Validate(rules)
        if !this.Stop()
            return false
        this.gestures.SetRules(rules)
        this.gesturesEnabled := enabled && validated.Count > 0
        return true
    }
    Block() {
        return this.SubscribeMode("blocked")
    }
    Unblock() {
        if (this.gesturesEnabled && this.ids.Length > 0)
            return this.SubscribeMode("remap")
        return this.Stop()
    }
    ; Retain failed unsubscriptions; never re-enable a context with stale mappings.
    Stop() {
        this.mode := "pass"
        this.blocked := false
        this.gestures.Cancel()
        failed := Map()
        for id, handle in this.subs {
            try this.AHI.UnsubscribeKeyboard(id)
            catch as e {
                failed[id] := handle
                this.Log("UNSUB ERROR (id " id "): " e.Message)
            }
        }
        this.subs := failed
        safe := true
        try this.AHI.SetState(false)
        catch as e {
            safe := false
            this.Log("FAIL-OPEN ERROR: " e.Message)
        }
        this.seenDown := Map()
        this.modsDown := Map()
        this.armed := true
        if (!safe || failed.Count) {
            this.mode := "error"
            this.lastError := "release not confirmed; failed subscriptions=" failed.Count
            return false
        }
        return true
    }
    UnblockQuiet() {
        return this.Stop()
    }
    SubscribeMode(mode) {
        this.lastError := ""
        if !this.Stop()
            return false
        if (this.ids.Length = 0) {
            this.lastError := "no internal device identified"
            return false
        }
        this.mode := mode
        for i, id in this.ids {
            if !this.VerifyIdentity(id, this.handles[i]) {
                this.lastError := "identity mismatch (id " id "), refusing to subscribe"
                this.Log("BLOCK SKIP: " this.lastError)
                break
            }
            ; Track attempts too: a throwing API may already have changed state.
            this.subs[id] := this.handles[i]
            try this.AHI.SubscribeKeyboard(id, true, this.OnStroke.Bind(this, id))
            catch as e {
                this.lastError := "subscribe failed (id " id "): " e.Message
                this.Log("BLOCK ERROR: " this.lastError)
                break
            }
        }
        if (this.lastError != "") {
            reason := this.lastError
            this.Stop()
            this.lastError := reason (this.mode = "error" ? "; cleanup not confirmed" : "; rolled back")
            return false
        }
        this.blocked := (mode = "blocked")
        return true
    }
    Panic() {
        return this.Stop()
    }
    TickGestures() {
        previousCritical := A_IsCritical
        Critical("On")
        try this.TickGesturesQuiet()
        finally Critical(previousCritical)
    }
    TickGesturesQuiet() {
        if this.needStop {
            this.needStop := false
            this.Stop()
            return
        }
        if (this.mode = "remap") {
            try this.gestures.Tick()
            catch as e {
                this.lastError := "gesture output failed: " e.Message
                this.Log(this.lastError)
                this.Stop()
            }
        }
    }
    EmitGesture(id, code, state) {
        ; A timer must never emit a delayed character onto a re-used device ID.
        if (!this.subs.Has(id) || (this.dispatchId != id && !this.VerifyIdentity(id, this.subs[id]))) {
            this.needReidentify := true
            return
        }
        this.AHI.SendKeyEvent(id, code, state)
    }
    OnStroke(id, code, state) {
        previousCritical := A_IsCritical
        Critical("On")
        try this.ProcessStroke(id, code, state)
        catch as e {
            this.lastError := "input callback failed: " e.Message
            this.Log(this.lastError)
            this.mode := "error"
            this.needStop := true
        } finally {
            this.dispatchId := 0
            Critical(previousCritical)
        }
    }
    ProcessStroke(id, code, state) {
        if !this.subs.Has(id)
            return
        if !this.VerifyIdentity(id, this.subs[id]) {
            this.needReidentify := true
            try this.AHI.SendKeyEvent(id, code, state) ; pass through unexpected device
            return
        }
        this.dispatchId := id ; reuse this event's validated identity during sends
        if IsObject(this.onObserve)
            this.onObserve.Call(code, state)
        if (this.mode = "remap") {
            try this.gestures.Stroke(id, code, state,
                GetKeyState("Ctrl") || GetKeyState("Alt") || GetKeyState("LWin") || GetKeyState("RWin"))
            catch as e {
                this.lastError := "gesture callback failed: " e.Message
                this.Log(this.lastError)
                ; Defer unsubscribe: never stop a worker from its own callback.
                this.mode := "error"
                this.needStop := true
            }
            return
        }
        if (this.mode != "blocked") {
            try this.AHI.SendKeyEvent(id, code, state)
            return
        }
        this.TrackChord(code, state)
        if (this.exempt.Has(code) && !this.chord.Has(code) && code != this.chordKey) {
            try {
                this.AHI.SendKeyEvent(id, code, state)
                this.statReinject++
            }
            return
        }
        key := id ":" code
        if (state = 1)
            this.seenDown[key] := true
        else if !this.seenDown.Has(key) {
            try {
                this.AHI.SendKeyEvent(id, code, 0)
                this.statPhantom++
            }
        } else
            this.seenDown.Delete(key)
    }
    TrackChord(code, state) {
        if !this.chordKey
            return
        if this.chord.Has(code) {
            this.modsDown[code] := (state = 1)
            return
        }
        if (code != this.chordKey)
            return
        if (state = 0) {
            this.armed := true
            return
        }
        for sc, _ in this.chord
            if !this.modsDown.Get(sc, false)
                return
        if this.armed {
            this.armed := false
            if IsObject(this.onChord)
                this.onChord.Call()
        }
    }
    VerifyIdentity(id, handle) {
        try {
            lst := this.AHI.GetDeviceList()
            return IsObject(lst) && lst.Has(id) && !lst[id].IsMouse
                && !KbCore.IsBluetoothHandle(lst[id].Handle)
                && StrLower(String(lst[id].Handle)) = StrLower(String(handle))
        }
        return false
    }
    Revalidate() {
        if (this.ids.Length = 0)
            return "none"
        if this.needReidentify
            return "lost"
        for i, id in this.ids
            if !this.VerifyIdentity(id, this.handles[i])
                return "lost"
        return "ok"
    }
}
