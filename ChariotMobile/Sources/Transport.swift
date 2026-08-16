import Foundation
import CryptoKit
#if canImport(AgentLinkKit)
import AgentLinkKit
#endif

/// Tailscale transport for the phone. The official Tailscale iOS app provides
/// the VPN; this class is an ordinary HTTPS/WSS client talking to the Mac's
/// embedded tailnet node (or to loopback in the development harness — same
/// protocol, no TLS).
///
/// Pairing uses short REST calls; the message protocol runs over one
/// persistent WebSocket carrying `TransportFrame` JSON. iOS suspends the app
/// in the background, so the connection is re-established on foregrounding
/// and network changes; sequencing, acks, and the durable outbox make that
/// loss-free.
enum TransportError: Error {
    case revoked            // the Mac refuses this device
    case denied             // WS authentication failed
    case conflict           // pairing session already claimed
    case notFound
    case expired
    case http(Int)
    case unreachable(URLError.Code)
    case tlsPinMismatch
}

struct PairingRendezvous {
    var macDeviceID: String
    var macSigningPublicKey: Data
    var macPairingPublicKey: Data
    var state: String
}

/// Narrow certificate validation: when the QR pinned a public-key hash (the
/// Mac serves a per-installation self-signed certificate), accept exactly that
/// SPKI for this host and nothing else. Without a pin, standard system trust
/// applies (Tailscale-issued certificate). TLS validation is never disabled
/// globally and no ATS exception is added.
final class TransportSessionDelegate: NSObject, URLSessionDelegate {
    let pinnedSPKIHash: String?

    init(pinnedSPKIHash: String?) {
        self.pinnedSPKIHash = pinnedSPKIHash
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let pin = pinnedSPKIHash else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let spki = Self.spkiDER(of: leaf) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let hash = Data(SHA256.hash(data: spki)).base64EncodedString()
        if hash == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// DER SubjectPublicKeyInfo for the certificate's P-256 key (matches the
    /// helper's hash over RawSubjectPublicKeyInfo).
    static func spkiDER(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        guard attributes?[kSecAttrKeyType] as? String == (kSecAttrKeyTypeECSECPrimeRandom as String),
              (attributes?[kSecAttrKeySizeInBits] as? Int) == 256 else { return nil }
        // Fixed ASN.1 header for an uncompressed P-256 public key.
        let header: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce,
            0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,
            0x03, 0x01, 0x07, 0x03, 0x42, 0x00
        ]
        return Data(header) + raw
    }
}

final class TailscaleTransport: NSObject, @unchecked Sendable {
    let serviceURL: URL
    let tlsPublicKeyHash: String?
    private let session: URLSession
    private let lock = NSLock()

