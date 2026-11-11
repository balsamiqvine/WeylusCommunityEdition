import UIKit
import Combine

/// Full-screen surface that turns Apple Pencil and finger input into Weylus events, shows the
/// computer's screen and hosts the shortcut bar.
final class PencilSurfaceView: UIView, UIPencilInteractionDelegate {
    var onMenuGesture: (() -> Void)?

    private let filter = StrokeFilter()
    private let client = WeylusClient.shared
    private let prefs = Prefs.shared
    private let areaLayer = CAShapeLayer()
    private let videoView = MetalVideoView()
    private let decoder = H264Decoder()
    private let bar = ShortcutBarView()
    private var activeTouch: UITouch?
    /// Fingers currently forwarded to the computer, with their Weylus pointer ids.
    private var fingers: [ObjectIdentifier: Int] = [:]
    private var nextFingerID = 100
    private var lastPencilActivity = Date.distantPast
    private var twoFingerTap: UITapGestureRecognizer!
    private var threeFingerTap: UITapGestureRecognizer!
    private var hovering = false
    private var lastHover: PenSample?
    private var cancellables = Set<AnyCancellable>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        isMultipleTouchEnabled = true

        addSubview(videoView)
        addSubview(bar)
        bar.onMenu = { [weak self] in self?.onMenuGesture?() }
        decoder.onFrame = { [weak self] pb in self?.videoView.display(pb) }
        decoder.onError = { [weak self] in
            DispatchQueue.main.async { self?.client.requestKeyframe() }
        }
        client.videoSink = { [weak self] sample in self?.decoder.decode(sample) }
        client.onVideoReset = { [weak self] in
            self?.decoder.reset()
            self?.videoView.clear()
        }
        Publishers.CombineLatest3(prefs.$upscaler, prefs.$sharpness, prefs.$chromaGuide)
            .sink { [weak self] upscaler, sharpness, chromaGuide in
                self?.videoView.settings = RenderSettings(
                    upscaler: Upscaler(rawValue: upscaler) ?? .metalfx,
                    sharpness: Float(sharpness),
                    chromaGuide: chromaGuide
                )
                // integer scaling changes the picture's size
                DispatchQueue.main.async { self?.setNeedsLayout() }
            }
            .store(in: &cancellables)

