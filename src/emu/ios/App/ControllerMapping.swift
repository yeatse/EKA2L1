import GameController
import SwiftUI
import UIKit

// User-editable binding from host inputs (game-controller buttons and
// hardware-keyboard keys) to guest (Symbian) keys, edited from the guest
// side: the settings page lists every Nokia key and the user presses a
// physical controller button or keyboard key to bind it.
//
// The canonical model is [host token: guest scan]. That direction makes the
// conflict rule automatic — a host input can only drive one guest key, and
// re-capturing it simply overwrites the old entry (last edit wins). Binding
// also removes any other host input *of the same class* pointing at the same
// guest key, so each guest key keeps at most one controller binding and one
// keyboard binding. An absent host token means the input is unbound. Stored
// in UserDefaults; the emulator screen reloads the mapping on every appear.
//
// Host tokens: controller buttons use HostButton raw values; keyboard keys
// use "kb.<HID usage>". HID usage is the shared currency between capture
// (GameController's GCKeyCode) and runtime input (UIKit's UIKeyboardHIDUsage).

// Every bindable controller button on an extended gamepad. The left
// thumbstick is deliberately not listed: it aliases the d-pad tokens at both
// capture and input time, so a stick flick and a d-pad press are the same
// binding.
enum HostButton: String, CaseIterable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case buttonMenu, buttonOptions
    case leftThumbstickButton, rightThumbstickButton
    case dpadUp = "dpad.up"
    case dpadDown = "dpad.down"
    case dpadLeft = "dpad.left"
    case dpadRight = "dpad.right"

    var genericName: String {
        switch self {
        case .buttonA: return "A"
        case .buttonB: return "B"
        case .buttonX: return "X"
        case .buttonY: return "Y"
        case .leftShoulder: return "L1"
        case .rightShoulder: return "R1"
        case .leftTrigger: return "L2"
        case .rightTrigger: return "R2"
        case .buttonMenu: return "Menu"
        case .buttonOptions: return "Options"
        case .leftThumbstickButton: return "L3"
        case .rightThumbstickButton: return "R3"
        case .dpadUp: return "D-pad Up"
        case .dpadDown: return "D-pad Down"
        case .dpadLeft: return "D-pad Left"
        case .dpadRight: return "D-pad Right"
        }
    }

    // Controller-specific name when a gamepad is connected (e.g. "Cross
    // Button" on DualSense, "A Button" on Xbox), generic name otherwise.
    func displayName(on gamepad: GCExtendedGamepad?) -> String {
        guard let gamepad, let name = buttonInput(on: gamepad)?.localizedName,
              !name.isEmpty else {
            return genericName
        }
        return name
    }

    func buttonInput(on gamepad: GCExtendedGamepad) -> GCControllerButtonInput? {
        switch self {
        case .buttonA: return gamepad.buttonA
        case .buttonB: return gamepad.buttonB
        case .buttonX: return gamepad.buttonX
        case .buttonY: return gamepad.buttonY
        case .leftShoulder: return gamepad.leftShoulder
        case .rightShoulder: return gamepad.rightShoulder
        case .leftTrigger: return gamepad.leftTrigger
        case .rightTrigger: return gamepad.rightTrigger
        case .buttonMenu: return gamepad.buttonMenu
        case .buttonOptions: return gamepad.buttonOptions
        case .leftThumbstickButton: return gamepad.leftThumbstickButton
        case .rightThumbstickButton: return gamepad.rightThumbstickButton
        case .dpadUp: return gamepad.dpad.up
        case .dpadDown: return gamepad.dpad.down
        case .dpadLeft: return gamepad.dpad.left
        case .dpadRight: return gamepad.dpad.right
        }
    }

    func isPressed(on gamepad: GCExtendedGamepad, threshold: Float) -> Bool {
        switch self {
        // Triggers are analog; use the shared threshold instead of the
        // system's notion of "pressed".
        case .leftTrigger: return gamepad.leftTrigger.value > threshold
        case .rightTrigger: return gamepad.rightTrigger.value > threshold
        default: return buttonInput(on: gamepad)?.isPressed ?? false
        }
    }
}

// Hardware-keyboard host inputs, addressed by HID usage.
enum KeyboardKey {
    private static let tokenPrefix = "kb."

    static func token(forUsage usage: Int) -> String {
        "\(tokenPrefix)\(usage)"
    }

