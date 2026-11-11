import Foundation
import Combine

/// User settings, persisted in UserDefaults. Read directly from the input path on the main thread.
final class Prefs: ObservableObject {
    static let shared = Prefs()

    // Connection
    @Published var host: String { didSet { save(host, "host") } }
    @Published var port: Int { didSet { save(port, "port") } }
    @Published var accessCode: String { didSet { save(accessCode, "accessCode") } }
    @Published var capturableName: String { didSet { save(capturableName, "capturableName") } }

    // Pressure
    /// -1 (soft) ... 1 (firm). Same curve family as GNOME's "Tip Pressure Feel".
    @Published var tipFeel: Double { didSet { save(tipFeel, "tipFeel") } }
    /// Raw pressure (force / max force) that already counts as 100%.
    @Published var fullPressure: Double { didSet { save(fullPressure, "fullPressure") } }
    /// Minimum pressure reported while the tip is down, so the lightest touch clears libinput's threshold.
    @Published var tipOffset: Double { didSet { save(tipOffset, "tipOffset") } }

    // Smoothing
    @Published var smoothing: Double { didSet { save(smoothing, "smoothing") } }
    @Published var pressureSmoothing: Double { didSet { save(pressureSmoothing, "pressureSmoothing") } }
    @Published var curves: Bool { didSet { save(curves, "curves") } }

    // Mapping
    /// "stretch" or "w:h" of the computer's screen, used to keep circles round.
    @Published var aspect: String { didSet { save(aspect, "aspect") } }
    @Published var hoverEnabled: Bool { didSet { save(hoverEnabled, "hoverEnabled") } }

    // Video
    @Published var showVideo: Bool { didSet { save(showVideo, "showVideo") } }
    @Published var frameRate: Int { didSet { save(frameRate, "frameRate") } }
    @Published var showCursor: Bool { didSet { save(showCursor, "showCursor") } }
    /// Encoder quantizer: lower is sharper but needs more bandwidth.
    @Published var qualityQP: Int { didSet { save(qualityQP, "qualityQP") } }
    /// Upscaling algorithm, see `Upscaler`.
    @Published var upscaler: String { didSet { save(upscaler, "upscaler") } }
    /// FSR 1.0 RCAS sharpening strength, 0...1.
    @Published var sharpness: Double { didSet { save(sharpness, "sharpness") } }
    /// Luma-guided chroma upsampling (removes red/blue fringes on sharp edges).
    @Published var chromaGuide: Bool { didSet { save(chromaGuide, "chromaGuide") } }

    // Touch and on-screen controls
    /// "off", "touchscreen" (fingers go to the computer as multitouch) or "gestures"
    /// (finger taps trigger shortcuts on the iPad side).
    @Published var touchMode: String { didSet { save(touchMode, "touchMode") } }
    @Published var twoFingerTap: String { didSet { save(twoFingerTap, "twoFingerTap") } }
    @Published var threeFingerTap: String { didSet { save(threeFingerTap, "threeFingerTap") } }
    /// "left", "right" or "hidden"
    @Published var barSide: String { didSet { save(barSide, "barSide") } }
    @Published var controls: [ControlButton] {
        didSet {
            if let data = try? JSONEncoder().encode(controls) { save(data, "controls") }
        }
    }

    // Pencil Pro gestures
    @Published var tapShortcut: String { didSet { save(tapShortcut, "tapShortcut") } }
    @Published var squeezeShortcut: String { didSet { save(squeezeShortcut, "squeezeShortcut") } }
    @Published var squeezeHold: Bool { didSet { save(squeezeHold, "squeezeHold") } }

    private init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        port = d.object(forKey: "port") as? Int ?? 1701
        accessCode = d.string(forKey: "accessCode") ?? ""
        capturableName = d.string(forKey: "capturableName") ?? ""
        tipFeel = d.object(forKey: "tipFeel") as? Double ?? 0
        fullPressure = d.object(forKey: "fullPressure") as? Double ?? 0.45
        tipOffset = d.object(forKey: "tipOffset") as? Double ?? 0.03
        smoothing = d.object(forKey: "smoothing") as? Double ?? 30
        pressureSmoothing = d.object(forKey: "pressureSmoothing") as? Double ?? 30
        curves = d.object(forKey: "curves") as? Bool ?? true
        aspect = d.string(forKey: "aspect") ?? "16:9"
        hoverEnabled = d.object(forKey: "hoverEnabled") as? Bool ?? true
        showVideo = d.object(forKey: "showVideo") as? Bool ?? true
        frameRate = d.object(forKey: "frameRate") as? Int ?? 30
        showCursor = d.object(forKey: "showCursor") as? Bool ?? true
        qualityQP = d.object(forKey: "qualityQP") as? Int ?? 18
        upscaler = d.string(forKey: "upscaler") ?? Upscaler.metalfx.rawValue
        sharpness = d.object(forKey: "sharpness") as? Double ?? 0.25
        chromaGuide = d.object(forKey: "chromaGuide") as? Bool ?? true
        touchMode = d.string(forKey: "touchMode") ?? "gestures"
        twoFingerTap = d.string(forKey: "twoFingerTap") ?? "ctrl+z"
        threeFingerTap = d.string(forKey: "threeFingerTap") ?? "ctrl+shift+z"
        barSide = d.string(forKey: "barSide") ?? "left"
        controls = d.data(forKey: "controls")
            .flatMap { try? JSONDecoder().decode([ControlButton].self, from: $0) }
            ?? ControlButton.defaults
        tapShortcut = d.string(forKey: "tapShortcut") ?? "e"
        squeezeShortcut = d.string(forKey: "squeezeShortcut") ?? "ctrl+z"
        squeezeHold = d.object(forKey: "squeezeHold") as? Bool ?? false
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Width / height of the computer's screen, or nil to stretch over the whole iPad.
    var aspectRatio: Double? {
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }
}
