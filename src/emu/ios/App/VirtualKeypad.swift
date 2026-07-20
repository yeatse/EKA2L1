import SwiftUI
import UIKit

// On-screen control layouts the user can pick between in Settings or from the
// in-game system menu. Persisted as a raw string under
// @AppStorage("ios.keypadLayout"); the emulator screen reads the same key to
// decide which keypad to render. New cases must keep their raw value stable so
// previously-saved preferences keep resolving.
enum KeypadLayout: String, CaseIterable, Identifiable {
    // Classic: soft keys + system/clear keys + d-pad on the left, full numeric
    // pad on the right. Everything visible at once.
    case full
    // Modern compact: d-pad/OK plus the corner keys. A toggle swaps the centre
    // cluster between the d-pad and a numeric pad.
    case compact
    // Landscape, N-Gage QD style: d-pad + left soft key + system key down the
    // left edge, numeric pad + right soft key + clear key down the right edge,
    // the game picture centred between them.
    case ngage
    // Touch devices (S60v5, e.g. the 5230): the guest UI is driven by touch,
    // so only the system menu key floats in the bottom-right corner.
    case fullscreen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: return String(localized: "keypad.layout.classic")
        case .compact: return String(localized: "keypad.layout.compact")
        case .ngage: return String(localized: "keypad.layout.ngage")
        case .fullscreen: return String(localized: "keypad.layout.fullscreen")
        }
    }

    static let storageKey = "ios.keypadLayout"
    // Touch-driven ROMs (S60v5 / Symbian^3+) keep their own preference: their
    // guest UI is finger-operated, so they default to the fullscreen layout
    // while keypad-driven ROMs default to the classic key grid.
    static let touchStorageKey = "ios.keypadLayout.touch"
    static let `default` = KeypadLayout.full
    static let touchDefault = KeypadLayout.fullscreen

    static func resolve(_ raw: String) -> KeypadLayout {
        // The regression harness launches with `-EKA2L1RegressionMode 1`. Pin
        // the classic layout when it is set so the script's soft-key assertions
        // don't depend on the developer's saved preference.
        if UserDefaults.standard.bool(forKey: "EKA2L1RegressionMode") {
            return .full
        }
        return KeypadLayout(rawValue: raw) ?? .default
    }

    // Testing/debug launch argument, e.g.
    //   xcrun simctl launch booted com.eka2l1.emulator -LaunchKeypadLayout ngage
    // Applied once by the emulator screen as the session's starting layout (a
    // permanent resolve() override would block switching layouts in-session).
    static func launchArgumentLayout() -> KeypadLayout? {
        guard let forced = UserDefaults.standard.string(forKey: "LaunchKeypadLayout") else {
            return nil
        }
        return KeypadLayout(rawValue: forced)
    }

    // Where EmulatorView pins the keypad overlay. Keypads never resize the
    // game view; they float above it.
    var overlayAlignment: Alignment {
        switch self {
        case .full, .compact: return .bottom
        case .ngage: return .center
        case .fullscreen: return .bottomTrailing
        }
    }

    // Bottom-keypad layouts top-align the guest picture so the keys cover
    // letterbox instead of gameplay. Centred layouts keep the picture centred.
    var prefersTopAnchoredDisplay: Bool {
        self == .full || self == .compact
    }

    // Interface orientations the emulator screen permits while this layout is
    // active. The keypad layouts are drawn for one fixed orientation and pin
    // it (classic/compact portrait, N-Gage landscape). The fullscreen (touch)
    // layout carries no keypad furniture, so it lets the user rotate freely —
    // a landscape guest such as Angry Birds then fills the screen once the
    // device is turned sideways instead of sitting letterboxed in portrait.
    var supportedOrientations: UIInterfaceOrientationMask {
        switch self {
        case .full, .compact: return .portrait
        case .ngage: return .landscape
        case .fullscreen: return .allButUpsideDown
        }
    }

    // True when the layout follows the physical device rather than pinning a
    // single orientation. Free-rotation layouts must not force a rotation on
    // entry — they leave the current orientation alone and just widen the
    // allowed set.
    var allowsFreeRotation: Bool {
        self == .fullscreen
    }
}

// What the keypad's system menu key needs from the hosting screen: the layout
// selection (EmulatorView owns which preference store backs it) and the
// actions that operate on the emulator session.
struct KeypadMenuActions {
    var layoutSelection: Binding<String>
    var rotateGuestScreen: () -> Void
    // Per-game frame-rate cap shown in the Game Settings submenu: 15 / 30 / 60,
    // or 0 for unlimited.
    var frameLimit: Binding<Int>
    // Opens the floating opacity slider hosted by EmulatorView. A UIMenu can't
    // host a live slider, so the menu item just asks the screen to present one.
    var adjustOpacity: () -> Void
    var saveScreenshot: () -> Void
    var exitGame: () -> Void
}

