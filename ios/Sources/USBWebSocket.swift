import Foundation
import Network

/// WebSocket *client* running over a TCP connection that the computer opened to us.
///
/// Over USB, iOS only lets the computer connect to the iPad (through usbmuxd), not the other way
/// around. So in USB mode the app listens on a port, the bridge on the computer connects in and
/// relays to Weylus, and we speak the client side of the WebSocket protocol (RFC 6455) over that
/// accepted connection: HTTP upgrade request, masked frames out, unmasked frames in.
final class USBWebSocket {
    var onOpen: (() -> Void)?
    var onText: ((Data) -> Void)?
    var onBinary: ((Data) -> Void)?
    /// The connection to the computer went away; the listener keeps running for the next one.
    var onClose: ((String?) -> Void)?

    private let port: UInt16
    private let requestPath: String
    private var listener: NWListener?
    private var conn: NWConnection?
    private var handshakeDone = false
    private var buffer: [UInt8] = []
    private var readOffset = 0
    private var fragment: [UInt8]?
    private var fragmentOpcode: UInt8 = 0

    init(port: UInt16, requestPath: String) {
        self.port = port
        self.requestPath = requestPath
    }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        drop(nil, notify: false)
    }

    // MARK: Connection

    private func accept(_ c: NWConnection) {
        guard conn == nil else {
            c.cancel() // one computer at a time
            return
        }
        conn = c
        handshakeDone = false
        buffer = []
        readOffset = 0
        fragment = nil
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.conn === c else { return }
            switch state {
            case .ready:
                self.sendHandshake()
            case .failed(let err):
                self.drop(err.localizedDescription)
            case .cancelled:
                self.drop(nil)
            default:
                break
            }
        }
        c.start(queue: .main)
        receive(on: c)
    }

    private func drop(_ reason: String?, notify: Bool = true) {
        guard let c = conn else { return }
        conn = nil
        c.cancel()
        if notify { onClose?(reason) }
    }

    private func sendHandshake() {
        var key = [UInt8](repeating: 0, count: 16)
        for i in key.indices { key[i] = UInt8.random(in: 0...255) }
        let request = "GET \(requestPath) HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: \(Data(key).base64EncodedString())\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        conn?.send(content: Data(request.utf8), completion: .idempotent)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.process()
            }
            if let error {
                self.drop(error.localizedDescription)
            } else if isComplete {
                self.drop(nil)
            } else if self.conn === c {
                self.receive(on: c)
            }
        }
    }

    // MARK: Protocol

    private var available: Int { buffer.count - readOffset }

    private func process() {
        if !handshakeDone {
            // look for the end of the HTTP response headers
            let terminator: [UInt8] = [13, 10, 13, 10]
            guard let end = findSequence(terminator) else { return }
            let header = String(decoding: buffer[readOffset..<end], as: UTF8.self)
            readOffset = end + 4
            guard header.hasPrefix("HTTP/1.1 101") else {
                let status = header.split(separator: "\r\n").first.map(String.init) ?? "no response"
                drop("Weylus refused the connection (\(status))")
                return
            }
            handshakeDone = true
            onOpen?()
        }
        while parseFrame() {}
        // compact the buffer now and then instead of shifting it for every frame
        if readOffset > 0 && (readOffset > 1 << 20 || readOffset == buffer.count) {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
    }

    private func findSequence(_ seq: [UInt8]) -> Int? {
        guard available >= seq.count else { return nil }
        var i = readOffset
        while i + seq.count <= buffer.count {
            if buffer[i] == seq[0] && Array(buffer[i..<(i + seq.count)]) == seq { return i }
            i += 1
        }
        return nil
    }

    /// Parse one complete frame if available. Returns false when more data is needed.
    private func parseFrame() -> Bool {
        guard available >= 2 else { return false }
        let o = readOffset
        let b0 = buffer[o], b1 = buffer[o + 1]
        let fin = b0 & 0x80 != 0
        let opcode = b0 & 0x0f
        let masked = b1 & 0x80 != 0
        var length = Int(b1 & 0x7f)
        var header = 2
        if length == 126 {
            guard available >= 4 else { return false }
            length = Int(buffer[o + 2]) << 8 | Int(buffer[o + 3])
            header = 4
        } else if length == 127 {
            guard available >= 10 else { return false }
            length = 0
            for i in 0..<8 { length = length << 8 | Int(buffer[o + 2 + i]) }
            header = 10
        }
        var maskKey: [UInt8] = []
        if masked {
            guard available >= header + 4 else { return false }
            maskKey = Array(buffer[(o + header)..<(o + header + 4)])
            header += 4
        }
        guard length >= 0, available >= header + length else { return false }
        var payload = Array(buffer[(o + header)..<(o + header + length)])
        if masked {
            for i in payload.indices { payload[i] ^= maskKey[i & 3] }
        }
        readOffset += header + length

        switch opcode {
        case 0x0: // continuation
            fragment?.append(contentsOf: payload)
            if fin, let whole = fragment {
                deliver(fragmentOpcode, whole)
                fragment = nil
            }
        case 0x1, 0x2:
            if fin {
                deliver(opcode, payload)
            } else {
                fragment = payload
                fragmentOpcode = opcode
            }
        case 0x8: // close
            sendFrame(opcode: 0x8, payload: [])
            drop(nil)
            return false
        case 0x9: // ping
            sendFrame(opcode: 0xA, payload: payload)
        default:
            break // pong / reserved
        }
        return conn != nil
    }

    private func deliver(_ opcode: UInt8, _ payload: [UInt8]) {
        if opcode == 0x1 {
            onText?(Data(payload))
        } else {
            onBinary?(Data(payload))
        }
    }

    // MARK: Sending

    func send(text: String) {
        sendFrame(opcode: 0x1, payload: Array(text.utf8))
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8]) {
        guard let conn, handshakeDone else { return }
        var frame: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            frame.append(0x80 | UInt8(n))
        } else if n < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8(n >> 8))
            frame.append(UInt8(n & 0xff))
        } else {
            frame.append(0x80 | 127)
            for i in (0..<8).reversed() { frame.append(UInt8((n >> (8 * i)) & 0xff)) }
        }
        // clients must mask every frame they send
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.reserveCapacity(frame.count + n)
        for (i, b) in payload.enumerated() { frame.append(b ^ mask[i & 3]) }
        conn.send(content: Data(frame), completion: .idempotent)
    }
}
