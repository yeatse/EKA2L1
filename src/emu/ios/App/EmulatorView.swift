import SwiftUI
import UIKit

// Fullscreen emulator screen: the render view fills the whole display (no
// navigation bar / status bar) and the virtual keypad floats above it — the
// keypad never resizes the game picture. Frontend actions that used to live in
// the navigation bar are reachable through the keypad's system menu key.
struct EmulatorView: View {
    let uid: UInt32

    @AppStorage("ios.showVirtualKeypad") private var showVirtualKeypad = true
    @AppStorage(KeypadLayout.storageKey) private var keypadLayoutRaw = KeypadLayout.default.rawValue
    @AppStorage(KeypadLayout.touchStorageKey) private var touchKeypadLayoutRaw = KeypadLayout.touchDefault.rawValue
    @AppStorage(KeypadDefaults.opacityKey) private var keypadOpacity = KeypadDefaults.opacity
    @AppStorage("ios.showFPSOverlay") private var showFPSOverlay = true
    @AppStorage("ios.fpsOverlayX") private var fpsOverlayX = -1.0
    @AppStorage("ios.fpsOverlayY") private var fpsOverlayY = -1.0
    @Environment(\.dismiss) private var dismiss
    @State private var guestFatalDetails: String?
    @State private var sessionMessage: String?
    @State private var fpsDragStart: CGPoint?
    @State private var wasIdleTimerDisabled = false
    @State private var hostProxy = EmulatorHostProxy()
    // Per-game guest frame-rate cap (0 = unlimited); loaded on appear and
    // written straight through to the emulator when changed from Game Settings.
    @State private var frameLimit = 0
    // Whether the booted ROM is touch-driven (S60v5 / Symbian^3+); those use a
    // separate layout preference that defaults to the fullscreen layout.
    @State private var isTouchDevice = false
    // Screen-space frame of the keypad overlay, handed to the render view so it
    // yields touches there to the keys drawn above it.
    @State private var keypadFrame: CGRect = .null
    // Whether the floating opacity slider is presented (opened from the system
    // menu's Keypad Settings). Lives here so the bar can sit at the screen's
    // bottom centre, outside the keypad's own opacity fade.
    @State private var showOpacitySlider = false

    // The -LaunchKeypadLayout testing argument seeds the layout only for the
    // first emulator screen of the process; later screens use the stored pick.
    @MainActor private static var launchLayoutApplied = false

    private var keypadLayout: KeypadLayout {
        KeypadLayout.resolve(isTouchDevice ? touchKeypadLayoutRaw : keypadLayoutRaw)
    }

    // Menu layout picks go to whichever preference backs the current ROM class,
    // and re-show a hidden keypad — the pick expresses "I want this keypad now".
    private var layoutSelection: Binding<String> {
        Binding(
            get: { keypadLayout.rawValue },
            set: { raw in
                if isTouchDevice {
                    touchKeypadLayoutRaw = raw
                } else {
                    keypadLayoutRaw = raw
                }
                showVirtualKeypad = true
            }
        )
    }

    // Writing the frame-limit binding pushes the new cap straight to the
    // emulator (which applies it live and persists it per app UID).
    private var frameLimitSelection: Binding<Int> {
        Binding(
            get: { frameLimit },
            set: { newValue in
                frameLimit = newValue
                EKA2L1Bridge.shared.setGuestFrameLimit(appUID: uid, limit: newValue)
            }
        )
    }

