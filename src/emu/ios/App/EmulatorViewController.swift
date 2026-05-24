import QuartzCore
import UIKit

private class EKA2L1RenderView: UIView {
    var surfaceReady = false

    var renderLayer: CALayer { layer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentScaleFactor = UIScreen.main.nativeScale
        isMultipleTouchEnabled = true
        isOpaque = true
        backgroundColor = .black
        configureLayer()

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

    func configureLayer() {
        renderLayer.isOpaque = true
    }

    func updateDrawableSize(_ pixelSize: CGSize, scale: CGFloat) {
        renderLayer.contentsScale = scale
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let scale = contentScaleFactor
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixels.width > 0, pixels.height > 0 else { return }

        updateDrawableSize(pixels, scale: scale)
        EKA2L1Bridge.shared.attach(layer: renderLayer, pixelSize: pixels, scale: scale)
        surfaceReady = true
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
        let scale = contentScaleFactor
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

private final class EKA2L1MetalRenderView: EKA2L1RenderView {
    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    private var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    override var renderLayer: CALayer { metalLayer }

    override func configureLayer() {
        super.configureLayer()
        metalLayer.framebufferOnly = false
        metalLayer.pixelFormat = .bgra8Unorm
    }

    override func updateDrawableSize(_ pixelSize: CGSize, scale: CGFloat) {
        super.updateDrawableSize(pixelSize, scale: scale)
        metalLayer.drawableSize = pixelSize
    }
}

private final class EKA2L1EAGLRenderView: EKA2L1RenderView {
    override class var layerClass: AnyClass {
        CAEAGLLayer.self
    }

    private var eaglLayer: CAEAGLLayer {
        layer as! CAEAGLLayer
    }

    override var renderLayer: CALayer { eaglLayer }

    override func configureLayer() {
        super.configureLayer()
        eaglLayer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
        ]
    }
}

final class EmulatorViewController: UIViewController {
    private let uid: UInt32
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
        let key = "ios.useMetalRenderer"
        let useMetal = UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)
        let renderView: EKA2L1RenderView = useMetal
            ? EKA2L1MetalRenderView(frame: UIScreen.main.bounds)
            : EKA2L1EAGLRenderView(frame: UIScreen.main.bounds)
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
        if gameView.surfaceReady {
            _ = EKA2L1Bridge.shared.launchApp(uid: uid)
            EKA2L1Bridge.shared.resume()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        EKA2L1Bridge.shared.pause()
    }
}
