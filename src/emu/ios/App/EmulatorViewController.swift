import GameController
import QuartzCore
import UIKit

private final class ControllerInputBridge: @unchecked Sendable {
    private let threshold: Float = 0.45
    private let lock = NSLock()
    private var activeScansByToken: [String: UInt32] = [:]
    private var observers: [NSObjectProtocol] = []
    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "ios.enableControllerInput") as? Bool ?? true
    }

    func start() {
        guard enabled else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.attach(controller)
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.releaseAll()
        })
        GCController.startWirelessControllerDiscovery()
        GCController.controllers().forEach(attach)
    }

    func stop() {
        GCController.stopWirelessControllerDiscovery()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
        releaseAll()
    }

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.valueChangedHandler = { [weak self] pad, element in
            self?.handle(gamepad: pad, element: element)
        }
        handleAll(gamepad)
    }

    private func handle(gamepad: GCExtendedGamepad, element: GCControllerElement) {
        if element === gamepad.dpad {
            updateDirections(prefix: "dpad", x: gamepad.dpad.xAxis.value, y: gamepad.dpad.yAxis.value)
        } else if element === gamepad.leftThumbstick {
            updateDirections(prefix: "leftStick", x: gamepad.leftThumbstick.xAxis.value, y: gamepad.leftThumbstick.yAxis.value)
        } else if element === gamepad.buttonA {
            updateButton(token: "buttonA", scan: Scan.select, pressed: gamepad.buttonA.isPressed)
        } else if element === gamepad.buttonB {
            updateButton(token: "buttonB", scan: Scan.rightSoft, pressed: gamepad.buttonB.isPressed)
        } else if element === gamepad.buttonX {
            updateButton(token: "buttonX", scan: Scan.leftSoft, pressed: gamepad.buttonX.isPressed)
        } else if element === gamepad.buttonY {
            updateButton(token: "buttonY", scan: Scan.hash, pressed: gamepad.buttonY.isPressed)
        } else if element === gamepad.leftShoulder {
            updateButton(token: "leftShoulder", scan: Scan.leftSoft, pressed: gamepad.leftShoulder.isPressed)
        } else if element === gamepad.rightShoulder {
            updateButton(token: "rightShoulder", scan: Scan.rightSoft, pressed: gamepad.rightShoulder.isPressed)
        } else if element === gamepad.leftTrigger {
            updateButton(token: "leftTrigger", scan: Scan.star, pressed: gamepad.leftTrigger.value > threshold)
        } else if element === gamepad.rightTrigger {
            updateButton(token: "rightTrigger", scan: Scan.hash, pressed: gamepad.rightTrigger.value > threshold)
        } else if element === gamepad.buttonMenu {
            updateButton(token: "buttonMenu", scan: Scan.rightSoft, pressed: gamepad.buttonMenu.isPressed)
        }
    }

    private func handleAll(_ gamepad: GCExtendedGamepad) {
        updateDirections(prefix: "dpad", x: gamepad.dpad.xAxis.value, y: gamepad.dpad.yAxis.value)
        updateDirections(prefix: "leftStick", x: gamepad.leftThumbstick.xAxis.value, y: gamepad.leftThumbstick.yAxis.value)
        updateButton(token: "buttonA", scan: Scan.select, pressed: gamepad.buttonA.isPressed)
        updateButton(token: "buttonB", scan: Scan.rightSoft, pressed: gamepad.buttonB.isPressed)
        updateButton(token: "buttonX", scan: Scan.leftSoft, pressed: gamepad.buttonX.isPressed)
        updateButton(token: "buttonY", scan: Scan.hash, pressed: gamepad.buttonY.isPressed)
        updateButton(token: "leftShoulder", scan: Scan.leftSoft, pressed: gamepad.leftShoulder.isPressed)
        updateButton(token: "rightShoulder", scan: Scan.rightSoft, pressed: gamepad.rightShoulder.isPressed)
        updateButton(token: "leftTrigger", scan: Scan.star, pressed: gamepad.leftTrigger.value > threshold)
        updateButton(token: "rightTrigger", scan: Scan.hash, pressed: gamepad.rightTrigger.value > threshold)
        updateButton(token: "buttonMenu", scan: Scan.rightSoft, pressed: gamepad.buttonMenu.isPressed)
    }

    private func updateDirections(prefix: String, x: Float, y: Float) {
        updateButton(token: "\(prefix).up", scan: Scan.up, pressed: y > threshold)
        updateButton(token: "\(prefix).down", scan: Scan.down, pressed: y < -threshold)
        updateButton(token: "\(prefix).left", scan: Scan.left, pressed: x < -threshold)
        updateButton(token: "\(prefix).right", scan: Scan.right, pressed: x > threshold)
    }

    private func updateButton(token: String, scan: UInt32, pressed: Bool) {
        let event: (UInt32, Bool)?
        lock.lock()
        let wasPressed = activeScansByToken[token] != nil
        if pressed == wasPressed {
            event = nil
        } else if pressed {
            activeScansByToken[token] = scan
            event = (scan, true)
        } else if let oldScan = activeScansByToken.removeValue(forKey: token) {
            event = (oldScan, false)
        } else {
            event = nil
        }
        lock.unlock()

        if let event {
            EKA2L1Bridge.submitRawKey(event.0, pressed: event.1)
        }
    }

    private func releaseAll() {
        lock.lock()
        let activeScans = Array(activeScansByToken.values)
        activeScansByToken.removeAll()
        lock.unlock()

        for scan in activeScans {
            EKA2L1Bridge.submitRawKey(scan, pressed: false)
        }
    }
}

