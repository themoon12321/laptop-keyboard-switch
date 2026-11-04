class FakeInputHook {
    KeyOpt(*) {
    }
    Start() {
    }
    Stop() {
        this.OnEnd.Call(this)
    }
}
