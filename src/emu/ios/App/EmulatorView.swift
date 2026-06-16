import SwiftUI
import UIKit

struct EmulatorView: View {
    let uid: UInt32

    @AppStorage("ios.showVirtualKeypad") private var showVirtualKeypad = true
    @AppStorage(KeypadLayout.storageKey) private var keypadLayoutRaw = KeypadLayout.default.rawValue
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
                            .onChange(of: proxy.size) { newSize in
                                ensureOverlayPosition(in: newSize)
                            }
                            .accessibilityLabel("Game FPS")
                    }
                }
            }
            if showVirtualKeypad {
                VirtualKeypad(layout: KeypadLayout.resolve(keypadLayoutRaw))
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
