import Foundation

// SIGPIPE defences for the raw sockets this process writes to.
//
// Every transport here — the loopback HTTP server, the phone WebSocket, the
// guest bridge, the OAuth and developer-access forwarders — sends with
// `write(2)` on a socket fd. Under the default SIGPIPE disposition the kernel
// kills the process inside that `write` as soon as the peer has gone away, so
// the `w <= 0` handling at every call site never got a chance to run: a phone
// dropping mid-upload took the whole app down instead of just its connection.
// With these two guards in place `write` returns -1/EPIPE and the existing
// error paths close the one connection.

/// Ignore SIGPIPE for the whole process. Call once at startup, before any
/// socket is opened.
public func ignoreSIGPIPE() {
    signal(SIGPIPE, SIG_IGN)
}

/// Per-socket guard, so a write on `fd` fails with EPIPE no matter what the
/// process-wide disposition is. Applied to every fd we write to, which keeps
/// ChariotCore safe inside hosts that never call `ignoreSIGPIPE()` — the test
/// runner, above all.
func disableSIGPIPE(on fd: Int32) {
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
}
