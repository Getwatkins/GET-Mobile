import SwiftUI

@main
struct GETMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
            // Keep the screen from auto-locking while GET Mobile is in the
            // foreground. Mainly for flashing - a lock mid-write would be a
            // genuinely bad interruption, not just an inconvenience - but
            // this also keeps long HSL/standard logging sessions running
            // without the screen dimming/locking mid-drive. Only active
            // while actually in the foreground: backgrounding the app (or
            // switching away) lets the phone lock normally again, so this
            // doesn't drain the battery or override the user's lock
            // settings any time they're not actually using the app.
            UIApplication.shared.isIdleTimerDisabled = (newPhase == .active)
        }
    }
}
