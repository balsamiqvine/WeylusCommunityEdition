import UIKit
import Combine

/// Full-screen surface that turns Apple Pencil input into Weylus pen events.
/// Fingers are ignored (no palm problems), except a three-finger tap which opens the menu.
final class PencilSurfaceView: UIView, UIPencilInteractionDelegate {
    var onMenuGesture: (() -> Void)?

    private let filter = StrokeFilter()
    private let client = WeylusClient.shared
    private let prefs = Prefs.shared
    private let areaLayer = CAShapeLayer()
    private let videoView = VideoLayerView()
    private var activeTouch: UITouch?
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
        client.videoSink = { [weak self] sample in self?.videoView.enqueue(sample) }
        client.onVideoReset = { [weak self] in self?.videoView.clear() }

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

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(onMenuTap))
        menuTap.numberOfTouchesRequired = 3
        menuTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        menuTap.cancelsTouchesInView = false
        addGestureRecognizer(menuTap)

        let relayout: (Any) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.setNeedsLayout() }
        }
        prefs.$aspect.sink(receiveValue: relayout).store(in: &cancellables)
        prefs.$showVideo.sink(receiveValue: relayout).store(in: &cancellables)
        client.$videoSize.sink(receiveValue: relayout).store(in: &cancellables)
    }

    @objc private func onMenuTap() {
        onMenuGesture?()
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
    private var activeArea: CGRect {
        let b = bounds
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
        let area = activeArea
        let videoShowing = prefs.showVideo && client.videoSize != nil
        videoView.frame = area
        videoView.isHidden = !prefs.showVideo
        // The video itself shows where the screen is; only outline the area without it.
        areaLayer.path = area == bounds || videoShowing
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

    // MARK: Touches (pencil only)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let t = touches.first(where: { $0.type == .pencil }) else { return }
        activeTouch = t
        hovering = false
        client.send(filter.down(sample(t, type: "pointerdown", touching: true)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = activeTouch, touches.contains(t) else { return }
        let size = activeArea.size
        // Coalesced touches carry every 240 Hz sample, not just one per display frame.
        let all = event?.coalescedTouches(for: t) ?? [t]
        var out: [PenSample] = []
        for c in all {
            out += filter.move(sample(c, type: "pointermove", touching: true), size: size)
        }
        client.send(out)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, type: "pointerup")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, type: "pointercancel")
    }

    private func finish(_ touches: Set<UITouch>, type: String) {
        guard let t = activeTouch, touches.contains(t) else { return }
        activeTouch = nil
        client.send(filter.up(sample(t, type: type, touching: false), size: activeArea.size))
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