    static func usage(fromToken token: String) -> Int? {
        guard token.hasPrefix(tokenPrefix),
              let usage = Int(token.dropFirst(tokenPrefix.count)),
              (0x04...0xE7).contains(usage) else {
            return nil
        }
        return usage
    }

    static func isKeyboardToken(_ token: String) -> Bool {
        usage(fromToken: token) != nil
    }

    static func displayName(forUsage usage: Int) -> String {
        switch usage {
        case 0x04...0x1D:
            return String(UnicodeScalar(UInt8(65 + usage - 0x04)))       // A-Z
        case 0x1E...0x26:
            return String(UnicodeScalar(UInt8(49 + usage - 0x1E)))       // 1-9
        case 0x27: return "0"
        case 0x28: return "Return"
        case 0x29: return "Esc"
        case 0x2A: return "Delete"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x3A...0x45:
            return "F\(usage - 0x39)"                                    // F1-F12
        case 0x4F: return "\u{2192}"
        case 0x50: return "\u{2190}"
        case 0x51: return "\u{2193}"
        case 0x52: return "\u{2191}"
        case 0x54: return "Keypad /"
        case 0x55: return "Keypad *"
        case 0x56: return "Keypad -"
        case 0x57: return "Keypad +"
        case 0x58: return "Keypad Enter"
        case 0x59...0x61:
            return "Keypad \(usage - 0x58)"                              // keypad 1-9
        case 0x62: return "Keypad 0"
        case 0xE0, 0xE4: return "Ctrl"
        case 0xE1, 0xE5: return "Shift"
        case 0xE2, 0xE6: return "Alt"
        case 0xE3, 0xE7: return "Cmd"
        default:
            return String(format: "Key 0x%02X", usage)
        }
    }
}

// One guest (Nokia) key that can receive bindings. Digit keys carry no
// symbol — their name is the glyph already.
struct GuestKey: Identifiable {
    let scan: UInt32
    let name: String
    var symbol: String?
    var symbolColor: Color?

    var id: UInt32 { scan }
}

enum GuestKeys {
    static let directions: [GuestKey] = [
        GuestKey(scan: Scan.up, name: String(localized: "key.up"), symbol: "arrow.up.circle"),
        GuestKey(scan: Scan.down, name: String(localized: "key.down"), symbol: "arrow.down.circle"),
        GuestKey(scan: Scan.left, name: String(localized: "key.left"), symbol: "arrow.left.circle"),
        GuestKey(scan: Scan.right, name: String(localized: "key.right"), symbol: "arrow.right.circle"),
    ]

    static let actions: [GuestKey] = [
        GuestKey(scan: Scan.select, name: String(localized: "key.select"),
                 symbol: "checkmark.circle"),
        GuestKey(scan: Scan.leftSoft, name: String(localized: "key.leftSoft"),
                 symbol: "l.circle"),
        GuestKey(scan: Scan.rightSoft, name: String(localized: "key.rightSoft"),
                 symbol: "r.circle"),
        GuestKey(scan: Scan.call, name: String(localized: "key.call"),
                 symbol: "phone.circle", symbolColor: .green),
        GuestKey(scan: Scan.end, name: String(localized: "key.end"),
                 symbol: "phone.down.circle", symbolColor: .red),
        GuestKey(scan: Scan.clear, name: String(localized: "key.clear"),
                 symbol: "delete.left"),
    ]

    static let digits: [GuestKey] = [
        GuestKey(scan: 0x31, name: "1"), GuestKey(scan: 0x32, name: "2"),
        GuestKey(scan: 0x33, name: "3"), GuestKey(scan: 0x34, name: "4"),
        GuestKey(scan: 0x35, name: "5"), GuestKey(scan: 0x36, name: "6"),
        GuestKey(scan: 0x37, name: "7"), GuestKey(scan: 0x38, name: "8"),
        GuestKey(scan: 0x39, name: "9"), GuestKey(scan: 0x30, name: "0"),
        GuestKey(scan: Scan.star, name: "\u{2217}"),
        GuestKey(scan: Scan.hash, name: "#"),
    ]

    static let all: [GuestKey] = directions + actions + digits
}

enum ControllerMappingStore {
    static let storageKey = "ios.controllerMapping"

