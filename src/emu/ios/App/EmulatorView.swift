import SwiftUI
import UIKit

struct EmulatorView: View {
    let uid: UInt32

    @AppStorage("ios.showVirtualKeypad") private var showVirtualKeypad = true
    @AppStorage("ios.showFPSOverlay") private var showFPSOverlay = true
    @AppStorage("ios.fpsOverlayX") private var fpsOverlayX = -1.0
    @AppStorage("ios.fpsOverlayY") private var fpsOverlayY = -1.0
    @Environment(\.dismiss) private var dismiss
    @State private var guestFatalDetails: String?
    @State private var fpsDragStart: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    EmulatorControllerView(uid: uid, onAppExit: { fatalDetails in
                        if let fatalDetails {
                            guestFatalDetails = fatalDetails
                        } else {
                            dismiss()
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showFPSOverlay {
                        FPSOverlay()
                            .position(
                                x: overlayPosition(in: proxy.size).x,
                                y: overlayPosition(in: proxy.size).y
                            )
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let start = fpsDragStart ?? overlayPosition(in: proxy.size)
                                        fpsDragStart = start
                                        let point = clampedOverlayPosition(
                                            CGPoint(
                                                x: start.x + value.translation.width,
                                                y: start.y + value.translation.height
                                            ),
                                            in: proxy.size
                                        )
                                        fpsOverlayX = point.x
                                        fpsOverlayY = point.y
                                    }
                                    .onEnded { _ in
                                        fpsDragStart = nil
                                    }
                            )
                            .onAppear {
                                ensureOverlayPosition(in: proxy.size)
                            }
                            .onChange(of: proxy.size) { _, newSize in
                                ensureOverlayPosition(in: newSize)
                            }
                            .accessibilityLabel("Game FPS")
                    }
                }
            }
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

    private func overlayPosition(in size: CGSize) -> CGPoint {
        if fpsOverlayX >= 0, fpsOverlayY >= 0 {
            return clampedOverlayPosition(CGPoint(x: fpsOverlayX, y: fpsOverlayY), in: size)
        }
        return defaultOverlayPosition(in: size)
    }

    private func ensureOverlayPosition(in size: CGSize) {
        let point = overlayPosition(in: size)
        if point.x != fpsOverlayX || point.y != fpsOverlayY {
            fpsOverlayX = point.x
            fpsOverlayY = point.y
        }
    }

    private func defaultOverlayPosition(in size: CGSize) -> CGPoint {
        CGPoint(x: max(54, size.width - 56), y: 30)
    }

    private func clampedOverlayPosition(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 54), max(54, size.width - 54)),
            y: min(max(point.y, 30), max(30, size.height - 30))
        )
    }
}

private struct FPSOverlay: View {
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var fps = 0
    @State private var previousFrameCount: UInt64 = 0
    @State private var previousTimestamp = Date()

    var body: some View {
        Text("\(fps) FPS")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(width: 88, height: 34)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onAppear(perform: resetSample)
            .onReceive(timer) { now in
                let frameCount = EKA2L1Bridge.shared.renderedFrameCount()
                let elapsed = max(now.timeIntervalSince(previousTimestamp), 0.001)
                let renderedFrames = frameCount >= previousFrameCount ? frameCount - previousFrameCount : 0
                fps = Int((Double(renderedFrames) / elapsed).rounded())
                previousFrameCount = frameCount
                previousTimestamp = now
            }
    }

    private func resetSample() {
        previousFrameCount = EKA2L1Bridge.shared.renderedFrameCount()
        previousTimestamp = Date()
        fps = 0
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

// Symbian standard scan codes (see services/window/keys.h).
private enum Scan {
    static let leftSoft: UInt32 = 0xA4   // std_key_device_0
    static let rightSoft: UInt32 = 0xA5  // std_key_device_1
    static let select: UInt32 = 0xA7     // std_key_device_3
    static let call: UInt32 = 0xB4       // std_key_application_0 (green send)
    static let end: UInt32 = 0xB5        // std_key_application_1 (red hangup)
    static let up: UInt32 = 0x10
    static let down: UInt32 = 0x11
    static let left: UInt32 = 0x0E
    static let right: UInt32 = 0x0F
    static let hash: UInt32 = 0x7F
    static let star: UInt32 = 0x2A
}

private struct VirtualKeypad: View {
    private let columns = Array(repeating: GridItem(.fixed(48), spacing: 10), count: 3)

    // Digit, letters under it (phone style), and the raw scan code.
    private let digits: [(label: String, sub: String, scan: UInt32)] = [
        ("1", "", 0x31), ("2", "ABC", 0x32), ("3", "DEF", 0x33),
        ("4", "GHI", 0x34), ("5", "JKL", 0x35), ("6", "MNO", 0x36),
        ("7", "PQRS", 0x37), ("8", "TUV", 0x38), ("9", "WXYZ", 0x39),
        ("\u{2217}", "", Scan.star), ("0", "+", 0x30), ("#", "", Scan.hash)
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            navigationCluster
            numericPad
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: Left side – soft keys, call / end, and the navigation pad.

    private var navigationCluster: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                key(.text("LSK"), scan: Scan.leftSoft, kind: .soft)
                key(.text("RSK"), scan: Scan.rightSoft, kind: .soft)
            }
            HStack(spacing: 10) {
                key(.symbol("phone.fill"), scan: Scan.call, kind: .call)
                key(.symbol("phone.down.fill"), scan: Scan.end, kind: .end)
            }
            dPad
        }
    }

