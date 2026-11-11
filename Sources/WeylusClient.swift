import Foundation
import Network

/// Talks to a Weylus server over its existing WebSocket protocol (the same one the web client
/// uses), so no changes are needed on the computer.
final class WeylusClient: ObservableObject {
    static let shared = WeylusClient()

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected      // socket open, waiting for the user to pick a screen
        case ready          // config sent, input is live
        case failed(String)
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var capturables: [String] = []
    @Published private(set) var selected: Int?
    /// Non-fatal error reported by the server (input keeps working).
    @Published private(set) var lastError: String?

    private var conn: NWConnection?
    private let textContext = NWConnection.ContentContext(
        identifier: "text",
        metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]
    )

    var isLive: Bool { status == .ready }

    func connect() {
        disconnect()
        let prefs = Prefs.shared
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = prefs.host.trimmingCharacters(in: .whitespaces)
        comps.port = prefs.port
        comps.path = "/ws"
        if !prefs.accessCode.isEmpty {
            comps.queryItems = [URLQueryItem(name: "access_code", value: prefs.accessCode)]
        }
        guard !(comps.host ?? "").isEmpty, let url = comps.url else {
            status = .failed("Enter your computer's IP address")
            return
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // don't let Nagle batch up pen samples
        let params = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024 * 1024 // video chunks still arrive even while paused
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let c = NWConnection(to: .url(url), using: params)
        c.stateUpdateHandler = { [weak self] state in
            guard let self, self.conn === c else { return }
            switch state {
            case .ready:
                self.status = .connected
                self.sendRaw("\"GetCapturableList\"")
                self.receive(on: c)
            case .waiting(let err):
                self.status = .failed("Can't reach computer: \(err.localizedDescription)")
            case .failed(let err):
                self.status = .failed(err.localizedDescription)
                self.conn = nil
            default:
                break
            }
        }
        conn = c
        status = .connecting
        c.start(queue: .main)
    }

    func disconnect() {
        conn?.cancel()
        conn = nil
        lastError = nil
        capturables = []
        selected = nil
        status = .disconnected
    }

    func select(_ index: Int) {
        guard index >= 0, index < capturables.count else { return }
        selected = index
        Prefs.shared.capturableName = capturables[index]
        let config = """
        {"Config":{"uinput_support":true,"capturable_id":\(index),"capture_cursor":false,\
        "max_width":1920,"max_height":1080,"client_name":"Pencil","frame_rate":30}}
        """
        sendRaw(config)
        // Input only for now; the video stream comes later.
        sendRaw("\"PauseVideo\"")
        status = .ready
    }

    // MARK: Input

    func send(_ samples: [PenSample]) {
        guard isLive else { return }
        for s in samples { sendRaw(Self.pointerJSON(s)) }
    }

    func keyDown(_ sc: Shortcut) {
        for m in sc.modifiers { sendKey("down", m) }
        sendKey("down", sc.key)
    }

    func keyUp(_ sc: Shortcut) {
        sendKey("up", sc.key)
        for m in sc.modifiers.reversed() { sendKey("up", m) }
    }

    func press(_ sc: Shortcut) {
        keyDown(sc)
        keyUp(sc)
    }

    private func sendKey(_ type: String, _ k: Shortcut.Key) {
        guard isLive else { return }
        sendRaw("""
        {"KeyboardEvent":{"event_type":"\(type)","code":"\(k.code)","key":"\(Self.escape(k.key))",\
        "location":0,"alt":false,"ctrl":false,"shift":false,"meta":false}}
        """)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func num(_ v: Double) -> String {
        v.isFinite ? String(format: "%.6f", v) : "0"
    }

    static func pointerJSON(_ s: PenSample) -> String {
        // Matches the web client: `button` is the button that changed (primary on down/up),
        // `buttons` is what's currently pressed. buttons == 0 while hovering.
        let button = (s.type == "pointerdown" || s.type == "pointerup") ? 1 : 0
        let buttons = s.touching ? 1 : 0
        return "{\"PointerEvent\":{\"event_type\":\"\(s.type)\",\"pointer_id\":1,"
            + "\"timestamp\":\(s.timestamp),\"is_primary\":true,\"pointer_type\":\"pen\","
            + "\"button\":\(button),\"buttons\":\(buttons),"
            + "\"x\":\(num(s.x)),\"y\":\(num(s.y)),\"pressure\":\(num(s.pressure)),"
            + "\"tilt_x\":\(s.tiltX),\"tilt_y\":\(s.tiltY),\"twist\":\(s.twist),"
            + "\"width\":0,\"height\":0}}"
    }

    // MARK: Socket plumbing

    private func sendRaw(_ text: String) {
        guard let c = conn else { return }
        c.send(content: Data(text.utf8), contentContext: textContext, isComplete: true, completion: .idempotent)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self, self.conn === c else { return }
            if let error {
                self.status = .failed(error.localizedDescription)
                return
            }
            if let data,
               let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text:
                    self.handle(text: data)
                case .close:
                    self.status = .failed("Weylus closed the connection")
                    self.conn = nil
                    return
                default:
                    break // binary = video, ignored for now
                }
            }
            self.receive(on: c)
        }
    }

    private func handle(text data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
        if let dict = obj as? [String: Any] {
            if let list = dict["CapturableList"] as? [String] {
                capturables = list
                // Reconnect straight into the screen picked last time.
                if selected == nil, let i = list.firstIndex(of: Prefs.shared.capturableName) {
                    select(i)
                }
            } else if let err = dict["ConfigError"] as? String {
                status = .failed(err)
            } else if let err = dict["Error"] as? String {
                lastError = err
            }
        }
    }
}
