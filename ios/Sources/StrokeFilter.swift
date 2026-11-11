import Foundation
import CoreGraphics

/// One pen sample in Weylus' coordinate space: x/y normalized to 0...1 over the mapped area.
struct PenSample {
    var type: String          // pointerdown / pointermove / pointerup / pointercancel / pointerleave
    var x: Double
    var y: Double
    var pressure: Double
    var tiltX: Int
    var tiltY: Int
    var twist: Int
    var timestamp: UInt64     // microseconds
    var touching: Bool
}

enum PressureCurve {
    private static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    /// Cubic bezier from (0,0) to (1,1), the same family xsetwacom's PressureCurve and GNOME's
    /// "Tip Pressure Feel" use: control points (0,a),(1-a,1) for soft, (a,0),(1,1-a) for firm.
    static func apply(_ x: Double, feel: Double) -> Double {
        if feel == 0 { return x }
        let a = 0.75 * abs(feel)
        let (x1, y1, x2, y2) = feel < 0 ? (0, a, 1 - a, 1.0) : (a, 0, 1.0, 1 - a)
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {
            t = (lo + hi) / 2
            if bezier(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return bezier(t, y1, y2)
    }

    /// Raw pressure (force / maximum possible force) -> pressure sent to the host.
    static func map(raw: Double, prefs: Prefs = .shared) -> Double {
        var p = min(max(raw / max(prefs.fullPressure, 0.01), 0), 1)
        p = apply(p, feel: prefs.tipFeel)
        return prefs.tipOffset + (1 - prefs.tipOffset) * p
    }
}

/// Pressure mapping, exponential smoothing and Catmull-Rom interpolation for one stroke at a time.
/// Mirrors the StylusFilter in the Weylus web client so both behave the same.
final class StrokeFilter {
    static let maxTauMs = 40.0

    private var touching = false
    private var sx = 0.0, sy = 0.0, sp = 0.0
    private var lastTs: UInt64 = 0
    private var pts: [PenSample] = []

    func down(_ sample: PenSample) -> [PenSample] {
        var s = sample
        s.pressure = PressureCurve.map(raw: s.pressure)
        touching = true
        sx = s.x; sy = s.y; sp = s.pressure
        lastTs = s.timestamp
        pts = [s]
        return [s]
    }

    /// `size` is the mapped area in points, used to decide how finely to subdivide curves.
    func move(_ sample: PenSample, size: CGSize) -> [PenSample] {
        guard touching else { return [sample] }
        var s = sample
        s.pressure = PressureCurve.map(raw: s.pressure)
        let dtMs = max(Double(Int64(s.timestamp) - Int64(lastTs)) / 1000, 0.5)
        lastTs = s.timestamp
        func alpha(_ strength: Double) -> Double {
            let tau = strength / 100 * StrokeFilter.maxTauMs
            return tau <= 0 ? 1 : 1 - exp(-dtMs / tau)
        }
        let prefs = Prefs.shared
        let aPos = alpha(prefs.smoothing)
        let aP = alpha(prefs.pressureSmoothing)
        sx += aPos * (s.x - sx)
        sy += aPos * (s.y - sy)
        sp += aP * (s.pressure - sp)
        s.x = sx; s.y = sy; s.pressure = sp
        guard prefs.curves else { return [s] }
        pts.append(s)
        if pts.count > 4 { pts.removeFirst() }
        // One sample of lag: emit the segment between the previous two points now that the
        // direction the stroke continues in is known.
        guard pts.count >= 3 else { return [] }
        let n = pts.count
        return segment(pts[max(n - 4, 0)], pts[n - 3], pts[n - 2], pts[n - 1], size: size)
    }

    func up(_ sample: PenSample, size: CGSize) -> [PenSample] {
        guard touching else { return [sample] }
        touching = false
        var out: [PenSample] = []
        let n = pts.count
        if Prefs.shared.curves && n >= 2 {
            let last = pts[n - 1]
            out = segment(pts[max(n - 3, 0)], pts[n - 2], last, last, size: size)
        }
        // Lift off where the smoothed stroke ended to avoid a hook at the end of every stroke.
        var s = sample
        s.x = sx; s.y = sy
        pts = []
        out.append(s)
        return out
    }

    private func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        let a = 2 * p1
        let b = (-p0 + p2) * t
        let c = (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
        let d = (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        return 0.5 * (a + b + c + d)
    }

    /// Points on the curve from p1 (exclusive) to p2 (inclusive).
    private func segment(_ p0: PenSample, _ p1: PenSample, _ p2: PenSample, _ p3: PenSample, size: CGSize) -> [PenSample] {
        let dist = hypot((p2.x - p1.x) * Double(size.width), (p2.y - p1.y) * Double(size.height))
        let steps = min(max(Int((dist / 4).rounded(.up)), 1), 8)
        var out: [PenSample] = []
        out.reserveCapacity(steps)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            var e = p2
            e.type = "pointermove"
            e.x = catmullRom(p0.x, p1.x, p2.x, p3.x, t)
            e.y = catmullRom(p0.y, p1.y, p2.y, p3.y, t)
            e.pressure = min(max(lerp(p1.pressure, p2.pressure), 0), 1)
            e.tiltX = Int(lerp(Double(p1.tiltX), Double(p2.tiltX)).rounded())
            e.tiltY = Int(lerp(Double(p1.tiltY), Double(p2.tiltY)).rounded())
            e.timestamp = UInt64(lerp(Double(p1.timestamp), Double(p2.timestamp)).rounded())
            out.append(e)
        }
        return out
    }
}