        areaLayer.fillColor = UIColor.clear.cgColor
        areaLayer.strokeColor = UIColor(white: 1, alpha: 0.25).cgColor
        areaLayer.lineWidth = 1
        areaLayer.lineDashPattern = [6, 6]
        layer.addSublayer(areaLayer)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)

        func fingerTap(_ n: Int, _ action: Selector) -> UITapGestureRecognizer {
            let g = UITapGestureRecognizer(target: self, action: action)
            g.numberOfTouchesRequired = n
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            g.cancelsTouchesInView = false
            addGestureRecognizer(g)
            return g
        }
        let menuTap = fingerTap(4, #selector(onMenuTap))
        threeFingerTap = fingerTap(3, #selector(onThreeFingerTap))
        twoFingerTap = fingerTap(2, #selector(onTwoFingerTap))
        twoFingerTap.require(toFail: threeFingerTap)
        threeFingerTap.require(toFail: menuTap)

        let relayout: (Any) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.setNeedsLayout() }
        }
        prefs.$aspect.sink(receiveValue: relayout).store(in: &cancellables)
        prefs.$showVideo.sink(receiveValue: relayout).store(in: &cancellables)
        prefs.$barSide.sink(receiveValue: relayout).store(in: &cancellables)
        prefs.$touchMode
            .sink { [weak self] mode in
                // Gestures are recognised on the iPad only in "gestures" mode; in touchscreen
                // mode the computer's app gets the raw touches and handles gestures itself.
                self?.twoFingerTap.isEnabled = mode == "gestures"
                self?.threeFingerTap.isEnabled = mode == "gestures"
                if mode != "touchscreen" { self?.cancelFingers() }
            }
            .store(in: &cancellables)
        client.$videoSize.sink(receiveValue: relayout).store(in: &cancellables)
    }

    @objc private func onMenuTap() {
        onMenuGesture?()
    }

    @objc private func onTwoFingerTap() {
        if let sc = Shortcut.parse(prefs.twoFingerTap) { client.press(sc) }
    }

    @objc private func onThreeFingerTap() {
        if let sc = Shortcut.parse(prefs.threeFingerTap) { client.press(sc) }
    }

    // MARK: Mapping

    /// Width / height of what's being mapped: the video if it's showing, else the manual setting.
    private var targetAspect: Double? {
        if prefs.showVideo, let v = client.videoSize, v.width > 0, v.height > 0 {
            return Double(v.width / v.height)
        }
        return prefs.aspectRatio
    }

    /// The part of the iPad that maps onto the computer's screen. Matching the screen's shape
    /// keeps circles round; the rest of the iPad is dead space.
    /// Everything except the shortcut bar.
    private var contentRect: CGRect {
        switch prefs.barSide {
        case "left":
            return bounds.inset(by: UIEdgeInsets(top: 0, left: ShortcutBarView.width, bottom: 0, right: 0))
        case "right":
            return bounds.inset(by: UIEdgeInsets(top: 0, left: 0, bottom: 0, right: ShortcutBarView.width))
        default:
            return bounds
        }
    }

    private var activeArea: CGRect {
        let b = contentRect
        // Pixel-perfect mode: the largest whole-number multiple of the video that fits, aligned
        // to the screen's pixel grid. Falls back to a normal fit if even 1x doesn't fit.
        if prefs.upscaler == Upscaler.integer.rawValue, prefs.showVideo,
           let v = client.videoSize, v.width > 0, v.height > 0 {
            let scale = window?.screen.scale ?? UIScreen.main.scale
            let k = floor(min(b.width * scale / v.width, b.height * scale / v.height))
            if k >= 1 {
                let w = v.width * k / scale, h = v.height * k / scale
                let x = ((b.midX - w / 2) * scale).rounded() / scale
                let y = ((b.midY - h / 2) * scale).rounded() / scale
                return CGRect(x: x, y: y, width: w, height: h)
            }
        }
        guard let a = targetAspect, b.width > 0, b.height > 0 else { return b }
        if b.width / b.height > a {
            let w = b.height * a
            return CGRect(x: b.midX - w / 2, y: b.minY, width: w, height: b.height)
        } else {
            let h = b.width / a
            return CGRect(x: b.minX, y: b.midY - h / 2, width: b.width, height: h)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        areaLayer.frame = bounds
        bar.isHidden = prefs.barSide == "hidden"
        bar.frame = prefs.barSide == "right"
            ? CGRect(x: bounds.maxX - ShortcutBarView.width, y: 0, width: ShortcutBarView.width, height: bounds.height)
            : CGRect(x: 0, y: 0, width: ShortcutBarView.width, height: bounds.height)
        let area = activeArea
        let videoShowing = prefs.showVideo && client.videoSize != nil
        videoView.frame = area
        videoView.isHidden = !prefs.showVideo
        // The video itself shows where the screen is; only outline the area without it.
        areaLayer.path = area == contentRect || videoShowing
            ? nil
            : UIBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5)).cgPath
    }

    private func normalized(_ p: CGPoint) -> (Double, Double) {
        let a = activeArea
        let x = Double((p.x - a.minX) / a.width)
        let y = Double((p.y - a.minY) / a.height)
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    /// Altitude/azimuth -> PointerEvent tiltX/tiltY in degrees (W3C Pointer Events conversion).
    private static func tilt(altitude: CGFloat, azimuth: CGFloat) -> (Int, Int) {
        let alt = Double(altitude), az = Double(azimuth)
        if alt >= .pi / 2 - 1e-6 { return (0, 0) }
        let t = tan(max(alt, 1e-6))
        let tx = atan(cos(az) / t) * 180 / .pi
        let ty = atan(sin(az) / t) * 180 / .pi
        return (Int(tx.rounded()), Int(ty.rounded()))
    }

    private static func degrees(_ radians: CGFloat) -> Int {
        var d = Int((Double(radians) * 180 / .pi).rounded()) % 360
        if d < 0 { d += 360 }
        return d
    }

    private func sample(_ t: UITouch, type: String, touching: Bool) -> PenSample {
        let (x, y) = normalized(t.preciseLocation(in: self))
        let maxForce = t.maximumPossibleForce
        let raw = maxForce > 0 ? Double(t.force / maxForce) : 0
        let (tx, ty) = Self.tilt(altitude: t.altitudeAngle, azimuth: t.azimuthAngle(in: self))
        return PenSample(
            type: type, x: x, y: y, pressure: raw,
            tiltX: tx, tiltY: ty, twist: Self.degrees(t.rollAngle),
            timestamp: UInt64(max(t.timestamp, 0) * 1_000_000),
            touching: touching
        )
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if t.type == .pencil {
                pencilBegan(t)
            } else if t.type == .direct {
                fingerBegan(t)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = activeTouch, touches.contains(t) {
            let size = activeArea.size
            // Coalesced touches carry every 240 Hz sample, not just one per display frame.
            let all = event?.coalescedTouches(for: t) ?? [t]
            var out: [PenSample] = []
            for c in all {
                out += filter.move(sample(c, type: "pointermove", touching: true), size: size)
            }
            client.send(out)
            lastPencilActivity = Date()
        }
        for t in touches where fingers[ObjectIdentifier(t)] != nil {
            sendFinger(t, type: "pointermove", touching: true)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, type: "pointerup")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, type: "pointercancel")
    }

    private func finish(_ touches: Set<UITouch>, type: String) {
        if let t = activeTouch, touches.contains(t) {
            activeTouch = nil
            lastPencilActivity = Date()
            client.send(filter.up(sample(t, type: type, touching: false), size: activeArea.size))
        }
        for t in touches where fingers[ObjectIdentifier(t)] != nil {
            sendFinger(t, type: type, touching: false)
            fingers[ObjectIdentifier(t)] = nil
        }
    }

    private func pencilBegan(_ t: UITouch) {
        guard activeTouch == nil else { return }
        // A palm usually lands just before the Pencil does; drop any fingers still down.
        cancelFingers()
        activeTouch = t
        hovering = false
        lastPencilActivity = Date()
        client.send(filter.down(sample(t, type: "pointerdown", touching: true)))
    }

    // MARK: Fingers (touchscreen mode)

    private func fingerBegan(_ t: UITouch) {
        guard prefs.touchMode == "touchscreen" else { return }
        // Palm rejection: ignore fingers while the Pencil is drawing or was just used/hovering,
        // and contacts too large to be a fingertip.
        guard activeTouch == nil,
              Date().timeIntervalSince(lastPencilActivity) > 0.5,
              t.majorRadius < 35,
              activeArea.contains(t.location(in: self)),
              fingers.count < 5 else { return }
        fingers[ObjectIdentifier(t)] = nextFingerID
        nextFingerID += 1
        sendFinger(t, type: "pointerdown", touching: true)
    }

    private func sendFinger(_ t: UITouch, type: String, touching: Bool) {
        guard let id = fingers[ObjectIdentifier(t)] else { return }
        let area = activeArea
        let (x, y) = normalized(t.location(in: self))
        let diagonal = hypot(area.width, area.height)
        client.sendTouch(
            type: type, id: id, x: x, y: y,
            size: diagonal > 0 ? Double(t.majorRadius * 2 / diagonal) : 0,
            touching: touching,
            timestamp: UInt64(max(t.timestamp, 0) * 1_000_000)
        )
    }

    private func cancelFingers() {
        let now = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        for id in fingers.values {
            client.sendTouch(type: "pointercancel", id: id, x: 0, y: 0, size: 0, touching: false, timestamp: now)
        }
        fingers.removeAll()
    }

    // MARK: Hover (M2+ iPad Pro)

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        guard prefs.hoverEnabled, activeTouch == nil else { return }
        switch g.state {
        case .began, .changed:
            let (x, y) = normalized(g.location(in: self))
            let (tx, ty) = Self.tilt(altitude: g.altitudeAngle, azimuth: g.azimuthAngle(in: self))
            let s = PenSample(
                type: "pointermove", x: x, y: y, pressure: 0,
                tiltX: tx, tiltY: ty, twist: Self.degrees(g.rollAngle),
                timestamp: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000),
                touching: false
            )
            hovering = true
            lastHover = s
            lastPencilActivity = Date()
            client.send([s])
        case .ended, .cancelled:
            if hovering, var s = lastHover {
                s.type = "pointerleave"
                s.timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
                client.send([s])
            }
            hovering = false
        default:
            break
        }
    }

    // MARK: Pencil Pro gestures

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        if let sc = Shortcut.parse(prefs.tapShortcut) {
            client.press(sc)
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard let sc = Shortcut.parse(prefs.squeezeShortcut) else { return }
        if prefs.squeezeHold {
            switch squeeze.phase {
            case .began: client.keyDown(sc)
            case .ended, .cancelled: client.keyUp(sc)
            default: break
            }
        } else if squeeze.phase == .ended {
            client.press(sc)
        }
    }
}