private final class EKA2L1RenderView: UIView {
    var surfaceReady = false

    override class var layerClass: AnyClass {
        CAEAGLLayer.self
    }

    private var eaglLayer: CAEAGLLayer {
        layer as! CAEAGLLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentScaleFactor = UIScreen.main.nativeScale
        isMultipleTouchEnabled = true
        isOpaque = true
        backgroundColor = .black
        eaglLayer.isOpaque = true

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        addGestureRecognizer(longPress)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponder()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let scale = renderScale
        eaglLayer.contentsScale = scale
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixels.width > 0, pixels.height > 0 else { return }

        EKA2L1Bridge.shared.attach(layer: eaglLayer, pixelSize: pixels, scale: scale)
        surfaceReady = true
    }

    /// Backing-store scale for the GL surface. On a real device this is the
    /// native screen scale and the GPU does the present blit for free. The
    /// iOS Simulator has no GPU-backed GLES — every present blit is rasterized
    /// in software on the host CPU, and its cost grows with the pixel count.
    /// Since the guest screen is tiny (e.g. 240x320) and the present is just an
    /// upscale, rendering it at full native Retina only burns host CPU on
    /// interpolated pixels with no added detail. Cap the simulator surface so
    /// the software blit stops being the frame bottleneck.
    private var renderScale: CGFloat {
        #if targetEnvironment(simulator)
        return min(contentScaleFactor, 1.5)
        #else
        return contentScaleFactor
        #endif
    }

    private func pointerPhase(for touch: UITouch) -> EKA2L1PointerPhase {
        switch touch.phase {
        case .began:
            return .began
        case .moved, .stationary:
            return .moved
        case .ended:
            return .ended
        case .cancelled:
            return .cancelled
        case .regionEntered, .regionMoved:
            return .moved
        case .regionExited:
            return .ended
        @unknown default:
            return .cancelled
        }
    }

