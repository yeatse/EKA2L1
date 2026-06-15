import SwiftUI
import UIKit

// Symbian standard scan codes (see services/window/keys.h).
enum Scan {
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

// On-screen control layouts the user can pick between in Settings. Persisted as
// a raw string under @AppStorage("ios.keypadLayout"); the emulator screen reads
// the same key to decide which keypad to render. New cases must keep their raw
// value stable so previously-saved preferences keep resolving.
enum KeypadLayout: String, CaseIterable, Identifiable {
    // Classic: soft keys + call/end + d-pad/OK on the left, full numeric pad on
    // the right. Everything visible at once.
    case full
    // Modern compact: just the d-pad/OK and the two soft keys. A toggle swaps
    // the centre cluster between the d-pad and a numeric pad, so titles that are
    // only driven with the direction keys get a smaller, cleaner overlay.
    case compact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: return "Classic"
        case .compact: return "Compact"
        }
    }

    static let storageKey = "ios.keypadLayout"
    static let `default` = KeypadLayout.full

    static func resolve(_ raw: String) -> KeypadLayout {
        // The regression harness launches with `-EKA2L1RegressionMode 1`, which
        // lands in NSArgumentDomain. Pin the classic layout when it is set so
        // the script's soft-key assertions don't depend on the developer's saved
        // preference; the argument domain is volatile, so the stored value is
        // left untouched.
        if UserDefaults.standard.bool(forKey: "EKA2L1RegressionMode") {
            return .full
        }
        return KeypadLayout(rawValue: raw) ?? .default
    }
}

// Digit, the phone-style letters under it, and the raw scan code. Shared by the
// classic and compact numeric pads so both stay identical.
private let keypadDigits: [(label: String, sub: String, scan: UInt32)] = [
    ("1", "", 0x31), ("2", "ABC", 0x32), ("3", "DEF", 0x33),
    ("4", "GHI", 0x34), ("5", "JKL", 0x35), ("6", "MNO", 0x36),
    ("7", "PQRS", 0x37), ("8", "TUV", 0x38), ("9", "WXYZ", 0x39),
    ("\u{2217}", "", Scan.star), ("0", "+", 0x30), ("#", "", Scan.hash)
]

// Entry point used by EmulatorView: renders the keypad for the selected layout.
struct VirtualKeypad: View {
    let layout: KeypadLayout

    var body: some View {
        switch layout {
        case .full: ClassicKeypad()
        case .compact: CompactKeypad()
        }
    }
}

// MARK: - Classic (original) layout

private struct ClassicKeypad: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            navigationCluster
            NumericPad()
        }
        .keypadSurface()
    }

    // Soft keys, call / end, and the navigation pad.
    private var navigationCluster: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                softKey("LSK", scan: Scan.leftSoft)
                softKey("RSK", scan: Scan.rightSoft)
            }
            HStack(spacing: 10) {
                callKey(.symbol("phone.fill"), scan: Scan.call, kind: .call)
                callKey(.symbol("phone.down.fill"), scan: Scan.end, kind: .end)
            }
            DPad()
        }
    }

    private func softKey(_ title: String, scan: UInt32) -> some View {
        HoldableRawKey(scan: scan) { pressed in
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 58, height: 38)
                .keyCap(kind: .soft, pressed: pressed)
        }
    }

    private func callKey(_ label: KeyLabel, scan: UInt32, kind: KeyKind) -> some View {
        HoldableRawKey(scan: scan) { pressed in
            label.view
                .frame(width: 58, height: 38)
                .keyCap(kind: kind, pressed: pressed)
        }
    }
}

// MARK: - Compact (modern) layout

private struct CompactKeypad: View {
    @State private var showNumeric = false

    // Both modes are pinned to this content height so toggling never resizes the
    // game view above — a shorter/taller keypad would otherwise hand a different
    // height to the emulator's GeometryReader and rescale the frame.
    private let contentHeight: CGFloat = 248
    private let topRowHeight: CGFloat = 40
    private let rowSpacing: CGFloat = 8

    // Height of each number row, sized to exactly fill the space left under the
    // top row so all four rows reach the bottom of the fixed content height.
    private var numberKeyHeight: CGFloat {
        (contentHeight - topRowHeight - 10 - rowSpacing * 3) / 4
    }