    private var menuActions: KeypadMenuActions {
        KeypadMenuActions(
            layoutSelection: layoutSelection,
            rotateGuestScreen: {
                EKA2L1Bridge.shared.advanceGuestScreenMode(appUID: uid) { _ in }
            },
            frameLimit: frameLimitSelection,
            adjustOpacity: {
                withAnimation(.easeInOut(duration: 0.22)) { showOpacitySlider = true }
            },
            saveScreenshot: { saveScreenshot() },
            exitGame: {
                EKA2L1Bridge.shared.closeRunningApp()
                dismiss()
            }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                EmulatorControllerView(
                    uid: uid,
                    host: hostProxy,
                    anchorsDisplayTop: keypadLayout.prefersTopAnchoredDisplay && showVirtualKeypad,
                    keypadHitRegion: keypadFrame,
                    onAppExit: { fatalDetails in
                        if let fatalDetails {
                            guestFatalDetails = fatalDetails
                        } else {
                            dismiss()
                        }
                    }
                )
                .ignoresSafeArea()

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
                        .accessibilityLabel(Text("emulator.fps.accessibility"))
                }
            }
            .overlay(alignment: keypadOverlayAlignment) {
                keypadOverlay
                    .background(
                        GeometryReader { keypadProxy in
                            Color.clear
                                .onAppear { updateKeypadFrame(keypadProxy.frame(in: .global)) }
                                .onChange(of: keypadProxy.frame(in: .global)) { updateKeypadFrame($0) }
                        }
                    )
            }
            .overlay(alignment: .bottom) {
                if showOpacitySlider {
                    OpacitySliderBar(opacity: $keypadOpacity) {
                        withAnimation(.easeInOut(duration: 0.22)) { showOpacitySlider = false }
                    }
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            isTouchDevice = EKA2L1Bridge.shared.currentDeviceIsTouchScreen()
            frameLimit = EKA2L1Bridge.shared.guestFrameLimit(appUID: uid)
            if !Self.launchLayoutApplied, let forced = KeypadLayout.launchArgumentLayout() {
                Self.launchLayoutApplied = true
                layoutSelection.wrappedValue = forced.rawValue
            }
            DisplayOrientation.apply(keypadLayout)
        }
        .onChange(of: keypadLayout) { newLayout in
            DisplayOrientation.apply(newLayout)
        }
        .onDisappear {
            // The emulator screen was popped/dismissed (exit menu item or a
            // programmatic dismiss after the app exited). Kill the guest app in
            // lockstep with closing the screen. Drop the exit handler first so
            // the kill's logon doesn't bounce back into a dismiss. SwiftUI's
            // onDisappear fires on navigation removal but not on app
            // backgrounding (that path pauses via scenePhase), so this cleanly
            // means "screen closed". No-op if the app already exited.
            EKA2L1Bridge.shared.setAppExitHandler(nil)
            EKA2L1Bridge.shared.closeRunningApp()
            UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled
            DisplayOrientation.unlock()
        }
        .alert("emulator.guestFatal", isPresented: Binding(
            get: { guestFatalDetails != nil },
            set: { isPresented in
                if !isPresented {
                    guestFatalDetails = nil
                }
            }
        )) {
            Button("common.ok") {
                guestFatalDetails = nil
                dismiss()
            }
        } message: {
            Text(guestFatalDetails ?? "")
        }
        .alert("emulator.notice", isPresented: Binding(
            get: { sessionMessage != nil },
            set: { isPresented in
                if !isPresented {
                    sessionMessage = nil
                }
            }
        )) {
            Button("common.ok") { sessionMessage = nil }
        } message: {
            Text(sessionMessage ?? "")
        }
    }

    // MARK: Keypad overlay

    private var keypadOverlayAlignment: Alignment {
        showVirtualKeypad ? keypadLayout.overlayAlignment : .bottomTrailing
    }

    // The overlay (full keypad, or just the floating system-menu key when the
    // keypad is hidden) always intercepts touches within its own frame; the
    // exposed game area stays available for guest touch. .global matches the
    // render view's coordinate space (it fills the window).
    private func updateKeypadFrame(_ frame: CGRect) {
        if frame != keypadFrame {
            keypadFrame = frame
        }
    }

    @ViewBuilder private var keypadOverlay: some View {
        Group {
            if showVirtualKeypad {
                VirtualKeypad(layout: keypadLayout, actions: menuActions)
                    .padding(keypadLayout == .ngage ? 0 : 10)
            } else {
                // Keypad hidden: keep the system menu key so the screen stays
                // operable without the navigation bar.
                SystemMenuKey(actions: menuActions, size: CGSize(width: 46, height: 40))
                    .padding(10)
            }
        }
        .opacity(keypadOpacity)
    }

    // MARK: Actions

    // Snapshot only the render view (no keypad overlay). drawHierarchy uses
    // the window-server snapshot path, which is what captures GL/Metal layer
    // content — CALayer.render(in:) would leave the game picture black.
    private func saveScreenshot() {
        guard let view = hostProxy.viewController?.view else {
            sessionMessage = String(localized: "emulator.screenshot.failed")
            return
        }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        sessionMessage = String(localized: "emulator.screenshot.saved")
    }

