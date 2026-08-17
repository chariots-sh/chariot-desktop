import Foundation
import CryptoKit

/// Minimal RFC 6455 server-side WebSocket over an accepted socket. Carries the
/// JSON `TransportFrame` protocol between the Mac and a phone; TLS termination
/// happens upstream (in the agent-tailnet helper for tailnet connections) so
/// this only ever runs over loopback.
final class WebSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private var open = true

    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32) {
        self.fd = fd
        disableSIGPIPE(on: fd)
    }

    static func acceptKey(for clientKey: String) -> String {
        let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((clientKey + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    /// Blocking read loop; runs on the connection's accept thread.
    func run() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var fragmented = Data()

        while open {
            // Parse as many complete frames as the buffer holds.
            while let frame = Self.parseFrame(from: &buffer) {
                switch frame.opcode {
                case 0x1, 0x0:  // text / continuation
                    fragmented.append(frame.payload)
                    if frame.fin {
                        if let text = String(data: fragmented, encoding: .utf8) {
                            onText?(text)
                        }
                        fragmented = Data()
                    }
                case 0x8:  // close
                    sendRaw(opcode: 0x8, payload: Data())
                    finish()
                    return
                case 0x9:  // ping
                    sendRaw(opcode: 0xA, payload: frame.payload)
                case 0xA:  // pong
                    break
                default:
                    finish()
                    return
                }
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 {
                finish()
                return
            }
            buffer.append(contentsOf: chunk[0..<n])
            // Bounded frames. 32 MiB accommodates a worst-case uncompressed
            // phone data snapshot (file.write envelopes); normal snapshots
            // arrive deflated and are far smaller.
            if buffer.count > 32 * 1024 * 1024 {
                finish()
                return
            }
        }
    }

    private struct Frame {
        let fin: Bool
        let opcode: UInt8
        let payload: Data
    }

    private static func parseFrame(from buffer: inout Data) -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer.prefix(14))
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = UInt64(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = length << 8 | UInt64(bytes[i]) }
            offset = 10
        }
        guard length <= 32 * 1024 * 1024 else { return Frame(fin: true, opcode: 0x8, payload: Data()) }
        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = [UInt8](buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: offset)..<buffer.index(buffer.startIndex, offsetBy: offset + 4)))
            offset += 4
        }
        let total = offset + Int(length)
        guard buffer.count >= total else { return nil }
        var payload = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: offset)..<buffer.index(buffer.startIndex, offsetBy: total))
        if masked {
            var unmasked = [UInt8](payload)
            for i in 0..<unmasked.count { unmasked[i] ^= maskKey[i % 4] }
            payload = Data(unmasked)
        }
        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: total))
        return Frame(fin: fin, opcode: opcode, payload: payload)
    }

    func send(text: String) {
        sendRaw(opcode: 0x1, payload: Data(text.utf8))
    }

    func close() {
        sendRaw(opcode: 0x8, payload: Data())
        finish()
    }

    private func finish() {
        writeLock.lock()
        let wasOpen = open
        open = false
        writeLock.unlock()
        if wasOpen {
            shutdown(fd, SHUT_RDWR)
            onClose?()
        }
    }

    private func sendRaw(opcode: UInt8, payload: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard open else { return }
        var frame = Data()
        frame.append(0x80 | opcode)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        frame.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let w = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if w <= 0 { return }
                off += w
            }
        }
    }
}
