import SwiftUI
import UIKit

// Shared building blocks for the on-screen keypad layouts in VirtualKeypad.swift:
// scan codes, the press/release key primitive, key-cap styling, the d-pad and
// the numeric pads.

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
    static let edit: UInt32 = 0x12     // std_key_left_shift
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

enum Keypad {
    // Barely-there tick: keys and the d-pad fire several times a second.
    static let hapticIntensity = 0.3
}

struct HoldableRawKey<Label: View>: View {
    let scan: UInt32
    // Hit-test region for the key. Defaults to the full bounding rect; round
    // keys pass a precise shape so neighbouring keys don't overlap.
    var hitShape: AnyShape = AnyShape(Rectangle())
    @ViewBuilder let label: (Bool) -> Label

    @State private var pressed = false
    @State private var sentDown = false
    @State private var impacts = 0

    var body: some View {
        label(pressed)
            .contentShape(hitShape)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                EKA2L1Bridge.shared.tapRawKey(scan)
            }
            // SwiftUI's zero-distance DragGesture fires late on iOS 27; UIKit
            // touchesBegan reports the press as soon as the finger lands.
            .overlay(
                KeyTouchSurface(hitShape: hitShape, onPress: press, onRelease: release)
                    .accessibilityHidden(true)
            )
            .onDisappear(perform: release)
            .hapticImpact(.light, intensity: Keypad.hapticIntensity, trigger: impacts)
    }

    private func press() {
        guard !sentDown else { return }
        sentDown = true
        pressed = true
        impacts += 1
        EKA2L1Bridge.shared.submitRawKey(scan, pressed: true)
    }

    private func release() {
        guard sentDown else { return }
        sentDown = false
        pressed = false
        EKA2L1Bridge.shared.submitRawKey(scan, pressed: false)
    }
}

private struct KeyTouchSurface: UIViewRepresentable {
    let hitShape: AnyShape
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeUIView(context: Context) -> KeyTouchView {
        let view = KeyTouchView()
        configure(view)
        return view
    }

    func updateUIView(_ view: KeyTouchView, context: Context) {
        configure(view)
    }

    static func dismantleUIView(_ view: KeyTouchView, coordinator: ()) {
        view.reset()
    }

    private func configure(_ view: KeyTouchView) {
        view.hitShape = hitShape
        view.onPress = onPress
        view.onRelease = onRelease
    }
}

private final class KeyTouchView: UIView {
    var hitShape: AnyShape = AnyShape(Rectangle())
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    // The key stays held until every finger that landed on it has lifted,
    // even if those fingers slide outside the key.
    private var activeTouches: Set<ObjectIdentifier> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hitShape.path(in: bounds).contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasIdle = activeTouches.isEmpty
        for touch in touches {
            activeTouches.insert(ObjectIdentifier(touch))
        }
        if wasIdle && !activeTouches.isEmpty {
            onPress?()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        remove(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        remove(touches)
    }

    func reset() {
        guard !activeTouches.isEmpty else { return }
        activeTouches.removeAll()
        onRelease?()
    }

    private func remove(_ touches: Set<UITouch>) {
        guard !activeTouches.isEmpty else { return }
        for touch in touches {
            activeTouches.remove(ObjectIdentifier(touch))
        }
        if activeTouches.isEmpty {
            onRelease?()
        }
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
        if #available(iOS 26.0, *) {
            content
                .foregroundStyle(.white)
                .glassEffect(.regular.interactive(),
                             in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            legacyBody(content)
        }
    }

    private func legacyBody(_ content: Content) -> some View {
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
    var tint: Color?
    var size: CGSize = CGSize(width: 58, height: 38)

    var body: some View {
        HoldableRawKey(scan: scan) { pressed in
            Group {
                if let title {
                    Text(title)
                        .font(.system(size: min(18, max(13, size.height * 0.4)),
                                      weight: .semibold,
                                      design: .rounded))
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint ?? .white)
                }
            }
            .frame(width: size.width, height: size.height)
            .keyCap(kind: .soft, pressed: pressed)
        }
    }
}

// Left/right soft key. The visible labels stay deliberately plain while the
// accessibility labels remain "LSK"/"RSK" for the regression harness.
struct SoftKey: View {
    enum Side {
        case left, right
    }

