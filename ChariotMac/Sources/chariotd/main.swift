import Foundation
import ChariotCore

// chariotd — headless Chariot Desktop core. Runs the VM supervisor and the
// localhost mailbox so the mobile flow can be exercised end to end without the
// GUI. Usage:
//   chariotd --data-dir <dir> --base-image <raw> --guest-resources <dir> [--port 8787] [--no-vm]

var dataDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ChariotDesktop").path
var baseImage = ""
var guestResources = ""
var port: UInt16 = 8787
var startVM = true

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--data-dir": dataDir = args.removeFirst()
    case "--base-image": baseImage = args.removeFirst()
    case "--guest-resources": guestResources = args.removeFirst()
    case "--port": port = UInt16(args.removeFirst()) ?? 8787
    case "--no-vm": startVM = false
    default:
        FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
        exit(2)
    }
}

guard !baseImage.isEmpty, !guestResources.isEmpty else {
    FileHandle.standardError.write(Data("usage: chariotd --base-image <raw> --guest-resources <dir> [--data-dir <dir>] [--port N] [--no-vm]\n".utf8))
    exit(2)
}

let paths = ChariotPaths(dataDirectory: URL(fileURLWithPath: dataDir),
                         guestResources: URL(fileURLWithPath: guestResources))

do {
    let hub = try ChariotHub(paths: paths)
    hub.onEvent = { message in
        print("[chariotd] \(message)")
        fflush(stdout)
    }
    try hub.startMailboxServer(port: port)
    print("[chariotd] mac device: \(hub.macPublicIdentity.deviceID) fingerprint \(hub.macPublicIdentity.fingerprint)")

    let runLoopTask = Task {
        if startVM {
            let configuration = SandboxConfiguration(baseImagePath: baseImage)
            let id = try await hub.ensureInstance(configuration: configuration)
            print("[chariotd] instance \(id) — starting VM")
            try await hub.startVM()
            print("[chariotd] VM running; bridge connected")
        } else {
            print("[chariotd] --no-vm: mailbox only")
        }
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let shutdown = {
        print("[chariotd] shutting down…")
        runLoopTask.cancel()
        Task {
            try? await hub.stopVM()
            exit(0)
        }
    }
    sigintSource.setEventHandler(handler: shutdown)
    sigtermSource.setEventHandler(handler: shutdown)
    sigintSource.resume()
    sigtermSource.resume()

    RunLoop.main.run()
} catch {
    FileHandle.standardError.write(Data("chariotd failed: \(error)\n".utf8))
    exit(1)
}