// Keypad appearance defaults shared between the layouts and Settings.
enum KeypadDefaults {
    static let opacityKey = "ios.keypadOpacity"
    static let opacity = 0.85
    // Overlay opacity bounds (fully opaque down to a still-usable minimum, so
    // the floating menu key can never disappear entirely).
    static let opacityRange: ClosedRange<Double> = 0.1...1.0
}

// Entry point used by EmulatorView: renders the keypad for the selected layout.
struct VirtualKeypad: View {
    let layout: KeypadLayout
    let actions: KeypadMenuActions

    var body: some View {
        switch layout {
        case .full: ClassicKeypad(actions: actions)
        case .compact: CompactKeypad(actions: actions)
        case .ngage: NGageKeypad(actions: actions)
        case .fullscreen: FullscreenKeypad(actions: actions)
        }
    }
}

// MARK: - System menu key

// The "system function" key: opens a native menu with a Keypad Settings and a
// Game Settings submenu, screenshot and exit. Menu-native controls (Picker) are
// hosted inline; opacity, which needs a live slider a UIMenu can't host, opens a
// floating bar owned by EmulatorView instead.
// Present in every layout so the emulator screen works without a navigation bar.
struct SystemMenuKey: View {
    let actions: KeypadMenuActions
    var size: CGSize = CGSize(width: 58, height: 38)

    @AppStorage(KeypadDefaults.opacityKey) private var keypadOpacity = KeypadDefaults.opacity

    var body: some View {
        Menu {
            Menu {
                Picker("emulator.menu.keypadLayout", selection: actions.layoutSelection) {
                    ForEach(KeypadLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout.rawValue)
                    }
                }
                Divider()
                Button {
                    actions.adjustOpacity()
                } label: {
                    Label("emulator.menu.opacityValue \(keypadOpacity.formatted(.percent.precision(.fractionLength(0))))",
                          systemImage: "slider.horizontal.below.rectangle")
                }
            } label: {
                Label("emulator.menu.keypadSettings", systemImage: "keyboard")
            }
            Menu {
                fpsLimitPicker
                Divider()
                Button {
                    actions.rotateGuestScreen()
                } label: {
                    Label("emulator.menu.rotateGuestScreen", systemImage: "rotate.right")
                }
            } label: {
                Label("emulator.menu.gameSettings", systemImage: "slider.horizontal.3")
            }
            Button {
                actions.saveScreenshot()
            } label: {
                Label("emulator.saveScreenshot", systemImage: "camera")
            }
            Button(role: .destructive) {
                actions.exitGame()
            } label: {
                Label("emulator.exit", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: size.width, height: size.height)
                .keyCap(kind: .soft, pressed: false)
        }
        .accessibilityLabel("emulator.menu")
    }

    // 15 / 30 / 60 are numeric units shown verbatim; only "Unlimited" (tag 0,
    // matching the bridge's unlimited sentinel) is localized. The palette style
    // renders the options as an inline row inside the menu; it is iOS 17+, so
    // pre-17 falls back to the default menu picker.
    @ViewBuilder
    private var fpsLimitPicker: some View {
        let picker = Picker("emulator.menu.fpsLimit", selection: actions.frameLimit) {
            Text(verbatim: "15").tag(15)
            Text(verbatim: "30").tag(30)
            Text(verbatim: "60").tag(60)
            Text("emulator.fpsLimit.unlimited").tag(0)
        }
        if #available(iOS 17, *) {
            picker.pickerStyle(.palette)
        } else {
            picker
        }
    }
}

// MARK: - Classic (original) layout

private struct ClassicKeypad: View {
    let actions: KeypadMenuActions

    // Match the right-hand numeric pad's height (4 rows of 49 + 3 gaps of 10)
    // so the cluster's top/bottom edges line up with it. The taller cluster
    // also pushes the corner keys clear of the d-pad, leaving a small vertical
    // gap instead of touching it.
    private let clusterSize = CGSize(width: 156, height: 4 * 49 + 3 * 10)
    private let cornerKeySize = CGSize(width: 52, height: 34)

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            navigationCluster
            Spacer(minLength: 8)
            CapsNumericPad()
        }
        .frame(maxWidth: .infinity)
        .keypadSurface()
    }

    // A large d-pad fills the centre; the four function keys tuck into the
    // corners, clear of the round pad with a small vertical gap.
    private var navigationCluster: some View {
        SlidingDPad(diameter: 148)
            .frame(width: clusterSize.width, height: clusterSize.height)
            .overlay(alignment: .topLeading) {
                SoftKey(side: .left, size: cornerKeySize)
            }
            .overlay(alignment: .topTrailing) {
                SoftKey(side: .right, size: cornerKeySize)
            }
            .overlay(alignment: .bottomLeading) {
                SystemMenuKey(actions: actions, size: cornerKeySize)
            }
            .overlay(alignment: .bottomTrailing) {
                ClearKey(size: cornerKeySize)
            }
    }
}

