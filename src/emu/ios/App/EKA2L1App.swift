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
        // Stage-1 regression hook: scripts/build_ios.sh smoke greps for the
        // EKA2L1_SMOKE marker on stdout. Keep firing the dyncom check at
        // launch so the CI signal survives the stage-2 UI restructure.
        DispatchQueue.global(qos: .background).async {
            let r = EKA2L1Bridge.runSmoke(backend: .dyncom)
            let backend = r.resolvedBackend == .dyncom ? "dyncom" : "dynarmic"
            if r.pass {
                NSLog("EKA2L1_SMOKE: PASS backend=\(backend) instrs=\(r.instructionsExecuted) pc=0x%08X", r.pc)
            } else {
                NSLog("EKA2L1_SMOKE: FAIL backend=\(backend) instrs=\(r.instructionsExecuted)")
            }
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