    let side: Side
    var size: CGSize = CGSize(width: 58, height: 38)

    var body: some View {
        CapKey(scan: side == .left ? Scan.leftSoft : Scan.rightSoft,
               title: side == .left ? "L" : "R",
               size: size)
            .accessibilityLabel(Text(verbatim: side == .left ? "LSK" : "RSK"))
    }
}

// Green and red phone keys: EStdKeyApplication0 and EStdKeyApplication1.
struct PhoneKey: View {
    enum Side {
        case call, end
    }

    let side: Side
    var size: CGSize = CGSize(width: 58, height: 38)

    var body: some View {
        CapKey(scan: side == .call ? Scan.call : Scan.end,
               symbol: side == .call ? "phone.fill" : "phone.down.fill",
               tint: side == .call ? .green : .red,
               size: size)
            .accessibilityLabel(Text(side == .call ? LocalizedStringKey("keypad.accessibility.call")
                                                   : LocalizedStringKey("keypad.accessibility.end")))
    }
}

struct EditKey: View {
    var size: CGSize = CGSize(width: 58, height: 38)

    var body: some View {
        CapKey(scan: Scan.edit, symbol: "pencil", size: size)
            .accessibilityLabel(Text("key.edit"))
    }
}

// The clear ("C") key — same guest key as hardware backspace.
struct ClearKey: View {
    var size: CGSize = CGSize(width: 58, height: 38)

    var body: some View {
        CapKey(scan: Scan.clear, symbol: "delete.left.fill", size: size)
            .accessibilityLabel(Text("keypad.accessibility.clear"))
    }
}

// MARK: - D-pad

// Ring of eight 45° direction sectors around a fixed OK key. A touch on the
// ring presses the direction under it at once, then steers like a virtual
// stick; diagonals hold both axis keys. A touch that starts on OK holds it
// until it slides onto the ring, where it lets go of OK and steers instead.
// One touch steers at a time; another finger can still hold OK.
struct DirectionPad: View {
    var diameter: CGFloat = 130

    private let okRatio: CGFloat = 0.4

    @State private var activeScans: Set<UInt32> = []
    @State private var sector: Int?
    @State private var okPressed = false
    @State private var impacts = 0

    private static let cardinals: [(symbol: String, sector: Int)] = [
        ("chevron.right", 0), ("chevron.down", 2), ("chevron.left", 4), ("chevron.up", 6),
    ]

    private var usesGlass: Bool {
        if #available(iOS 26.0, *) { true } else { false }
    }

    var body: some View {
        let radius = diameter / 2
        ZStack {
            ring

            if let sector {
                highlight(sector)
            }

            ForEach(Self.cardinals, id: \.sector) { cardinal in
                let lit = sector.map { abs(Self.sectorDistance($0, cardinal.sector)) <= 1 } ?? false
                let angle = Double(cardinal.sector) * .pi / 4
                Image(systemName: cardinal.symbol)
                    .font(.system(size: diameter * 0.1, weight: .semibold))
                    .foregroundStyle(.white.opacity(lit ? 0.95 : (usesGlass ? 0.55 : 0.9)))
                    .scaleEffect(lit && !usesGlass ? 0.86 : 1)
                    .offset(x: cos(angle) * radius * 0.72, y: sin(angle) * radius * 0.72)
            }

            okCap(size: diameter * okRatio)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "OK"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    EKA2L1Bridge.shared.tapRawKey(Scan.select)
                }

            // SwiftUI's DragGesture tracks one touch and starts late; the UIKit
            // surface sees every finger as it lands.
            DPadTouchSurface(okRatio: okRatio, onChange: update)
                .accessibilityHidden(true)
        }
        .frame(width: diameter, height: diameter)
        .onDisappear {
            update(DPadState())
        }
        .hapticImpact(.light, intensity: Keypad.hapticIntensity, trigger: impacts)
    }

