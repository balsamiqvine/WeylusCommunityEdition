import SwiftUI

struct MenuView: View {
    var close: () -> Void
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var client = WeylusClient.shared

    var body: some View {
        NavigationStack {
            Form {
                connection
                video
                pressure
                smoothing
                mapping
                touch
                shortcutBar
                gestures
                Section {
                    Text("Tap Menu in the shortcut bar or four-finger tap anywhere to come back here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Weylus Pencil")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Draw", action: close)
                }
            }
        }
    }

    // MARK: Sections

    private var connection: some View {
        Section {
            Picker("Connection", selection: $prefs.connection) {
                Text("Wi-Fi").tag("wifi")
                Text("USB cable").tag("usb")
            }
            .onChange(of: prefs.connection) { client.connect() }
            if prefs.connection == "wifi" {
                TextField("Computer IP, e.g. 192.168.1.20", text: $prefs.host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            TextField("Port", value: $prefs.port, format: .number.grouping(.never))
                .keyboardType(.numberPad)
            TextField("Access code (if Weylus has one)", text: $prefs.accessCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button(client.status == .disconnected ? "Connect" : "Reconnect") {
                    client.connect()
                }
                Spacer()
                Text(statusText)
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
            }
            Picker("Mode", selection: $prefs.displayMode) {
                Text("Mirror a screen").tag("mirror")
                Text("Extend (second screen)").tag("extend")
            }
            .onChange(of: prefs.displayMode) { client.applyDisplayMode() }
            if prefs.displayMode == "extend" {
                Picker("Resolution", selection: $prefs.extendResolution) {
                    Text("Half, pixel-doubled (smooth)").tag("half")
                    Text("Native (sharpest, slower)").tag("native")
                }
                .onChange(of: prefs.extendResolution) { client.updateVideoSettings() }
            }
            if prefs.displayMode == "mirror" && !client.capturables.isEmpty {
                Picker("Screen", selection: Binding(
                    get: { client.selected ?? -1 },
                    set: { client.select($0) }
                )) {
                    if client.selected == nil {
                        Text("Choose…").tag(-1)
                    }
                    ForEach(Array(client.capturables.enumerated()), id: \.offset) { i, name in
                        Text(name).tag(i)
                    }
                }
            }
            if let err = client.lastError {
                Text("Weylus says: \(err)")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Connection")
        } footer: {
            if prefs.connection == "usb" {
                Text("Plug the iPad into the computer with a cable and start Weylus there with run-weylus.sh, which also starts the USB bridge. No Wi-Fi needed; the computer must be trusted (tap Trust on the iPad the first time).")
            }
        }
    }

    private var pressure: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 12) {
                    SliderRow(title: "Tip feel", value: $prefs.tipFeel, range: -1...1,
                              label: prefs.tipFeel < -0.01 ? "soft" : prefs.tipFeel > 0.01 ? "firm" : "linear")
                    SliderRow(title: "Full pressure at", value: $prefs.fullPressure, range: 0.1...1,
                              label: String(format: "%.0f%% force", prefs.fullPressure * 100))
                    SliderRow(title: "Light touch boost", value: $prefs.tipOffset, range: 0...0.2,
                              label: String(format: "%.1f%%", prefs.tipOffset * 100))
                }
                CurvePreview(prefs: prefs)
                    .frame(width: 120, height: 120)
            }
        } header: {
            Text("Pressure")
        } footer: {
            Text("Lower \"Full pressure at\" if you have to press hard to get thick lines. Raise \"Light touch boost\" if the faintest strokes don't register.")
        }
    }

    private var smoothing: some View {
        Section {
            SliderRow(title: "Stroke smoothing", value: $prefs.smoothing, range: 0...100,
                      label: String(format: "%.0f", prefs.smoothing))
            SliderRow(title: "Pressure smoothing", value: $prefs.pressureSmoothing, range: 0...100,
                      label: String(format: "%.0f", prefs.pressureSmoothing))
            Toggle("Curved strokes", isOn: $prefs.curves)
        } header: {
            Text("Smoothing")
        } footer: {
            Text("Smoothing removes jitter at the cost of up to ~40 ms lag at 100.")
        }
    }

    private var video: some View {
        Section {
            Toggle("Show screen", isOn: $prefs.showVideo)
            Picker("Frame rate", selection: $prefs.frameRate) {
                Text("15 fps").tag(15)
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Picture quality", selection: $prefs.qualityQP) {
                Text("Standard").tag(23)
                Text("High").tag(18)
                Text("Very high").tag(14)
            }
            Picker("Upscaling", selection: $prefs.upscaler) {
                ForEach(Upscaler.allCases, id: \.rawValue) { u in
                    Text(u.label).tag(u.rawValue)
                }
            }
            if prefs.upscaler != Upscaler.integer.rawValue {
                SliderRow(title: "Sharpening (FSR RCAS)", value: $prefs.sharpness, range: 0...1,
                          label: String(format: "%.0f%%", prefs.sharpness * 100))
            }
            Toggle("Clean colour edges", isOn: $prefs.chromaGuide)
            Toggle("Laptop cursor in video", isOn: $prefs.showCursor)
            if let size = client.videoSize {
                LabeledContent("Stream", value: "\(Int(size.width))×\(Int(size.height))")
            }
        } header: {
            Text("Video")
        } footer: {
            Text("Higher quality looks sharper but uses more Wi-Fi bandwidth when the screen changes a lot. MetalFX is Apple's equivalent of FSR 1.0's upscaler; with sharpening it matches FSR 1.0's full pipeline. Integer keeps pixels perfectly square but may leave a border. With the laptop cursor off, the iPad draws its own cursor at the Pencil with no delay, and moving it costs no video. \"Clean colour edges\" stops red/blue fringes around sharp edges. Turn the screen off to use the iPad as a plain drawing tablet.")
        }
        .onChange(of: prefs.showVideo) { client.updateVideoSettings() }
        .onChange(of: prefs.frameRate) { client.updateVideoSettings() }
        .onChange(of: prefs.showCursor) { client.updateVideoSettings() }
        .onChange(of: prefs.qualityQP) { client.updateVideoSettings() }
    }

    private var mapping: some View {
        Section {
            Picker("Computer screen shape", selection: $prefs.aspect) {
                Text("16:9").tag("16:9")
                Text("16:10").tag("16:10")
                Text("3:2").tag("3:2")
                Text("4:3").tag("4:3")
                Text("Stretch to iPad").tag("stretch")
            }
            Toggle("Send hover", isOn: $prefs.hoverEnabled)
        } header: {
            Text("Mapping")
        } footer: {
            Text("While the screen is showing, the drawing area matches the video automatically. Without it, matching your screen's shape keeps circles round; the dashed box shows the active area.")
        }
    }

    private var touch: some View {
        Section {
            Picker("Fingers", selection: $prefs.touchMode) {
                Text("Ignore").tag("off")
                Text("Tap shortcuts").tag("gestures")
                Text("Touchscreen").tag("touchscreen")
            }
            if prefs.touchMode == "gestures" {
                ShortcutField(title: "Two-finger tap", text: $prefs.twoFingerTap)
                ShortcutField(title: "Three-finger tap", text: $prefs.threeFingerTap)
            }
        } header: {
            Text("Touch")
        } footer: {
            switch prefs.touchMode {
            case "touchscreen":
                Text("Fingers act as a touchscreen on the computer, so apps with touch support (like Krita) can pan, zoom and rotate. Touches are ignored while the Pencil is drawing or hovering, and large contacts like palms are rejected.")
            case "gestures":
                Text("Finger taps trigger shortcuts on the iPad side, which works in any app. Fingers never reach the computer, so palms can't make marks.")
            default:
                Text("Fingers are ignored, except the four-finger tap for this menu.")
            }
        }
    }

    private var shortcutBar: some View {
        Section {
            Picker("Position", selection: $prefs.barSide) {
                Text("Left").tag("left")
                Text("Right").tag("right")
                Text("Hidden").tag("hidden")
            }
            NavigationLink("Buttons") {
                ControlsEditor(prefs: prefs)
            }
        } header: {
            Text("Shortcut bar")
        } footer: {
            Text("Buttons along the screen edge. \"Hold\" buttons keep their keys pressed while you touch them, so you can hold e.g. ctrl with a finger and draw with the Pencil.")
        }
    }

    private var gestures: some View {
        Section {
            ShortcutField(title: "Double-tap", text: $prefs.tapShortcut)
            ShortcutField(title: "Squeeze", text: $prefs.squeezeShortcut)
            Toggle("Hold keys while squeezing", isOn: $prefs.squeezeHold)
        } header: {
            Text("Apple Pencil gestures")
        } footer: {
            Text("Shortcuts like e, ctrl+z, ctrl+shift+z, [ or space. Leave empty to disable. \"Hold\" keeps the keys pressed for as long as you squeeze, handy for temporary tools.")
        }
    }

    private var statusText: String {
        switch client.status {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .waitingForUSB: return "Waiting for the computer over USB…"
        case .connected: return "Connected, pick a screen"
        case .ready: return client.extending ? "Live (second screen)" : "Live"
        case .failed(let msg): return msg
        }
    }

    private var statusColor: Color {
        switch client.status {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct ShortcutField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("none", text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Shortcut.parse(text) == nil && !text.isEmpty ? Color.red : Color.primary)
                .frame(maxWidth: 200)
        }
    }
}