// MARK: - Compact (modern) layout

private struct CompactKeypad: View {
    let actions: KeypadMenuActions

    @State private var showNumeric = false

    private let contentHeight: CGFloat = 248
    private let topRowHeight: CGFloat = 40
    private let rowSpacing: CGFloat = 8
    private let cornerKeySize = CGSize(width: 54, height: 40)

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
    // pad in the centre, system key / mode toggle in the bottom corners and the
    // clear key on the trailing edge.
    private var directionalMode: some View {
        SlidingDPad(diameter: 188)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                SoftKey(side: .left, size: cornerKeySize)
            }
            .overlay(alignment: .topTrailing) {
                SoftKey(side: .right, size: cornerKeySize)
            }
            .overlay(alignment: .bottomLeading) {
                SystemMenuKey(actions: actions, size: cornerKeySize)
            }
            .overlay(alignment: .trailing) {
                ClearKey(size: cornerKeySize)
            }
            .overlay(alignment: .bottomTrailing) {
                modeToggle
            }
    }

    // Numeric mode: soft keys plus the centre cluster (system, toggle, clear)
    // on a top row, then an iOS-dial-style 3x4 pad across the full width.
    private var numericMode: some View {
        VStack(spacing: 10) {
            HStack {
                SoftKey(side: .left, size: cornerKeySize)
                Spacer()
                SystemMenuKey(actions: actions, size: cornerKeySize)
                modeToggle
                ClearKey(size: cornerKeySize)
                Spacer()
                SoftKey(side: .right, size: cornerKeySize)
            }
            .frame(height: topRowHeight)
            FilledNumericPad(keyHeight: numberKeyHeight, rowSpacing: rowSpacing)
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
        .accessibilityLabel(Text(showNumeric ? "keypad.accessibility.toDirectionPad" : "keypad.accessibility.toNumberPad"))
    }

}

// MARK: - N-Gage QD style landscape layout

// Whole-screen landscape overlay: the game picture stays centred, the left
// edge carries LSK / d-pad / system key and the right edge RSK / numeric pad /
// clear key — mirroring how an N-Gage QD sits in the hands.
private struct NGageKeypad: View {
    let actions: KeypadMenuActions

    private let edgeKeySize = CGSize(width: 64, height: 40)
    private let padColumnWidth: CGFloat = 178

    var body: some View {
        HStack {
            VStack(spacing: 12) {
                SoftKey(side: .left, size: edgeKeySize)
                Spacer(minLength: 8)
                SlidingDPad(diameter: 182)
                Spacer(minLength: 8)
                SystemMenuKey(actions: actions, size: edgeKeySize)
            }
            .frame(width: 190)
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                SoftKey(side: .right, size: edgeKeySize)
                Spacer(minLength: 8)
                FilledNumericPad(keyHeight: 42, rowSpacing: 6)
                    .frame(width: padColumnWidth)
                Spacer(minLength: 8)
                ClearKey(size: edgeKeySize)
            }
            .frame(width: 190)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Fullscreen (touch devices) layout

// S60v5-class devices are driven through the touch screen itself; only the
// system menu key floats in the corner so the screen stays clear.
private struct FullscreenKeypad: View {
    let actions: KeypadMenuActions

    var body: some View {
        SystemMenuKey(actions: actions, size: CGSize(width: 46, height: 40))
    }
}

// MARK: - Floating opacity slider

// Horizontal bar EmulatorView floats at the bottom-centre while the user tunes
// the keypad opacity. The slider drives the shared opacity preference directly,
// so the keypad fades live as it moves; the circular checkmark dismisses it.
struct OpacitySliderBar: View {
    @Binding var opacity: Double
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "keyboard")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Slider(value: $opacity, in: KeypadDefaults.opacityRange)
                .tint(.white)
                .frame(minWidth: 180)
            Text(opacity.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 42, alignment: .trailing)
            doneButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .accessibilityLabel("settings.keypadOpacity")
    }

    // Circular checkmark. .circle button-border shape is iOS 17+, so pre-17
    // falls back to the capsule shape available since iOS 15.
    @ViewBuilder
    private var doneButton: some View {
        let button = Button {
            onDone()
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("common.done")
        if #available(iOS 17, *) {
            button.buttonBorderShape(.circle)
        } else {
            button.buttonBorderShape(.capsule)
        }
    }
}