    var body: some View {
        Group {
            if showNumeric {
                numericMode
                    .transition(.opacity)
            } else {
                directionalMode
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: contentHeight)
        .keypadSurface()
    }

    // Direction-only mode: soft keys pinned to the top corners, a large four-way
    // pad in the centre, and the mode toggle tucked into the bottom-right.
    private var directionalMode: some View {
        ZStack {
            DirectionalPad(diameter: 188)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            cornerSoftKey(scan: Scan.leftSoft, mirrored: true)
        }
        .overlay(alignment: .topTrailing) {
            cornerSoftKey(scan: Scan.rightSoft, mirrored: false)
        }
        .overlay(alignment: .bottomTrailing) {
            modeToggle
        }
    }

    // Numeric mode: soft keys + toggle on a top row, then an iOS-dial-style 3x4
    // pad that spreads across the full width instead of clustering in the middle.
    private var numericMode: some View {
        VStack(spacing: 10) {
            HStack {
                cornerSoftKey(scan: Scan.leftSoft, mirrored: true)
                Spacer()
                modeToggle
                Spacer()
                cornerSoftKey(scan: Scan.rightSoft, mirrored: false)
            }
            .frame(height: topRowHeight)
            NativeNumericPad(keyHeight: numberKeyHeight, rowSpacing: rowSpacing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modeToggle: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.18)) {
                showNumeric.toggle()
            }
        } label: {
            Image(systemName: showNumeric ? "dpad.fill" : "square.grid.3x3.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.13))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showNumeric ? "Switch to direction pad" : "Switch to number pad")
    }

    private func cornerSoftKey(scan: UInt32, mirrored: Bool) -> some View {
        HoldableRawKey(scan: scan) { pressed in
            Image(systemName: "chevron.up.right.2")
                .font(.system(size: 17, weight: .semibold))
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                .frame(width: 54, height: 40)
                .keyCap(kind: .soft, pressed: pressed)
        }
    }
}

// MARK: - Shared clusters

// Circular four-way pad with a centred OK (select). Used by both layouts.
private struct DPad: View {
    var diameter: CGFloat = 130

    var body: some View {
        let ring = diameter
        let arrowOffset = diameter * 0.346
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .frame(width: ring, height: ring)

            arrow("chevron.up", scan: Scan.up).offset(y: -arrowOffset)
            arrow("chevron.down", scan: Scan.down).offset(y: arrowOffset)
            arrow("chevron.left", scan: Scan.left).offset(x: -arrowOffset)
            arrow("chevron.right", scan: Scan.right).offset(x: arrowOffset)

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
        .frame(width: ring, height: ring)
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
}

// Phone-style 3x4 numeric pad (1-9, *, 0, #). Used by both layouts.
private struct NumericPad: View {
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

// Large four-way pad whose hit zones are the four quadrants of the ring (split
// on the diagonals), with a centred OK. Used by the compact layout. Pressing a
// quadrant highlights that wedge so the active zone is obvious.
private struct DirectionalPad: View {
    var diameter: CGFloat = 188

    private let innerRatio: CGFloat = 0.34

    var body: some View {
        let okSize = diameter * innerRatio
        let labelRadius = diameter * 0.36
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

            // Angles use SwiftUI's convention (0° = +x, growing clockwise because
            // y points down): up is centred on 270°, right on 0°, etc.
            sector(scan: Scan.up, symbol: "chevron.up", from: 225, to: 315,
                   offset: CGSize(width: 0, height: -labelRadius))
            sector(scan: Scan.right, symbol: "chevron.right", from: 315, to: 405,
                   offset: CGSize(width: labelRadius, height: 0))
            sector(scan: Scan.down, symbol: "chevron.down", from: 45, to: 135,
                   offset: CGSize(width: 0, height: labelRadius))
            sector(scan: Scan.left, symbol: "chevron.left", from: 135, to: 225,
                   offset: CGSize(width: -labelRadius, height: 0))

            HoldableRawKey(scan: Scan.select, hitShape: AnyShape(Circle())) { pressed in
                Text("OK")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
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
    }

    private func sector(scan: UInt32, symbol: String, from: Double, to: Double,
                        offset: CGSize) -> some View {
        let shape = Sector(startAngle: .degrees(from), endAngle: .degrees(to),
                           innerRatio: innerRatio)
        return HoldableRawKey(scan: scan, hitShape: AnyShape(shape)) { pressed in
            ZStack {
                shape.fill(.white.opacity(pressed ? 0.26 : 0.0001))
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .scaleEffect(pressed ? 0.86 : 1)
                    .offset(offset)
            }
            .frame(width: diameter, height: diameter)
            .animation(.easeOut(duration: 0.1), value: pressed)
        }
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

// iOS system-keyboard-style numeric pad: three flexible columns of rounded-rect
// keys that each fill their whole grid cell, so the tap target is large and the
// keys spread across the full width instead of clustering in the centre.
private struct NativeNumericPad: View {
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

// MARK: - Shared building blocks

enum KeyLabel {
    case text(String)
    case symbol(String)

    @ViewBuilder var view: some View {
        switch self {
        case .text(let value):
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
        case .symbol(let value):
            Image(systemName: value).font(.system(size: 16, weight: .semibold))
        }
    }
}

enum KeyKind {
    case digit, soft, call, end
}

struct HoldableRawKey<Label: View>: View {
    let scan: UInt32
    // Hit-test region for the key. Defaults to the full bounding rect; the
    // direction sectors and the round number keys pass a precise shape so
    // neighbouring keys don't overlap.
    var hitShape: AnyShape = AnyShape(Rectangle())
    @ViewBuilder let label: (Bool) -> Label

    @State private var pressed = false
    @State private var sentDown = false

    var body: some View {
        label(pressed)
            .contentShape(hitShape)
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
            .foregroundStyle(.white)
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

    fileprivate func keypadSurface() -> some View {
        modifier(KeypadSurface())
    }
}