    init?(serviceURL: String, tlsPublicKeyHash: String?) {
        guard let url = URL(string: serviceURL), url.host != nil else { return nil }
        self.serviceURL = url
        self.tlsPublicKeyHash = tlsPublicKeyHash
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration,
                                  delegate: TransportSessionDelegate(pinnedSPKIHash: tlsPublicKeyHash),
                                  delegateQueue: nil)
        super.init()
    }

    var isDevelopmentLoopback: Bool {
        serviceURL.host == "127.0.0.1" || serviceURL.host == "localhost"
    }

    var modeDescription: String {
        isDevelopmentLoopback ? "Local development" : "Tailscale"
    }

    // MARK: REST (pairing + reachability)

    private func url(_ path: String) -> URL {
        var components = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)!
        components.path = path
        return components.url!
    }

    private func request(_ method: String, _ url: URL, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .serverCertificateUntrusted || error.code == .cancelled {
                throw TransportError.tlsPinMismatch
            }
            throw TransportError.unreachable(error.code)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 { throw TransportError.revoked }
        if status == 404 { throw TransportError.notFound }
        if status == 409 { throw TransportError.conflict }
        if status == 410 { throw TransportError.expired }
        guard (200..<300).contains(status) else { throw TransportError.http(status) }
        return data
    }

    private func json(_ method: String, _ url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await request(method, url, body: bodyData)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func macStatus() async throws -> [String: Any] {
        try await json("GET", url("/status"))
    }

    func fetchPairingRecord(pairingID: String) async throws -> PairingRendezvous {
        let object = try await json("GET", url("/pairing/\(pairingID)"))
        return PairingRendezvous(
            macDeviceID: object["mac_device_id"] as? String ?? "",
            macSigningPublicKey: (try? Base64URL.decode(object["mac_signing_public_key"] as? String ?? "")) ?? Data(),
            macPairingPublicKey: (try? Base64URL.decode(object["mac_pairing_public_key"] as? String ?? "")) ?? Data(),
            state: object["state"] as? String ?? ""
        )
    }

    func claimPairing(pairingID: String, ephemeralPublicKey: Data, encryptedResponse: Data) async throws {
        _ = try await json("POST", url("/pairing/\(pairingID)/response"),
                           body: ["ephemeral_public_key": Base64URL.encode(ephemeralPublicKey),
                                  "ciphertext": Base64URL.encode(encryptedResponse)])
    }

    func fetchCredential(pairingID: String) async throws -> (ciphertext: Data, epoch: UInt32)? {
        do {
            let object = try await json("GET", url("/pairing/\(pairingID)/credential"))
            guard let ciphertextB64 = object["ciphertext"] as? String else { return nil }
            return (try Base64URL.decode(ciphertextB64), UInt32(object["epoch"] as? Int ?? 1))
        } catch TransportError.notFound {
            return nil
        }
    }

    // MARK: Persistent WebSocket

    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    var onFrame: (@Sendable (TransportFrame) -> Void)?
    var onDisconnect: (@Sendable (TransportError?) -> Void)?

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return socket?.state == .running
    }

    /// Open the WebSocket. Frames (including the server's `challenge`) arrive
    /// via `onFrame`; the caller answers with `hello`.
    func connectWebSocket() {
        lock.lock()
        socket?.cancel(with: .goingAway, reason: nil)
        var components = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)!
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.path = "/v2/ws"
        let task = session.webSocketTask(with: components.url!)
        socket = task
        lock.unlock()
        task.resume()
        receiveLoop(task)
        schedulePings(task)
    }

    func disconnect() {
        lock.lock()
        let task = socket
        socket = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
        }
    }

    func sendFrame(_ frame: TransportFrame) {
        lock.lock()
        let task = socket
        lock.unlock()
        guard let task, let data = try? frame.encoded(),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let frame = try? TransportFrame.decode(Data(text.utf8)) {
                    self.onFrame?(frame)
                }
                self.receiveLoop(task)
            case .failure(let error):
                self.lock.lock()
                let isCurrent = self.socket === task
                if isCurrent { self.socket = nil }
                self.lock.unlock()
                guard isCurrent else { return }
                let urlError = error as? URLError
                if urlError?.code == .serverCertificateUntrusted || urlError?.code == .cancelled {
                    self.onDisconnect?(.tlsPinMismatch)
                } else if let code = urlError?.code {
                    self.onDisconnect?(.unreachable(code))
                } else {
                    self.onDisconnect?(nil)
                }
            }
        }
    }

    private func schedulePings(_ task: URLSessionWebSocketTask) {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self, weak task] _ in
                guard let self, let task, task.state == .running else { return }
                task.sendPing { [weak self] error in
                    if error != nil { self?.onDisconnect?(nil) }
                }
            }
        }
    }
}

/// Human guidance for connection failures, per the phone's environment: the
/// Tailscale VPN, tailnet policy, and the Mac itself are separate failure
/// domains and get distinct, actionable messages.
func describeTransportFailure(_ error: TransportError, host: String) -> String {
    switch error {
    case .unreachable(let code):
        switch code {
        case .cannotFindHost, .dnsLookupFailed:
            return "Can't resolve \(host). Open Tailscale and connect this phone — and check it's signed in to the same tailnet as the Mac."
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "No network connection. Open Tailscale and connect this phone."
        case .timedOut:
            return "The Mac is not answering. It may be offline or asleep, this phone may be on a different tailnet, or tailnet policy may be blocking access to the Mac."
        case .cannotConnectToHost:
            return "Reached the network but not the agent service. The Mac may be offline, its Tailscale login may have expired, or tailnet policy is blocking access."
        default:
            return "Connection failed (\(code.rawValue)). Check Tailscale on this phone and the Mac."
        }
    case .tlsPinMismatch:
        return "The service's TLS identity doesn't match this pairing. If the Mac was reset, pair again with a fresh QR code."
    case .revoked:
        return "This phone has been revoked by the Mac."
    case .denied:
        return "The Mac rejected this phone's credentials. Pair again with a fresh QR code."
    case .expired:
        return "This pairing code has expired — show a fresh one on the Mac."
    case .conflict:
        return "This pairing code was already used — show a fresh one on the Mac."
    case .notFound:
        return "Pairing session not found — is the QR code current?"
    case .http(let status):
        return "The Mac's service returned an error (\(status))."
    }
}