    private func dispatchTouches(_ touches: Set<UITouch>) {
        // Must match the surface scale used in layoutSubviews so guest pointer
        // coordinates line up with the (possibly downscaled) render surface.
        let scale = renderScale
        for touch in touches {
            let point = touch.location(in: self)
            EKA2L1Bridge.shared.submitPointer(
                x: point.x * scale,
                y: point.y * scale,
                phase: pointerPhase(for: touch),
                pointerId: UInt(bitPattern: ObjectIdentifier(touch))
            )
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        EKA2L1Bridge.shared.tapRawKey(0xA7)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .ended else { return }
        EKA2L1Bridge.shared.tapRawKey(gesture.scale >= 1.0 ? 0x10 : 0x11)
    }

    // Map a hardware-keyboard press to an EPOC standard scan code (see
    // services/window/keys.h `std_scan_code`). Alphanumerics use their uppercase
    // ASCII value as the scan code — that's the EPOC convention, which is why the
    // digits/letters can be forwarded straight through; space/backspace/tab and
    // the soft keys do not follow ASCII and are mapped by keyCode instead.
    private func scanCode(for press: UIPress) -> UInt32 {
        let chars = press.key?.charactersIgnoringModifiers.lowercased() ?? ""
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            switch scalar.value {
            case 48...57:           // 0-9
                return UInt32(scalar.value)
            case 97...122:          // a-z -> uppercase ASCII == std scan code
                return UInt32(scalar.value) - 0x20
            case 42:                // *
                return 0x2a
            case 35:                // #
                return 0x7f
            default:
                break
            }
        }

        switch press.key?.keyCode {
        case .keyboardUpArrow:
            return 0x10             // std_key_up_arrow
        case .keyboardDownArrow:
            return 0x11             // std_key_down_arrow
        case .keyboardLeftArrow:
            return 0x0e             // std_key_left_arrow
        case .keyboardRightArrow:
            return 0x0f             // std_key_right_arrow
        case .keyboardReturnOrEnter, .keypadEnter:
            return 0xA7             // std_key_device_3 (select / OK)
        case .keyboardSpacebar:
            return 0x05             // std_key_space
        case .keyboardDeleteOrBackspace:
            return 0x01             // std_key_backspace
        case .keyboardTab:
            return 0x02             // std_key_tab
        case .keyboardF1:
            return 0xA4             // std_key_device_0 (left soft key)
        case .keyboardF2, .keyboardEscape:
            return 0xA5             // std_key_device_1 (right soft key / back)
        case .keyboardF3:
            return 0xB4             // std_key_application_0 (green call)
        case .keyboardF4:
            return 0xB5             // std_key_application_1 (red end)
        default:
            return 0
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            let scan = scanCode(for: press)
            if scan != 0 {
                EKA2L1Bridge.shared.submitRawKey(scan, pressed: true)
            }
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            let scan = scanCode(for: press)
            if scan != 0 {
                EKA2L1Bridge.shared.submitRawKey(scan, pressed: false)
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        dispatchTouches(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        dispatchTouches(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        dispatchTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        dispatchTouches(touches)
    }
}

final class EmulatorViewController: UIViewController {
    private let uid: UInt32
    // Invoked when the guest app exits on its own (Exit soft key / panic /
    // normal termination) so the SwiftUI host can pop this screen.
    var onAppExit: ((String?) -> Void)?
    private var launched = false
    private let controllerInput = ControllerInputBridge()
    private var gameView: EKA2L1RenderView {
        view as! EKA2L1RenderView
    }

    init(uid: UInt32) {
        self.uid = uid
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let renderView = EKA2L1RenderView(frame: UIScreen.main.bounds)
        renderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view = renderView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        gameView.setNeedsLayout()
        gameView.layoutIfNeeded()
        controllerInput.start()
        EKA2L1Bridge.shared.resume()
        // Launch once: viewDidAppear can re-fire (e.g. returning frontmost),
        // and re-launching would spawn a second guest instance.
        if gameView.surfaceReady, !launched {
            launched = true
            EKA2L1Bridge.shared.setAppExitHandler { [weak self] fatalDetails in
                self?.handleAppExited(fatalDetails: fatalDetails)
            }
            _ = EKA2L1Bridge.shared.launchApp(uid: uid)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        controllerInput.stop()
        EKA2L1Bridge.shared.detachLayer()
    }

    // Closing the screen (and killing the app) is detected at the SwiftUI level
    // in EmulatorView's .onDisappear: UIKit's isMovingFromParent /
    // isBeingDismissed are unreliable for a UIViewControllerRepresentable popped
    // by a SwiftUI NavigationStack (they read false), so viewWillDisappear can't
    // tell a pop from a transient disappear. Backgrounding is handled by
    // scenePhase.
    private func handleAppExited(fatalDetails: String?) {
        EKA2L1Bridge.shared.setAppExitHandler(nil)
        onAppExit?(fatalDetails)
    }
}
