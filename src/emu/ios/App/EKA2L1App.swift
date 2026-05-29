// Stage-2 SwiftUI shell for the EKA2L1 iOS port.
//
// scenePhase is the iOS contract for "app is foreground / background". The
// emulator must stop touching the EAGL context the moment we leave .active
// or the system will tear down our drawable and crash the next GL call.

import SwiftUI

@main
struct EKA2L1App: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Stage-1 regression hook: scripts/build_ios.sh smoke greps the
        // simulator log for the EKA2L1_SMOKE marker. runSmoke() emits that
        // marker itself (stderr + os_log + NSLog), so just fire the dyncom
        // check at launch and let the bridge do the logging.
        DispatchQueue.global(qos: .background).async {
            _ = EKA2L1Bridge.runSmoke(backend: .dyncom)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                EKA2L1Bridge.shared.resume()
            case .inactive, .background:
                EKA2L1Bridge.shared.pause()
            @unknown default:
                break
            }
        }
    }
}
