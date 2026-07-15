import SwiftUI
import UIKit

// SwiftUI's zero-distance DragGesture creates a gesture recognizer for every
// virtual key. On iOS 26, rebuilding that large recognizer dependency graph
// while a key's pressed state changes can leave UIKit comparing a stale
// recognizer container (see docs/ios-swiftui-keypad-gesture-crash.md). The
// keypad only needs raw down/move/up tracking, so keep it in UIKit's responder
// path and out of the gesture-recognizer graph.
fileprivate enum KeyTouchShape: Equatable {
    case rectangle
    case circle
}

private final class KeyTouchView: UIView {
    var shape: KeyTouchShape = .rectangle
    var onChanged: ((CGPoint) -> Void)?
    var onEnded: (() -> Void)?

    private weak var activeTouch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        layer.isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard shape == .circle else { return true }
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        let radius = min(bounds.width, bounds.height) / 2
        return dx * dx + dy * dy <= radius * radius
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        onChanged?(touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        onChanged?(activeTouch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishIfActive(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishIfActive(touches)
    }

    private func finishIfActive(_ touches: Set<UITouch>) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        onEnded?()
    }
}

private struct KeyTouchSurface: UIViewRepresentable {
    let shape: KeyTouchShape
    let onChanged: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeUIView(context: Context) -> KeyTouchView {
        KeyTouchView()
    }

    func updateUIView(_ view: KeyTouchView, context: Context) {
        view.shape = shape
        view.onChanged = onChanged
        view.onEnded = onEnded
    }
}

// Shared building blocks for the on-screen keypad layouts in VirtualKeypad.swift:
// scan codes, the press/release key primitive, key-cap styling, the sliding
// d-pad and the numeric pads.

// Symbian standard scan codes (see services/window/keys.h).
enum Scan {
    static let leftSoft: UInt32 = 0xA4   // std_key_device_0
    static let rightSoft: UInt32 = 0xA5  // std_key_device_1
    static let select: UInt32 = 0xA7     // std_key_device_3
    static let clear: UInt32 = 0x01      // std_key_backspace (guest "C" key)
    static let up: UInt32 = 0x10
    static let down: UInt32 = 0x11
    static let left: UInt32 = 0x0E
    static let right: UInt32 = 0x0F
    static let hash: UInt32 = 0x7F
    static let star: UInt32 = 0x2A
    static let call: UInt32 = 0xB4       // std_key_application_0 (green call)
    static let end: UInt32 = 0xB5        // std_key_application_1 (red end)
}

// Digit, the phone-style letters under it, and the raw scan code. Shared by
// every numeric pad so they all stay identical.
let keypadDigits: [(label: String, sub: String, scan: UInt32)] = [
    ("1", "", 0x31), ("2", "ABC", 0x32), ("3", "DEF", 0x33),
    ("4", "GHI", 0x34), ("5", "JKL", 0x35), ("6", "MNO", 0x36),
    ("7", "PQRS", 0x37), ("8", "TUV", 0x38), ("9", "WXYZ", 0x39),
    ("\u{2217}", "", Scan.star), ("0", "+", 0x30), ("#", "", Scan.hash)
]

// MARK: - Key primitive

struct HoldableRawKey<Label: View>: View {
    let scan: UInt32
    // Hit-test region for the key. Defaults to the full bounding rect; round
    // keys pass a precise shape so neighbouring keys don't overlap.
    fileprivate var hitShape: KeyTouchShape = .rectangle
    @ViewBuilder let label: (Bool) -> Label

    @State private var pressed = false
    @State private var sentDown = false