    static let defaults: [String: UInt32] = [
        // Controller
        HostButton.dpadUp.rawValue: Scan.up,
        HostButton.dpadDown.rawValue: Scan.down,
        HostButton.dpadLeft.rawValue: Scan.left,
        HostButton.dpadRight.rawValue: Scan.right,
        HostButton.buttonA.rawValue: Scan.select,
        HostButton.buttonB.rawValue: Scan.clear,
        HostButton.buttonX.rawValue: 0x35,   // digit 5, common game action key
        HostButton.buttonY.rawValue: 0x37,   // digit 7, common secondary game key
        HostButton.leftShoulder.rawValue: Scan.leftSoft,
        HostButton.rightShoulder.rawValue: Scan.rightSoft,
        HostButton.leftTrigger.rawValue: Scan.star,
        HostButton.rightTrigger.rawValue: Scan.hash,
        HostButton.buttonOptions.rawValue: Scan.call,
        HostButton.buttonMenu.rawValue: Scan.end,
        // Keyboard (HID usages), mirroring the historical hardcoded layout.
        KeyboardKey.token(forUsage: 0x52): Scan.up,
        KeyboardKey.token(forUsage: 0x51): Scan.down,
        KeyboardKey.token(forUsage: 0x50): Scan.left,
        KeyboardKey.token(forUsage: 0x4F): Scan.right,
        KeyboardKey.token(forUsage: 0x28): Scan.select,     // Return
        KeyboardKey.token(forUsage: 0x3A): Scan.leftSoft,   // F1
        KeyboardKey.token(forUsage: 0x3B): Scan.rightSoft,  // F2
        KeyboardKey.token(forUsage: 0x3C): Scan.call,       // F3
        KeyboardKey.token(forUsage: 0x3D): Scan.end,        // F4
        KeyboardKey.token(forUsage: 0x2A): Scan.clear,      // Delete/Backspace
        KeyboardKey.token(forUsage: 0x1E): 0x31, KeyboardKey.token(forUsage: 0x1F): 0x32,
        KeyboardKey.token(forUsage: 0x20): 0x33, KeyboardKey.token(forUsage: 0x21): 0x34,
        KeyboardKey.token(forUsage: 0x22): 0x35, KeyboardKey.token(forUsage: 0x23): 0x36,
        KeyboardKey.token(forUsage: 0x24): 0x37, KeyboardKey.token(forUsage: 0x25): 0x38,
        KeyboardKey.token(forUsage: 0x26): 0x39, KeyboardKey.token(forUsage: 0x27): 0x30,
    ]

    static func load() -> [String: UInt32] {
        guard let stored = UserDefaults.standard.dictionary(forKey: storageKey) else {
            return defaults
        }
        var mapping: [String: UInt32] = [:]
        for (token, value) in stored {
            guard let number = value as? NSNumber else { continue }
            let scan = UInt32(truncating: number)
            guard HostButton(rawValue: token) != nil || KeyboardKey.isKeyboardToken(token),
                  GuestKeys.all.contains(where: { $0.scan == scan }) else {
                continue
            }
            mapping[token] = scan
        }
        return mapping
    }

