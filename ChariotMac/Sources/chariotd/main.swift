import Foundation
import ChariotCore

// chariotd — headless Chariot Desktop core. Runs the VM supervisor, the
// loopback transport service, and (optionally) the embedded Tailscale node so
// the mobile flow can be exercised end to end without the GUI. Usage:
//   chariotd --data-dir <dir> --base-image <raw> --guest-resources <dir>
//            [--port 8787] [--no-vm] [--no-tailscale] [--tailnet-helper <path>]

var dataDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ChariotDesktop").path
var baseImage = ""
var guestResources = ""
var port: UInt16 = 8787
var startVM = true
var tailscale = true
var helperPath = ""

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--data-dir": dataDir = args.removeFirst()
    case "--base-image": baseImage = args.removeFirst()
    case "--guest-resources": guestResources = args.removeFirst()
    case "--port": port = UInt16(args.removeFirst()) ?? 8787
    case "--no-vm": startVM = false
    case "--no-tailscale": tailscale = false
    case "--tailnet-helper": helperPath = args.removeFirst()
    default:
        FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
        exit(2)
    }
}

guard !baseImage.isEmpty, !guestResources.isEmpty else {
    FileHandle.standardError.write(Data("usage: chariotd --base-image <raw> --guest-resources <dir> [--data-dir <dir>] [--port N] [--no-vm] [--no-tailscale] [--tailnet-helper <path>]\n".utf8))
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
    if !tailscale { hub.tailscaleEnabled = false }
    try hub.startTransportServer(port: port)
    print("[chariotd] mac device: \(hub.macPublicIdentity.deviceID) fingerprint \(hub.macPublicIdentity.fingerprint)")
    print("[chariotd] transport 127.0.0.1:\(hub.transportPort), admin 127.0.0.1:\(hub.adminPort)")

    if hub.tailscaleEnabled {
        // Helper lookup: explicit flag, env, or next to this binary.
        let candidates = [
            helperPath,
            ProcessInfo.processInfo.environment["CHARIOT_TAILNET_HELPER"] ?? "",
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("agent-tailnet").path
        ].filter { !$0.isEmpty }
        if let helper = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            hub.enableTailscale(helperURL: URL(fileURLWithPath: helper))
        } else {
            print("[chariotd] agent-tailnet helper not found — pass --tailnet-helper or run with --no-tailscale")
        }
    }

    let runLoopTask = Task {
        if startVM {
            let configuration = SandboxConfiguration(baseImagePath: baseImage)
            let id = try await hub.ensureInstance(configuration: configuration)
            print("[chariotd] instance \(id) — starting VM")
            try await hub.startVM()
            print("[chariotd] VM running; bridge connected")
        } else {
            print("[chariotd] --no-vm: transport only")
        }
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let shutdown = {
        print("[chariotd] shutting down…")
        runLoopTask.cancel()
        hub.tailnet?.stop()
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