    var body: some View {
        ZStack {
            label(pressed)
            KeyTouchSurface(
                shape: hitShape,
                onChanged: { _ in press() },
                onEnded: release
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            EKA2L1Bridge.shared.tapRawKey(scan)
        }
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

// MARK: - Key-cap styling

enum KeyKind {
    case digit, soft
}

private struct KeyCapModifier: ViewModifier {
    let kind: KeyKind
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .scaleEffect(pressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    private var background: Double {
        switch kind {
        case .digit:
            return pressed ? 0.24 : 0.10
        case .soft:
            return pressed ? 0.26 : 0.13
        }
    }
}

private struct KeypadSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
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
}

extension View {
    func keyCap(kind: KeyKind, pressed: Bool) -> some View {
        modifier(KeyCapModifier(kind: kind, pressed: pressed))
    }

    func keypadSurface() -> some View {
        modifier(KeypadSurface())
    }
}

// Fixed-size cap key sending a raw scan code — soft keys, clear key, etc.
struct CapKey: View {
    let scan: UInt32
    var title: String?
    var symbol: String?
    var size: CGSize = CGSize(width: 58, height: 38)

    var body: some View {
        HoldableRawKey(scan: scan) { pressed in
            Group {
                if let title {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(width: size.width, height: size.height)
            .keyCap(kind: .soft, pressed: pressed)
        }
    }
}

// Left/right soft key with the unified symbol treatment. Keeps "LSK"/"RSK"
// accessibility labels — the regression harness drives the soft keys by those
// labels via snapshot-ui.
struct SoftKey: View {
    enum Side {
        case left, right
    }

    let side: Side
    var size: CGSize = CGSize(width: 58, height: 38)

    private var symbolName: String {
        if #available(iOS 17, *) {
            return side == .left ? "l.button.roundedbottom.horizontal" : "r.button.roundedbottom.horizontal"
        }
        return side == .left ? "l.circle" : "r.circle"
    }

    var body: some View {
        CapKey(scan: side == .left ? Scan.leftSoft : Scan.rightSoft,
               symbol: symbolName, size: size)
            .accessibilityLabel(side == .left ? "LSK" : "RSK")
    }
}

// The clear ("C") key — same guest key as hardware backspace.
struct ClearKey: View {
    var size: CGSize = CGSize(width: 58, height: 38)

    var body: some View {
        CapKey(scan: Scan.clear, symbol: "delete.left.fill", size: size)
            .accessibilityLabel("Clear")
    }
}

// MARK: - Sliding d-pad

// Circular four-way pad with a centred OK (select), used by every layout.
// The four direction zones are the ring quadrants split on the diagonals.
// One drag gesture covers the whole ring: holding a direction and sliding the
// finger into another quadrant releases the old key and presses the new one,
// so diagonal corrections don't require lifting the finger. The centre OK is
// its own key — slides across it keep the current direction (games treat OK
// as fire, so a transient press while crossing the middle would misfire).
struct SlidingDPad: View {
    var diameter: CGFloat = 130

    private let innerRatio: CGFloat = 0.34

    @State private var activeScan: UInt32?

    private struct Direction {
        let scan: UInt32
        let symbol: String
        let sectorStart: Double // degrees, SwiftUI convention (0° = +x, cw)
        let labelOffset: CGVector
    }

    private var directions: [Direction] {
        let r = diameter * 0.36
        return [
            Direction(scan: Scan.up, symbol: "chevron.up", sectorStart: 225,
                      labelOffset: CGVector(dx: 0, dy: -r)),
            Direction(scan: Scan.right, symbol: "chevron.right", sectorStart: 315,
                      labelOffset: CGVector(dx: r, dy: 0)),
            Direction(scan: Scan.down, symbol: "chevron.down", sectorStart: 45,
                      labelOffset: CGVector(dx: 0, dy: r)),
            Direction(scan: Scan.left, symbol: "chevron.left", sectorStart: 135,
                      labelOffset: CGVector(dx: -r, dy: 0)),
        ]
    }

    var body: some View {
        let okSize = diameter * innerRatio
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .overlay(PadDividers(innerRatio: innerRatio).stroke(.white.opacity(0.12), lineWidth: 1))

            ForEach(directions, id: \.scan) { dir in
                let pressed = activeScan == dir.scan
                Sector(startAngle: .degrees(dir.sectorStart),
                       endAngle: .degrees(dir.sectorStart + 90),
                       innerRatio: innerRatio)
                    .fill(.white.opacity(pressed ? 0.26 : 0.0001))
                Image(systemName: dir.symbol)
                    .font(.system(size: diameter * 0.1, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .scaleEffect(pressed ? 0.86 : 1)
                    .offset(x: dir.labelOffset.dx, y: dir.labelOffset.dy)
                    .animation(.easeOut(duration: 0.1), value: pressed)
            }

            // Transparent touch surface for the ring. Sits above the sector
            // fills but below OK, so touches starting on OK stay OK.
            KeyTouchSurface(
                shape: .circle,
                onChanged: { point in
                    updateActive(directionScan(at: point))
                },
                onEnded: { updateActive(nil) }
            )

            HoldableRawKey(scan: Scan.select, hitShape: .circle) { pressed in
                Text("OK")
                    .font(.system(size: okSize * 0.28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: okSize, height: okSize)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.12)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    )
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .scaleEffect(pressed ? 0.88 : 1)
                    .opacity(pressed ? 0.7 : 1)
                    .animation(.easeOut(duration: 0.12), value: pressed)
            }
        }
        .frame(width: diameter, height: diameter)
        .onDisappear {
            updateActive(nil)
        }
    }

    // Direction under the finger, or nil to keep the current one (finger over
    // the OK circle mid-slide, or outside the ring — holding past the rim is
    // common in action games and should not drop the direction).
    private func directionScan(at point: CGPoint) -> UInt32? {
        let radius = diameter / 2
        let dx = point.x - radius
        let dy = point.y - radius
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist <= radius * innerRatio {
            return activeScan
        }
        var degrees = atan2(dy, dx) * 180 / .pi // -180..180, 0° = +x, cw
        if degrees < 0 {
            degrees += 360
        }
        switch degrees {
        case 45..<135: return Scan.down
        case 135..<225: return Scan.left
        case 225..<315: return Scan.up
        default: return Scan.right
        }
    }

    private func updateActive(_ scan: UInt32?) {
        guard scan != activeScan else { return }
        if let old = activeScan {
            EKA2L1Bridge.shared.submitRawKey(old, pressed: false)
        }
        if let scan {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            EKA2L1Bridge.shared.submitRawKey(scan, pressed: true)
        }
        activeScan = scan
    }
}

// Annular wedge between innerRatio*R and R, spanning [startAngle, endAngle].
private struct Sector: Shape {
    let startAngle: Angle
    let endAngle: Angle
    var innerRatio: CGFloat = 0.34

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: startAngle,
                    endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: endAngle,
                    endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

// The four diagonal separators (at 45/135/225/315°) from the OK circle out to
// the rim, so the equal quadrant split is visible.
private struct PadDividers: Shape {
    var innerRatio: CGFloat = 0.34

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var path = Path()
        for degrees in stride(from: 45.0, to: 360.0, by: 90.0) {
            let radians = degrees * .pi / 180.0
            let dir = CGPoint(x: cos(radians), y: sin(radians))
            path.move(to: CGPoint(x: center.x + dir.x * inner, y: center.y + dir.y * inner))
            path.addLine(to: CGPoint(x: center.x + dir.x * outer, y: center.y + dir.y * outer))
        }
        return path
    }
}

// MARK: - Numeric pads

// Phone-style 3x4 numeric pad with fixed-size caps (classic layout).
struct CapsNumericPad: View {
    private let columns = Array(repeating: GridItem(.fixed(48), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(keypadDigits, id: \.label) { digit in
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
}

// iOS system-keyboard-style numeric pad: three flexible columns of rounded-rect
// keys that each fill their whole grid cell, so the tap target is large and the
// keys spread across the full available width.
struct FilledNumericPad: View {
    var keyHeight: CGFloat = 56
    var rowSpacing: CGFloat = 8

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: rowSpacing) {
            ForEach(keypadDigits, id: \.label) { digit in
                // Default (rectangular) hit shape so the whole cell is tappable.
                HoldableRawKey(scan: digit.scan) { pressed in
                    VStack(spacing: 0) {
                        Text(digit.label)
                            .font(.system(size: keyHeight * 0.46, weight: .regular, design: .rounded))
                        if !digit.sub.isEmpty {
                            Text(digit.sub)
                                .font(.system(size: max(8, keyHeight * 0.16), weight: .semibold))
                                .tracking(1)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: keyHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(pressed ? 0.30 : 0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
                    .animation(.easeOut(duration: 0.1), value: pressed)
                }
            }
        }
    }
}
