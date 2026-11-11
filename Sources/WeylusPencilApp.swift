import SwiftUI

@main
struct WeylusPencilApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var showMenu = true
    @ObservedObject private var client = WeylusClient.shared

    var body: some View {
        PencilSurface(onMenu: { showMenu = true })
            .ignoresSafeArea()
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .defersSystemGestures(on: .all) // don't let edge swipes eat strokes near the border
            .overlay(alignment: .top) {
                if !showMenu && !client.isLive {
                    Text("Not connected. Tap Menu or four-finger tap for the menu.")
                        .font(.footnote)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                }
            }
            .sheet(isPresented: $showMenu) {
                MenuView(close: { showMenu = false })
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                if !Prefs.shared.host.isEmpty {
                    client.connect()
                }
            }
    }
}

struct PencilSurface: UIViewRepresentable {
    var onMenu: () -> Void

    func makeUIView(context: Context) -> PencilSurfaceView {
        let v = PencilSurfaceView()
        v.onMenuGesture = onMenu
        return v
    }

    func updateUIView(_ v: PencilSurfaceView, context: Context) {
        v.onMenuGesture = onMenu
    }
}
