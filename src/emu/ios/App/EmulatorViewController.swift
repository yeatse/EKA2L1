import QuartzCore
import UIKit

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

    private func scanCode(for press: UIPress) -> UInt32 {
        let chars = press.key?.charactersIgnoringModifiers.lowercased() ?? ""
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            switch scalar.value {
            case 48...57:
                return UInt32(scalar.value)
            case 42:
                return 0x2a
            case 35:
                return 0x7f
            default:
                break
            }
        }

        switch press.key?.keyCode {
        case .keyboardUpArrow:
            return 0x10
        case .keyboardDownArrow:
            return 0x11
        case .keyboardLeftArrow:
            return 0x0e
        case .keyboardRightArrow:
            return 0x0f
        case .keyboardReturnOrEnter:
            return 0xA7
        case .keyboardEscape:
            return 0xA5
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