    private var dPad: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .frame(width: 130, height: 130)

            arrow("chevron.up", scan: Scan.up).offset(y: -45)
            arrow("chevron.down", scan: Scan.down).offset(y: 45)
            arrow("chevron.left", scan: Scan.left).offset(x: -45)
            arrow("chevron.right", scan: Scan.right).offset(x: 45)

            HoldableRawKey(scan: Scan.select) { pressed in
                Text("OK")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.12)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    )
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .scaleEffect(pressed ? 0.85 : 1)
                    .opacity(pressed ? 0.7 : 1)
                    .animation(.easeOut(duration: 0.12), value: pressed)
            }
        }
        .frame(width: 130, height: 130)
    }

    private func arrow(_ symbol: String, scan: UInt32) -> some View {
        HoldableRawKey(scan: scan) { pressed in
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .scaleEffect(pressed ? 0.85 : 1)
                .opacity(pressed ? 0.7 : 1)
                .animation(.easeOut(duration: 0.12), value: pressed)
        }
    }

    // MARK: Right side – numeric pad.

    private var numericPad: some View {
        // Row height tuned so 4 rows + 3 gaps == the left cluster's height
        // (soft row + call row + d-pad), keeping both columns top/bottom aligned.
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(digits, id: \.label) { digit in
                HoldableRawKey(scan: digit.scan) { pressed in
                    VStack(spacing: 1) {
                        Text(digit.label)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                        if !digit.sub.isEmpty {
                            Text(digit.sub)
                                .font(.system(size: 7, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .frame(width: 48, height: 49)
                    .keyCap(kind: .digit, pressed: pressed)
                }
            }
        }
    }

    private enum KeyLabel {
        case text(String)
        case symbol(String)
    }

    private func key(_ label: KeyLabel, scan: UInt32, kind: KeyKind) -> some View {
        HoldableRawKey(scan: scan) { pressed in
            Group {
                switch label {
                case .text(let value):
                    Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
                case .symbol(let value):
                    Image(systemName: value).font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(width: 58, height: 38)
            .keyCap(kind: kind, pressed: pressed)
        }
    }
}

private enum KeyKind {
    case digit, soft, call, end
}

private struct HoldableRawKey<Label: View>: View {
    let scan: UInt32
    @ViewBuilder let label: (Bool) -> Label

    @State private var pressed = false
    @State private var sentDown = false

    var body: some View {
        label(pressed)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                EKA2L1Bridge.shared.tapRawKey(scan)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        press()
                    }
                    .onEnded { _ in
                        release()
                    }
            )
            .onDisappear(perform: release)
    }

    private func press() {
        guard !sentDown else { return }
        sentDown = true
        pressed = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        EKA2L1Bridge.shared.submitRawKey(scan, pressed: true)
    }

    private func release() {
        guard sentDown else { return }
        sentDown = false
        pressed = false
        EKA2L1Bridge.shared.submitRawKey(scan, pressed: false)
    }
}

private struct KeyCapModifier: ViewModifier {
    let kind: KeyKind
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(kind == .digit || kind == .soft ? 0.12 : 0.0), lineWidth: 1)
            )
            .scaleEffect(pressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .digit, .soft: return .white
        case .call, .end: return .white
        }
    }

    private var background: Color {
        switch kind {
        case .digit:
            return .white.opacity(pressed ? 0.24 : 0.10)
        case .soft:
            return .white.opacity(pressed ? 0.26 : 0.13)
        case .call:
            return Color.green.opacity(pressed ? 0.7 : 0.9)
        case .end:
            return Color.red.opacity(pressed ? 0.7 : 0.9)
        }
    }
}

private extension View {
    func keyCap(kind: KeyKind, pressed: Bool) -> some View {
        modifier(KeyCapModifier(kind: kind, pressed: pressed))
    }
}
