import SwiftUI
import UIKit

struct EmulatorView: View {
    let uid: UInt32

    @AppStorage("ios.showVirtualKeypad") private var showVirtualKeypad = true
    @Environment(\.dismiss) private var dismiss
    @State private var guestFatalDetails: String?

    var body: some View {
        VStack(spacing: 0) {
            EmulatorControllerView(uid: uid, onAppExit: { fatalDetails in
                if let fatalDetails {
                    guestFatalDetails = fatalDetails
                } else {
                    dismiss()
                }
            })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showVirtualKeypad {
                VirtualKeypad()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
        }
        .background(Color.black)
        .onDisappear {
            // The emulator screen was popped/dismissed (back button or a
            // programmatic dismiss after the app exited). Kill the guest app in
            // lockstep with closing the screen. Drop the exit handler first so
            // the kill's logon doesn't bounce back into a dismiss. SwiftUI's
            // onDisappear fires on navigation removal but not on app
            // backgrounding (that path pauses via scenePhase), so this cleanly
            // means "screen closed". No-op if the app already exited.
            EKA2L1Bridge.shared.setAppExitHandler(nil)
            EKA2L1Bridge.shared.closeRunningApp()
        }
        .alert("Guest fatal", isPresented: Binding(
            get: { guestFatalDetails != nil },
            set: { isPresented in
                if !isPresented {
                    guestFatalDetails = nil
                }
            }
        )) {
            Button("确定") {
                guestFatalDetails = nil
                dismiss()
            }
        } message: {
            Text(guestFatalDetails ?? "")
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("L") {
                    EKA2L1Bridge.shared.tapRawKey(0xA4)
                }
                .accessibilityLabel("Left soft key")

                Button("R") {
                    EKA2L1Bridge.shared.tapRawKey(0xA5)
                }
                .accessibilityLabel("Right soft key")

                Button {
                    showVirtualKeypad.toggle()
                } label: {
                    Image(systemName: showVirtualKeypad ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .accessibilityLabel(showVirtualKeypad ? "Hide virtual keypad" : "Show virtual keypad")
            }
        }
    }
}

private struct EmulatorControllerView: UIViewControllerRepresentable {
    let uid: UInt32
    let onAppExit: (String?) -> Void

    func makeUIViewController(context: Context) -> EmulatorViewController {
        let controller = EmulatorViewController(uid: uid)
        controller.onAppExit = onAppExit
        return controller
    }

    func updateUIViewController(_ uiViewController: EmulatorViewController, context: Context) {
        uiViewController.onAppExit = onAppExit
    }
}

private struct VirtualKeypad: View {
    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 3)

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    keyButton("LS", scan: 0xA4)
                    keyButton("RS", scan: 0xA5)
                }
                HStack(spacing: 8) {
                    Spacer().frame(width: 44)
                    iconButton("chevron.up", scan: 0x10)
                    Spacer().frame(width: 44)
                }
                HStack(spacing: 8) {
                    iconButton("chevron.left", scan: 0x0e)
                    iconButton("circle", scan: 0xA7)
                    iconButton("chevron.right", scan: 0x0f)
                }
                HStack(spacing: 8) {
                    Spacer().frame(width: 44)
                    iconButton("chevron.down", scan: 0x11)
                    Spacer().frame(width: 44)
                }
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"], id: \.self) { label in
                    keyButton(label, scan: scanCode(for: label))
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func keyButton(_ label: String, scan: UInt32) -> some View {
        Button {
            EKA2L1Bridge.shared.tapRawKey(scan)
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(width: 44, height: 36)
        }
        .buttonStyle(.bordered)
    }

    private func iconButton(_ symbol: String, scan: UInt32) -> some View {
        Button {
            EKA2L1Bridge.shared.tapRawKey(scan)
        } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 36)
        }
        .buttonStyle(.bordered)
    }

    private func scanCode(for label: String) -> UInt32 {
        switch label {
        case "1": return 0x31
        case "2": return 0x32
        case "3": return 0x33
        case "4": return 0x34
        case "5": return 0x35
        case "6": return 0x36
        case "7": return 0x37
        case "8": return 0x38
        case "9": return 0x39
        case "0": return 0x30
        case "*": return 0x2a
        case "#": return 0x7f
        default: return 0
        }
    }
}