    static func save(_ mapping: [String: UInt32]) {
        UserDefaults.standard.set(mapping.mapValues { Int($0) }, forKey: storageKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // Host→scan for hardware-keyboard runtime lookups, keyed by HID usage.
    static func keyboardScanMapping() -> [Int: UInt32] {
        var result: [Int: UInt32] = [:]
        for (token, scan) in load() {
            if let usage = KeyboardKey.usage(fromToken: token) {
                result[usage] = scan
            }
        }
        return result
    }

    // Keeps the relation one-to-one per input class: the captured host input
    // is stolen from whatever guest key held it (last edit wins), and any
    // other host input of the same class bound to this guest key is dropped.
    static func bind(hostToken: String, toScan scan: UInt32, in mapping: inout [String: UInt32]) {
        let bindingKeyboard = KeyboardKey.isKeyboardToken(hostToken)
        for (token, value) in mapping
        where value == scan && KeyboardKey.isKeyboardToken(token) == bindingKeyboard {
            mapping.removeValue(forKey: token)
        }
        mapping[hostToken] = scan
    }

    static func unbind(scan: UInt32, in mapping: inout [String: UInt32]) {
        for (token, value) in mapping where value == scan {
            mapping.removeValue(forKey: token)
        }
    }

    // Host tokens bound to this guest key, controller first, then keyboard.
    static func hostTokens(boundToScan scan: UInt32, in mapping: [String: UInt32]) -> [String] {
        let controller = HostButton.allCases
            .filter { mapping[$0.rawValue] == scan }
            .map(\.rawValue)
        let keyboard = mapping
            .filter { $0.value == scan && KeyboardKey.isKeyboardToken($0.key) }
            .keys.sorted()
        return controller + keyboard
    }
}

// Watches the connected controller and hardware keyboard while the mapping
// editor is open. During a capture it reports the first host input that
// transitions to pressed after the capture started (controller buttons
// already held when it starts are ignored). The emulator screen is never
// visible at the same time as Settings, so this never races the emulator's
// input paths.
@MainActor
final class ControllerCaptureMonitor: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published private(set) var keyboardName: String?
    @Published private(set) var capturedToken: String?

    private var observers: [NSObjectProtocol] = []
    private var capturing = false
    private var pressedTokens: Set<String> = []
    private let threshold: Float = 0.45

    func start() {
        let center = NotificationCenter.default
        for name: Notification.Name in [.GCControllerDidConnect, .GCControllerDidDisconnect,
                                        .GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil,
                                                queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        GCController.startWirelessControllerDiscovery()
        refresh()
    }

    func stop() {
        GCController.stopWirelessControllerDiscovery()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.controllers().forEach { $0.extendedGamepad?.valueChangedHandler = nil }
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        capturing = false
        capturedToken = nil
    }

    func beginCapture() {
        capturedToken = nil
        capturing = true
    }

    func cancelCapture() {
        capturing = false
        capturedToken = nil
    }

    private func refresh() {
        // Only the first extended gamepad feeds capture; mixing pressed-state
        // sets from several controllers would corrupt the transition baseline.
        let controller = GCController.controllers().first { $0.extendedGamepad != nil }
        controllerName = controller?.vendorName
        let threshold = self.threshold
        if let gamepad = controller?.extendedGamepad {
            gamepad.valueChangedHandler = { [weak self] pad, _ in
                let pressed = Self.pressedTokens(on: pad, threshold: threshold)
                Task { @MainActor in self?.update(pressed: pressed) }
            }
        }

        keyboardName = GCKeyboard.coalesced == nil
            ? nil : (GCKeyboard.coalesced?.vendorName ?? "Keyboard")
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard pressed else { return }
            let token = KeyboardKey.token(forUsage: Int(keyCode.rawValue))
            Task { @MainActor in self?.capture(token: token) }
        }
    }

    private func update(pressed: Set<String>) {
        let newlyPressed = pressed.subtracting(pressedTokens)
        pressedTokens = pressed
        if let token = newlyPressed.first {
            capture(token: token)
        }
    }

    private func capture(token: String) {
        guard capturing else { return }
        capturing = false
        capturedToken = token
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private nonisolated static func pressedTokens(on gamepad: GCExtendedGamepad,
                                                  threshold: Float) -> Set<String> {
        var tokens = Set(
            HostButton.allCases
                .filter { $0.isPressed(on: gamepad, threshold: threshold) }
                .map(\.rawValue)
        )
        // The left thumbstick captures as the d-pad, mirroring runtime input.
        if gamepad.leftThumbstick.yAxis.value > threshold { tokens.insert(HostButton.dpadUp.rawValue) }
        if gamepad.leftThumbstick.yAxis.value < -threshold { tokens.insert(HostButton.dpadDown.rawValue) }
        if gamepad.leftThumbstick.xAxis.value < -threshold { tokens.insert(HostButton.dpadLeft.rawValue) }
        if gamepad.leftThumbstick.xAxis.value > threshold { tokens.insert(HostButton.dpadRight.rawValue) }
        return tokens
    }
}

struct ControllerMappingView: View {
    @State private var mapping = ControllerMappingStore.load()
    @StateObject private var monitor = ControllerCaptureMonitor()
    @State private var captureTarget: GuestKey?

    var body: some View {
        Form {
            Section {
                ForEach(GuestKeys.directions, content: row)
            } header: {
                Text("controllerMapping.directions")
            } footer: {
                Text("controllerMapping.directions.hint")
            }
            Section("controllerMapping.actions") {
                ForEach(GuestKeys.actions, content: row)
            }
            Section("controllerMapping.numbers") {
                ForEach(GuestKeys.digits, content: row)
            }
            Section {
                Button("controllerMapping.reset", role: .destructive) {
                    ControllerMappingStore.reset()
                    mapping = ControllerMappingStore.defaults
                }
            } footer: {
                Text(connectionSummary)
            }
        }
        .navigationTitle("settings.controllerMapping")
        .onAppear(perform: monitor.start)
        .onDisappear(perform: monitor.stop)
        .sheet(item: $captureTarget, onDismiss: monitor.cancelCapture) { key in
            CaptureSheet(
                key: key,
                currentBinding: bindingText(for: key),
                monitor: monitor,
                onClear: {
                    ControllerMappingStore.unbind(scan: key.scan, in: &mapping)
                    ControllerMappingStore.save(mapping)
                    captureTarget = nil
                },
                onCancel: { captureTarget = nil }
            )
        }
        .onChange(of: monitor.capturedToken) { token in
            guard let token, let target = captureTarget else { return }
            ControllerMappingStore.bind(hostToken: token, toScan: target.scan, in: &mapping)
            ControllerMappingStore.save(mapping)
            captureTarget = nil
        }
    }

    private var connectedGamepad: GCExtendedGamepad? {
        GCController.controllers().first { $0.extendedGamepad != nil }?.extendedGamepad
    }

    private var connectionSummary: String {
        var lines: [String] = []
        if let name = monitor.controllerName {
            lines.append(String(format: String(localized: "controllerMapping.connected %@"), name))
        }
        if let name = monitor.keyboardName {
            lines.append(String(format: String(localized: "controllerMapping.keyboardConnected %@"), name))
        }
        if lines.isEmpty {
            lines.append(String(localized: "controllerMapping.noController"))
        }
        return lines.joined(separator: "\n")
    }

    private func row(_ key: GuestKey) -> some View {
        Button {
            monitor.beginCapture()
            captureTarget = key
        } label: {
            Label {
                HStack {
                    // Explicit Color.primary/.secondary: the relative styles
                    // would resolve against the button's accent tint here,
                    // not label color.
                    Text(key.name)
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Text(bindingText(for: key) ?? String(localized: "key.none"))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } icon: {
                if let symbol = key.symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(key.symbolColor ?? Color.accentColor)
                }
            }
        }
    }

    // Controller and keyboard bindings for this guest key, joined for display.
    private func bindingText(for key: GuestKey) -> String? {
        let tokens = ControllerMappingStore.hostTokens(boundToScan: key.scan, in: mapping)
        guard !tokens.isEmpty else { return nil }
        let gamepad = connectedGamepad
        return tokens.map { hostDisplayName(token: $0, gamepad: gamepad) }
            .joined(separator: " \u{00B7} ")
    }

    private func hostDisplayName(token: String, gamepad: GCExtendedGamepad?) -> String {
        if let button = HostButton(rawValue: token) {
            return button.displayName(on: gamepad)
        }
        if let usage = KeyboardKey.usage(fromToken: token) {
            return KeyboardKey.displayName(forUsage: usage)
        }
        return token
    }
}

private struct CaptureSheet: View {
    let key: GuestKey
    let currentBinding: String?
    @ObservedObject var monitor: ControllerCaptureMonitor
    let onClear: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Label {
                Text(key.name)
            } icon: {
                if let symbol = key.symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(key.symbolColor ?? Color.accentColor)
                }
            }
            .font(.title3.weight(.semibold))
            Image(systemName: "gamecontroller")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .symbolEffectIfAvailable()
            Text("controllerMapping.pressButton")
                .font(.body)
                .multilineTextAlignment(.center)
            if monitor.controllerName == nil && monitor.keyboardName == nil {
                Text("controllerMapping.noController")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let currentBinding {
                Text("controllerMapping.currentBinding \(currentBinding)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                if currentBinding != nil {
                    Button("controllerMapping.clearBinding", role: .destructive, action: onClear)
                }
                Button("common.cancel", action: onCancel)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

private extension View {
    // Pulse the controller glyph while waiting for a press on OSes that have
    // the effect; a static glyph is fine below iOS 17.
    @ViewBuilder
    func symbolEffectIfAvailable() -> some View {
        if #available(iOS 17, *) {
            symbolEffect(.pulse)
        } else {
            self
        }
    }
}