private struct CurvePreview: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.stroke(Path(rect), with: .color(.secondary.opacity(0.4)))
            var diag = Path()
            diag.move(to: CGPoint(x: 0, y: size.height))
            diag.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.stroke(diag, with: .color(.secondary.opacity(0.3)))
            var curve = Path()
            let steps = Int(size.width)
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                let y = PressureCurve.map(raw: x, prefs: prefs)
                let pt = CGPoint(x: CGFloat(x) * size.width, y: size.height - CGFloat(y) * size.height)
                if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
            }
            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2)
        }
        .accessibilityLabel("Pressure curve preview")
    }
}

private struct ControlsEditor: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Form {
            Section {
                ForEach($prefs.controls) { $control in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Label", text: $control.label)
                            .font(.headline)
                        ShortcutField(title: "Keys", text: $control.shortcut)
                        Toggle("Hold while pressed", isOn: $control.hold)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { prefs.controls.remove(atOffsets: $0) }
                .onMove { prefs.controls.move(fromOffsets: $0, toOffset: $1) }
                Button("Add button") {
                    prefs.controls.append(ControlButton(label: "New", shortcut: "", hold: false))
                }
            } footer: {
                Text("Keys like e, ctrl+z, ctrl+shift+z, [, space or a lone modifier such as ctrl. Swipe to delete, Edit to reorder.")
            }
            Section {
                Button("Reset to defaults", role: .destructive) {
                    prefs.controls = ControlButton.defaults
                }
            }
        }
        .navigationTitle("Shortcut buttons")
        .toolbar { EditButton() }
    }
}
