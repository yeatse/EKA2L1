// Stage-2 SwiftUI shell for the EKA2L1 iOS port.
//
// scenePhase is the iOS contract for "app is foreground / background". The
// emulator must stop touching the EAGL context the moment we leave .active
// or the system will tear down our drawable and crash the next GL call.

import SwiftUI
import UIKit

// Supplies the interface-orientation lock. The emulator screen pins the
// orientation to its keypad layout (see DisplayOrientation) by writing
// `lockedInterfaceOrientationMask`; UIKit asks this delegate on every rotation,
// so a physical device turn can't override the layout's orientation.
final class AppOrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        lockedInterfaceOrientationMask
    }
}

@main
struct EKA2L1App: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
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
