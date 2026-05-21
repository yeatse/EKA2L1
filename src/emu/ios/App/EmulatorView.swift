import SwiftUI
import UIKit

// SwiftUI wrapper around EmulatorViewController. Push onto the navigation
// stack from AppListView; pop to tear the running app down.
struct EmulatorView: UIViewControllerRepresentable {
    let uid: UInt32

    func makeUIViewController(context: Context) -> EmulatorViewController {
        return EmulatorViewController(uid: uid)
    }

    func updateUIViewController(_ uiViewController: EmulatorViewController, context: Context) {}
}
