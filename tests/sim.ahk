; =====================================================================
;  KbCore simulation tests (no UI, never touches a real keyboard)
;  usage: AutoHotkey64.exe tests\sim.ahk  -> writes tests\sim-results.txt
;  covers: identify / multi-device / whole-device subscribe / exempt
;          reinjection / phantom-up fix / all-or-nothing rollback /
;          identity check / renumber after resume / panic / chord / 100 toggles
; =====================================================================
#Requires AutoHotkey v2.0
#Warn All, StdOut
#Warn LocalSameAsGlobal, Off
#SingleInstance Off
#include ..\app\lib\KbCore.ahk

global g_pass := 0
global g_fail := 0
global g_msgs := ""
global outFile := A_ScriptDir "\sim-results.txt"
global progFile := A_ScriptDir "\sim-progress.txt"
try FileDelete(outFile)
try FileDelete(progFile)
Prog(s) {
    global progFile
    try FileAppend(s "`n", progFile, "UTF-8")
}

Check(cond, name) {
    global g_pass, g_fail, g_msgs
    if (cond) {
        g_pass++
        g_msgs .= "PASS  " name "`n"
    } else {
        g_fail++
        g_msgs .= "FAIL  " name "`n"
    }
}

class FakeAHI {
    __New() {
        this.devs := Map()
        this.subs := Map()
        this.sent := []
        this.failIds := Map()
        this.stateCalls := []
        this.failUnsubIds := Map()
        this.failRelease := false
        this.failSend := false
        this.filterEnabled := false
    }
    AddDev(id, handle, isMouse := false) {
        this.devs[id] := {id: id, Handle: handle, IsMouse: isMouse}
    }
    DelDev(id) {
        this.devs.Delete(id)
    }
    GetDeviceList() {
        return this.devs
    }
    SubscribeKeyboard(id, block, cb) {
        if (this.failIds.Has(id))
            throw Error("simulated subscribe failure id=" id)
        this.subs[id] := cb
        this.filterEnabled := true ; actual AHI Subscribe enables its context
    }
    UnsubscribeKeyboard(id) {
        if this.failUnsubIds.Has(id)
            throw Error("simulated cleanup failure")
        if this.subs.Has(id)
            this.subs.Delete(id)
    }
    SendKeyEvent(id, code, state) {
        if this.failSend
            throw Error("simulated output failure")
        this.sent.Push({id: id, code: code, state: state})
    }
    SetState(s) {
        if (!s && this.failRelease)
            throw Error("simulated release failure")
        this.stateCalls.Push(s)
        this.filterEnabled := s
    }
    Stroke(id, code, state) {
        if (this.filterEnabled && this.subs.Has(id))
            this.subs[id].Call(code, state)
    }
    LastState() {
        return this.stateCalls.Length ? this.stateCalls[this.stateCalls.Length] : ""
    }
    SentCount(code := "", state := "") {
        n := 0
        for s in this.sent {
            if (code != "" && s.code != code)
                continue
            if (state != "" && s.state != state)
                continue
            n++
        }
        return n
    }
}

NewCore(f) {
    return KbCore(f, 0)
}

Prog("T1 start")
f := FakeAHI()
f.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
f.AddDev(2, "USB\VID_32C2&PID_0018")
f.AddDev(3, "HID\VID_1EA7&PID_0064&Col01")
c := NewCore(f)
n := c.Identify(f.GetDeviceList(), [])
Check(n = 1 && c.ids.Length = 1 && c.ids[1] = 1, "T1 heuristic picks only internal ACPI device")
Prog("T1 done")

Prog("T2 start")
f2 := FakeAHI()
f2.AddDev(1, "HID\VID_1234&PID_5678&MI_00")
f2.AddDev(2, "HID\VID_1234&PID_5678&Col02")
f2.AddDev(3, "USB\VID_32C2&PID_0018")
interact := (list) => [{id: 1, handle: "HID\VID_1234&PID_5678&MI_00"}, {id: 2, handle: "HID\VID_1234&PID_5678&Col02"}]
c2 := NewCore(f2)
n2 := c2.Identify(f2.GetDeviceList(), [], interact)
Check(n2 = 2 && c2.ids[1] = 1 && c2.ids[2] = 2, "T2 interactive identify supports multiple devices")
Prog("T2 done")

Prog("T3 start")
f3 := FakeAHI()
f3.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
f3.AddDev(2, "USB\VID_32C2&PID_0018")
c3 := NewCore(f3)
c3.Identify(f3.GetDeviceList(), [])
ok3 := c3.Block()
Check(ok3 && f3.subs.Count = 1 && f3.subs.Has(1) && !f3.subs.Has(2), "T3 block subscribes internal only")
; The wrapper activates context filters inside Subscribe; explicit SetState(true)
; is unnecessary, but omitting it does not prove anything about other devices.
Check(f3.LastState() != 1 && f3.filterEnabled, "T3b subscription activates only the fake context without redundant SetState(true)")
Prog("T3 done")