    // MARK: FPS overlay positioning

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

// MARK: - Orientation

// The interface orientation is pinned to whatever the active keypad layout
// wants (N-Gage → landscape, everything else → portrait) and locked there, so
// a physical device rotation can't change it. `AppOrientationDelegate` reads
// this mask from the (nonisolated) UIKit callback, hence the plain global.
nonisolated(unsafe) var lockedInterfaceOrientationMask: UIInterfaceOrientationMask = .portrait

// SwiftUI hosts every screen in system UIHostingControllers we can't subclass,
// and their supportedInterfaceOrientations otherwise caps the window at portrait
// (a navigation push settles there), so requestGeometryUpdate and autorotation
// both refuse landscape even when the app delegate allows it. Route each hosting
// controller in the live chain through the single global authority the first
// time we see it. The concrete UIHostingController<…> classes are only known at
// runtime, hence the per-class swizzle rather than a subclass or Info.plist cap.
@MainActor private var routedOrientationClasses = Set<ObjectIdentifier>()

@MainActor private func routeOrientationThroughLiveControllers(from root: UIViewController?) {
    var vc = root
    var depth = 0
    while let current = vc, depth < 12 {
        let cls: AnyClass = type(of: current)
        if routedOrientationClasses.insert(ObjectIdentifier(cls)).inserted,
           let method = class_getInstanceMethod(cls, #selector(getter: UIViewController.supportedInterfaceOrientations)) {
            let block: @convention(block) (UIViewController) -> UIInterfaceOrientationMask = { _ in
                lockedInterfaceOrientationMask
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        vc = current.presentedViewController ?? current.children.last
        depth += 1
    }
}

// Pins/releases the interface orientation for the emulator screen (frame +
// keypad).
@MainActor
enum DisplayOrientation {
    // Apply a layout's permitted orientations. A pinned layout (classic/compact
    // portrait, N-Gage landscape) rotates to its orientation immediately; the
    // fullscreen touch layout widens the allowed set and follows the physical
    // device, so the user can turn a landscape guest sideways to fill the screen.
    static func apply(_ layout: KeypadLayout) {
        lockedInterfaceOrientationMask = layout.supportedOrientations
        routeOrientationThroughLiveControllers(from: activeScene?.keyWindow?.rootViewController)
        rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        // A free-rotation layout keeps the current orientation and lets the user
        // turn the device; a pinned layout rotates to its orientation now.
        guard !layout.allowsFreeRotation else { return }
        request(landscape: layout.supportedOrientations.contains(.landscape))
    }

    // Release back to portrait when leaving the emulator (home screen is
    // portrait-only).
    static func unlock() {
        lockedInterfaceOrientationMask = .portrait
        request(landscape: false)
    }

    private static func request(landscape: Bool) {
        guard let scene = activeScene else { return }
        routeOrientationThroughLiveControllers(from: scene.keyWindow?.rootViewController)
        rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait))
        // The request is rejected while a navigation transition is running (the
        // emulator screen is usually mid-push), so confirm after it settles and
        // re-request once if it didn't stick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard let scene = activeScene,
                  scene.interfaceOrientation.isLandscape != landscape else { return }
            routeOrientationThroughLiveControllers(from: scene.keyWindow?.rootViewController)
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait))
        }
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static var rootViewController: UIViewController? {
        activeScene?.keyWindow?.rootViewController
    }
}

// MARK: - FPS overlay

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

// MARK: - UIKit bridge

// Lets the SwiftUI screen reach the hosted controller (for the render-view
// screenshot) without retaining it.
@MainActor
final class EmulatorHostProxy {
    weak var viewController: EmulatorViewController?
}

private struct EmulatorControllerView: UIViewControllerRepresentable {
    let uid: UInt32
    let host: EmulatorHostProxy
    let anchorsDisplayTop: Bool
    // Screen-space region covered by the keypad overlay; the render view yields
    // touches there so the keys (drawn above it) receive them.
    let keypadHitRegion: CGRect
    let onAppExit: (String?) -> Void

    func makeUIViewController(context: Context) -> EmulatorViewController {
        let controller = EmulatorViewController(uid: uid)
        controller.onAppExit = onAppExit
        controller.anchorsDisplayTop = anchorsDisplayTop
        controller.keypadHitRegion = keypadHitRegion
        host.viewController = controller
        return controller
    }

    func updateUIViewController(_ uiViewController: EmulatorViewController, context: Context) {
        uiViewController.onAppExit = onAppExit
        uiViewController.anchorsDisplayTop = anchorsDisplayTop
        uiViewController.keypadHitRegion = keypadHitRegion
        host.viewController = uiViewController
    }
}