    @ViewBuilder private var ring: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
    }

    @ViewBuilder private func highlight(_ sector: Int) -> some View {
        if usesGlass {
            SectorArc(sector: sector)
                .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .padding(3)
                .shadow(color: .white.opacity(0.5), radius: 4)
        } else {
            let centre = Double(sector) * 45
            Sector(startAngle: .degrees(centre - 22.5), endAngle: .degrees(centre + 22.5),
                   innerRatio: okRatio)
                .fill(.white.opacity(0.26))
        }
    }

    private func okCap(size: CGFloat) -> some View {
        let top = usesGlass ? 0.38 : 0.28
        let bottom = usesGlass ? 0.14 : 0.12
        return Text(verbatim: "OK")
            .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(
                    LinearGradient(colors: [.white.opacity(top), .white.opacity(bottom)],
                                   startPoint: .top, endPoint: .bottom)
                )
            )
            .overlay(Circle().strokeBorder(.white.opacity(usesGlass ? 0.4 : 0.25), lineWidth: 1))
            .shadow(color: .black.opacity(usesGlass ? 0.3 : 0), radius: 6, y: 2)
            .scaleEffect(okPressed ? 0.88 : 1)
            .opacity(okPressed && !usesGlass ? 0.7 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.62), value: okPressed)
    }

    private func update(_ state: DPadState) {
        withAnimation(.easeOut(duration: 0.1)) {
            sector = state.sector
        }
        okPressed = state.okPressed

        var scans = Self.scans(for: state.sector)
        if state.okPressed {
            scans.insert(Scan.select)
        }
        guard scans != activeScans else { return }
        for scan in activeScans.subtracting(scans).sorted() {
            EKA2L1Bridge.shared.submitRawKey(scan, pressed: false)
        }
        let pressedScans = scans.subtracting(activeScans)
        for scan in pressedScans.sorted() {
            EKA2L1Bridge.shared.submitRawKey(scan, pressed: true)
        }
        if !pressedScans.isEmpty {
            impacts += 1
        }
        activeScans = scans
    }

    // Sector 0 is +x and sectors advance clockwise in screen space.
    private static func scans(for sector: Int?) -> Set<UInt32> {
        guard let sector else { return [] }
        var scans: Set<UInt32> = []
        if [7, 0, 1].contains(sector) { scans.insert(Scan.right) }
        if [1, 2, 3].contains(sector) { scans.insert(Scan.down) }
        if [3, 4, 5].contains(sector) { scans.insert(Scan.left) }
        if [5, 6, 7].contains(sector) { scans.insert(Scan.up) }
        return scans
    }

    private static func sectorDistance(_ a: Int, _ b: Int) -> Int {
        (a - b + 12) % 8 - 4
    }
}

private struct DPadState: Equatable {
    var sector: Int?
    var okPressed = false
}

// Rim highlight spanning one 45° sector.
private struct SectorArc: Shape {
    let sector: Int

    func path(in rect: CGRect) -> Path {
        let centre = Double(sector) * 45
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(centre - 18), endAngle: .degrees(centre + 18),
                    clockwise: false)
        return path
    }
}

// Annular wedge between innerRatio*R and R, spanning [startAngle, endAngle].
private struct Sector: Shape {
    let startAngle: Angle
    let endAngle: Angle
    var innerRatio: CGFloat = 0.4

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

private struct DPadTouchSurface: UIViewRepresentable {
    let okRatio: CGFloat
    let onChange: (DPadState) -> Void