Prog("T4 start")
f3.Stroke(1, 30, 1)
f3.Stroke(1, 30, 0)
Check(f3.SentCount() = 0, "T4 normal key fully swallowed")
Prog("T4 done")

Prog("T5 start")
f3.sent := []
c3.SetExempt(Map(46, true))
f3.Stroke(1, 46, 1)
f3.Stroke(1, 46, 0)
Check(f3.SentCount(46, 1) = 1 && f3.SentCount(46, 0) = 1, "T5 exempt keys are re-injected")
Prog("T5 done")

Prog("T6 start")
f3.sent := []
f3.Stroke(1, 91, 0)
Check(f3.SentCount(91, 0) = 1, "T6 phantom-up cleared (prevents stuck modifier)")
Prog("T6 done")

Prog("T6b start")
f3.sent := []
f3.Stroke(1, 29, 1)
f3.Stroke(1, 29, 0)
Check(f3.SentCount() = 0, "T6b normal down/up produces no phantom inject")
Prog("T6b done")

Prog("T7 start")
f3.sent := []
c3.Unblock()
Check(f3.subs.Count = 0 && !c3.blocked, "T7 unblock leaves no subscriptions")
Check(f3.LastState() = 0, "T7b unblock calls SetState(false)")
Prog("T7 done")

Prog("T8 start")
f8 := FakeAHI()
f8.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
c8 := NewCore(f8)
c8.Identify(f8.GetDeviceList(), [])
err := 0
loop 100 {
    try {
        if (!c8.Block()) {
            err++
            break
        }
        if (f8.subs.Count != 1) {
            err++
            break
        }
        c8.Unblock()
        if (f8.subs.Count != 0) {
            err++
            break
        }
    } catch {
        err++
        break
    }
}
Check(err = 0 && f8.subs.Count = 0 && !c8.blocked, "T8 100 toggles leave no residue")
Prog("T8 done")

Prog("T9 start")
f9 := FakeAHI()
f9.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
c9 := NewCore(f9)
c9.Identify(f9.GetDeviceList(), [])
c9.Block()
chk9a := (c9.Revalidate() = "ok")
f9.DelDev(1)
f9.AddDev(2, "ACPI\VEN_MSFT&DEV_0001")
chk9b := (c9.Revalidate() = "lost")
Check(chk9a && chk9b, "T9 device renumber detected as identity loss")
Prog("T9 done")

Prog("T10 start")
f10 := FakeAHI()
f10.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
c10 := NewCore(f10)
c10.Identify(f10.GetDeviceList(), [])
f10.devs[1].Handle := "USB\VID_32C2&PID_0018"
ok10 := c10.Block()
Check(!ok10 && f10.subs.Count = 0 && !c10.blocked, "T10 identity mismatch refuses to subscribe")
Prog("T10 done")

Prog("T11 start")
f11 := FakeAHI()
f11.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
f11.failIds[1] := true
c11 := NewCore(f11)
c11.Identify(f11.GetDeviceList(), [])
ok11 := c11.Block()
Check(!ok11 && f11.subs.Count = 0 && !c11.blocked, "T11 subscribe failure rolls back")
Check(f11.LastState() = 0, "T11b rollback calls SetState(false)")
Prog("T11 done")

Prog("T12 start")
f12 := FakeAHI()
f12.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
f12.AddDev(2, "ACPI\VEN_MSFT&DEV_0002")
f12.failIds[2] := true
c12 := NewCore(f12)
c12.Identify(f12.GetDeviceList(), [])
ok12 := c12.Block()
Check(!ok12 && f12.subs.Count = 0, "T12 partial failure rolls back all")
Prog("T12 done")

Prog("T13 start")
f13 := FakeAHI()
f13.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
c13 := NewCore(f13)
c13.Identify(f13.GetDeviceList(), [])
fire := {n: 0}
OnChordFn := (*) => (fire.n := fire.n + 1)
c13.SetOnChord(OnChordFn)
c13.SetChord(Map(29, true, 56, true), 37)
c13.Block()
f13.Stroke(1, 29, 1)
f13.Stroke(1, 56, 1)
f13.Stroke(1, 37, 1)
r1 := fire.n
f13.Stroke(1, 37, 0)
f13.Stroke(1, 37, 1)
r2 := fire.n
Check(r1 = 1 && r2 = 2, "T13 emergency chord fires once per press")
Prog("T13 done")

Prog("T14 start")
f14 := FakeAHI()
f14.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
c14 := NewCore(f14)
c14.Identify(f14.GetDeviceList(), [])
c14.Block()
c14.Panic()
Check(f14.subs.Count = 0 && !c14.blocked && f14.LastState() = 0, "T14 panic releases everything")
Prog("T14 done")

