import CoreMedia
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
    /// Size of the incoming video in pixels, nil until the first stream starts.
    @Published private(set) var videoSize: CGSize?

    /// Receives decoded-ready video frames (set by the surface view).
    var videoSink: ((CMSampleBuffer) -> Void)?
    /// Called when a new video stream starts, so the view can drop the old picture.
    var onVideoReset: (() -> Void)?
    private let parser = FragmentedMP4Parser()

    private var conn: NWConnection?
    private let textContext = NWConnection.ContentContext(
        identifier: "text",
        metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]
    )

    var isLive: Bool { status == .ready }

    private func setUpParser() {
        parser.onFormat = { [weak self] size in self?.videoSize = size }
        parser.onSample = { [weak self] sample in self?.videoSink?(sample) }
    }

    func connect() {
        disconnect()
        setUpParser()
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
                self.receive(on: c)
                if Prefs.shared.displayMode == "extend" {
                    // No screen list: listing screens makes GNOME show a share dialog.
                    self.startExtend()
                } else {
                    self.sendRaw("\"GetCapturableList\"")
                }
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
        videoSize = nil
        parser.reset()
        capturables = []
        selected = nil
        extending = false
        status = .disconnected
    }

    // MARK: Extend mode (virtual display)

    /// Pixel size of the area the virtual display should fill, kept up to date by the view.
    var extendSize: CGSize? {
        didSet {
            if extending, extendSize != oldValue { startExtend() }
        }
    }
    @Published private(set) var extending = false

    /// Ask Weylus to create a virtual monitor at the iPad's resolution and stream it.
    func startExtend() {
        guard conn != nil, let size = extendSize, size.width >= 320, size.height >= 240 else { return }
        let prefs = Prefs.shared
        // even dimensions keep the encoder and every scale factor happy
        let w = Int(size.width) / 2 * 2, h = Int(size.height) / 2 * 2
        selected = nil
        extending = true
        sendRaw("""
        {"Config":{"uinput_support":true,"capturable_id":0,"capture_cursor":\(prefs.showCursor),\
        "max_width":\(w),"max_height":\(h),"client_name":"Pencil","frame_rate":\(prefs.frameRate),\
        "keyframe_interval":\(Self.keyframeInterval),"quality_qp":\(prefs.qualityQP),\
        "virtual_display":{"width":\(w),"height":\(h),"scale":\(prefs.extendScale)}}}
        """)
        sendRaw(prefs.showVideo ? "\"ResumeVideo\"" : "\"PauseVideo\"")
        status = .ready
    }

    /// Switch between mirroring and extending while connected.
    func applyDisplayMode() {
        guard conn != nil else { return }
        if Prefs.shared.displayMode == "extend" {
            startExtend()
        } else {
            extending = false
            selected = nil
            status = .connected
            sendRaw("\"GetCapturableList\"")
        }
    }

    func select(_ index: Int) {
        guard index >= 0, index < capturables.count else { return }
        extending = false
        selected = index
        Prefs.shared.capturableName = capturables[index]
        let prefs = Prefs.shared
        let config = """
        {"Config":{"uinput_support":true,"capturable_id":\(index),"capture_cursor":\(prefs.showCursor),\
        "max_width":1920,"max_height":1080,"client_name":"Pencil","frame_rate":\(prefs.frameRate),\
        "keyframe_interval":\(Self.keyframeInterval),"quality_qp":\(prefs.qualityQP)}}
        """
        sendRaw(config)
        sendRaw(prefs.showVideo ? "\"ResumeVideo\"" : "\"PauseVideo\"")
        status = .ready
    }

    /// The connection is TCP, so nothing is ever lost and keyframes are only needed to start a
    /// stream; one a minute is a safety net. Fewer keyframes = more bits for picture quality.
    private static let keyframeInterval = 1800
    private var lastKeyframeRequest = Date.distantPast

    /// Ask Weylus to restart the stream (which begins with a keyframe), at most once a second.
    func requestKeyframe() {
        guard isLive, Date().timeIntervalSince(lastKeyframeRequest) > 1 else { return }
        lastKeyframeRequest = Date()
        sendRaw("\"RestartVideo\"")
    }

    /// Apply changed video settings (on/off, frame rate, cursor) to the running stream.
    func updateVideoSettings() {
        guard isLive else { return }
        if extending {
            startExtend()
        } else if let i = selected {
            select(i)
        }
    }

    // MARK: Input

    func send(_ samples: [PenSample]) {
        guard isLive else { return }
        for s in samples { sendRaw(Self.pointerJSON(s)) }
    }

    /// A finger on the touchscreen. `size` is the contact diameter relative to the mapped area's
    /// diagonal, as Weylus' web client reports it.
    func sendTouch(type: String, id: Int, x: Double, y: Double, size: Double, touching: Bool, timestamp: UInt64) {
        guard isLive else { return }
        let button = (type == "pointerdown" || type == "pointerup") ? 1 : 0
        sendRaw("{\"PointerEvent\":{\"event_type\":\"\(type)\",\"pointer_id\":\(id),"
            + "\"timestamp\":\(timestamp),\"is_primary\":false,\"pointer_type\":\"touch\","
            + "\"button\":\(button),\"buttons\":\(touching ? 1 : 0),"
            + "\"x\":\(Self.num(x)),\"y\":\(Self.num(y)),\"pressure\":\(touching ? "0.5" : "0"),"
            + "\"tilt_x\":0,\"tilt_y\":0,\"twist\":0,"
            + "\"width\":\(Self.num(size)),\"height\":\(Self.num(size))}}")
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
                case .binary:
                    self.parser.append(data)
                case .close:
                    self.status = .failed("Weylus closed the connection")
                    self.conn = nil
                    return
                default:
                    break
                }
            }
            self.receive(on: c)
        }
    }

    private func handle(text data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
        if let msg = obj as? String, msg == "NewVideo" {
            parser.reset()
            onVideoReset?()
            return
        }
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