    func makeUIView(context: Context) -> DPadTouchView {
        let view = DPadTouchView()
        configure(view)
        return view
    }

    func updateUIView(_ view: DPadTouchView, context: Context) {
        configure(view)
    }

    static func dismantleUIView(_ view: DPadTouchView, coordinator: ()) {
        view.reset()
    }

    private func configure(_ view: DPadTouchView) {
        view.okRatio = okRatio
        view.onChange = onChange
    }
}

private final class DPadTouchView: UIView {
    var okRatio: CGFloat = 0.4
    var onChange: ((DPadState) -> Void)?

    // Dead zone as a fraction of the radius, with hysteresis so a finger
    // resting on the boundary does not chatter the keys.
    private let engageRatio: CGFloat = 0.3
    private let releaseRatio: CGFloat = 0.22
    // Extra degrees a finger must pass a sector edge before switching.
    private let sectorHysteresis: Double = 7

    private var okTouches: Set<ObjectIdentifier> = []
    private var steeringTouch: ObjectIdentifier?
    private var sector: Int?
    private var published = DPadState()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    private var radius: CGFloat {
        min(bounds.width, bounds.height) / 2
    }

    private func distance(_ point: CGPoint) -> CGFloat {
        hypot(point.x - bounds.midX, point.y - bounds.midY)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        distance(point) <= radius
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            if distance(point) <= radius * okRatio {
                okTouches.insert(id)
            } else if steeringTouch == nil {
                steeringTouch = id
                steer(point)
            }
        }
        publish()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            if okTouches.contains(id) && distance(point) > radius * okRatio {
                okTouches.remove(id)
                if steeringTouch == nil {
                    steeringTouch = id
                }
            }
            if id == steeringTouch {
                steer(point)
            }
        }
        publish()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    func reset() {
        okTouches.removeAll()
        steeringTouch = nil
        sector = nil
        publish()
    }

    private func end(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            okTouches.remove(id)
            if id == steeringTouch {
                steeringTouch = nil
                sector = nil
            }
        }
        publish()
    }

    private func steer(_ point: CGPoint) {
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        let threshold = radius * (sector == nil ? engageRatio : releaseRatio)
        guard hypot(dx, dy) >= threshold else {
            sector = nil
            return
        }

        let degrees = atan2(dy, dx) * 180 / .pi
        let nearest = (Int((degrees / 45).rounded()) % 8 + 8) % 8
        if let current = sector {
            var delta = abs(degrees - Double(current) * 45).truncatingRemainder(dividingBy: 360)
            delta = min(delta, 360 - delta)
            if delta > 22.5 + sectorHysteresis {
                sector = nearest
            }
        } else {
            sector = nearest
        }
    }

    private func publish() {
        let state = DPadState(sector: sector, okPressed: !okTouches.isEmpty)
        guard state != published else { return }
        published = state
        onChange?(state)
    }
}

// MARK: - Numeric pads

// Phone-style 3x4 numeric pad. Glass caps need a wider gap than the flat
// pre-26 caps to read as separate keys.
struct CapsNumericPad: View {
    var size = CGSize(width: 150, height: 208)

    private var spacing: CGFloat {
        if #available(iOS 26.0, *) { 4 } else { 2 }
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                grid
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        let keyHeight = (size.height - spacing * 3) / 4
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
        return LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(keypadDigits, id: \.label) { digit in
                HoldableRawKey(scan: digit.scan) { pressed in
                    VStack(spacing: 1) {
                        Text(digit.label)
                            .font(.system(size: size.height / 10.4,
                                          weight: .semibold,
                                          design: .rounded))
                        if !digit.sub.isEmpty {
                            Text(digit.sub)
                                .font(.system(size: max(7, size.height / 29.7),
                                              weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: keyHeight)
                    .keyCap(kind: .digit, pressed: pressed)
                }
            }
        }
        .frame(width: size.width, height: size.height)
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