Prog("T15 start")
f15 := FakeAHI()
f15.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
f15.AddDev(2, "USB\VID_32C2&PID_0018")
c15 := NewCore(f15)
n15 := c15.Identify(f15.GetDeviceList(), ["USB\VID_32C2&PID_0018"])
Check(n15 = 1 && c15.ids[1] = 2, "T15 cached handle matches by content")
Prog("T15 done")

Prog("T16 start")
; 蓝牙键盘即使被写进缓存, 也必须被拒绝 (蓝牙天然是外接设备)
f16 := FakeAHI()
f16.AddDev(1, "ACPI\VEN_MSFT&DEV_0001")
f16.AddDev(2, "BTHLEDEVICE\{00001812-0000-1000-8000-00805F9B34FB}_DEV_VID&023554_PID&FA07&COL01\9&1&0&0000")
c16 := NewCore(f16)
n16 := c16.Identify(f16.GetDeviceList(), ["BTHLEDEVICE\{00001812-0000-1000-8000-00805F9B34FB}_DEV_VID&023554_PID&FA07&COL01\9&1&0&0000"])
Check(n16 = 1 && c16.ids[1] = 1, "T16 Bluetooth handle in cache is rejected, falls back to internal")
Prog("T16 done")

Prog("T16b start")
f16b := FakeAHI()
f16b.AddDev(1, "BTHLE\DEV_FF1E97B32273\7&39CEA933&0&FF1E97B32273")
btOnly := (list) => [{id: 1, handle: "BTHLE\DEV_FF1E97B32273\7&39CEA933&0&FF1E97B32273"}]
c16b := NewCore(f16b)
n16b := c16b.Identify(f16b.GetDeviceList(), [], btOnly)
Check(n16b = 0 && c16b.ids.Length = 0, "T16b Bluetooth-only interactive result is rejected")
Prog("T16b done")

Prog("ALL done")
ambiguous := FakeAHI()
ambiguous.AddDev(1, "USB\same-model")
ambiguous.AddDev(2, "USB\same-model")
ambiguousCore := NewCore(ambiguous)
Check(ambiguousCore.Identify(ambiguous.GetDeviceList(), ["USB\same-model"]) = 0,
    "duplicate hardware handles cannot silently select internal and external together")
manualOnly := NewCore(f)
confirmedOnly := (list) => [{id: 2, handle: "USB\VID_32C2&PID_0018"}]
Check(manualOnly.Identify(f.GetDeviceList(), [], confirmedOnly, false) = 1 && manualOnly.ids[1] = 2,
    "confirmed selection bypasses ACPI heuristic instead of silently overriding it")
; Failed cleanup must remain visible and must prevent any re-subscription.
f17 := FakeAHI()
f17.AddDev(1, "ACPI\internal")
c17 := NewCore(f17)
c17.Identify(f17.GetDeviceList())
c17.Block()
f17.failUnsubIds[1] := true
Check(!c17.Unblock() && c17.subs.Has(1) && c17.mode = "error", "T17 cleanup failure retains ownership and reports unknown state")
Check(!c17.Block() && !f17.filterEnabled, "T17b stale subscription cannot reactivate filters")
f17.failUnsubIds.Clear()
Check(c17.Unblock() && c17.subs.Count = 0, "T17c retry can finish cleanup")
f17.failRelease := true
Check(!c17.Unblock() && c17.mode = "error", "T18 failed fail-open is reported")

f19 := FakeAHI()
f19.AddDev(1, "ACPI\fragment1")
f19.AddDev(2, "ACPI\fragment2")
f19.AddDev(3, "USB\external")
c19 := NewCore(f19)
Check(c19.Identify(f19.GetDeviceList(), ["ACPI\fragment1"]) = 2, "T19 partial cache still includes all internal fragments")
c19.SetChord(Map(29, true), 37)
c19.SetExempt(Map(29, true, 37, true))
c19.Block()
f19.Stroke(1, 29, 1)
f19.Stroke(1, 37, 1)
Check(f19.sent.Length = 0, "T20 chord keys cannot leak through exemptions")
f19.devs[1].Handle := "USB\external-reused-id"
f19.Stroke(1, 30, 1)
Check(c19.needReidentify && f19.SentCount(30, 1) = 1, "T21 reused device ID passes input and requests re-identification")

f22 := FakeAHI()
f22.AddDev(1, "ACPI\internal")
c22 := NewCore(f22)
c22.Identify(f22.GetDeviceList())
c22.ConfigureGestures([{source: 45, target: 44, mode: "hold", delay: 600}], true)
c22.Unblock()
f22.failSend := true
f22.Stroke(1, 30, 1)
Check(c22.needStop && f22.subs.Count = 1, "T22 output failure schedules release outside the driver callback")
c22.TickGestures()
Check(c22.mode = "pass" && f22.subs.Count = 0 && !f22.filterEnabled, "T22b deferred release stops failed gesture processing")

g_msgs .= "`nTOTAL: " g_pass " passed, " g_fail " failed`n"
FileAppend(g_msgs, outFile, "UTF-8")
ExitApp(g_fail > 0 ? 1 : 0)
