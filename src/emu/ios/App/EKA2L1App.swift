// Stage-0 SwiftUI shell for the EKA2L1 iOS port.
//
// This is intentionally minimal: it brings up a single window that proves the
// app launches on device and simulator. The real launcher / device picker /
// app list will land in stage 2 alongside the Obj-C++ bridges in Bridge/.

import SwiftUI

@main
struct EKA2L1App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
