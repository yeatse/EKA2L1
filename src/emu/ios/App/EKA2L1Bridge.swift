import Foundation
import QuartzCore

// Sandbox Documents directory hosting the emulator's file tree (roms/, data/,
// sis/, ...). Shared by every view that stages files or reads emulator output.
func documentsRoot() -> String {
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
}

struct EKA2L1AppItem: Identifiable, Hashable {
    let uid: UInt32
    let name: String
    // True for built-in ROM/system apps; false for user-installed packages.
    let system: Bool

    var id: UInt32 { uid }
}

struct EKA2L1DeviceItem: Identifiable, Hashable {
    let index: Int
    let firmwareCode: String
    let manufacturer: String
    let model: String

    var id: Int { index }

    // Title shown on the app list / device switcher. Prefer the model
    // (e.g. "Nokia N97") and fall back to the firmware code.
    var displayName: String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? firmwareCode : trimmed
    }
}

struct EKA2L1NGageInstallItem {
    let result: Int
    let gameName: String

    var succeeded: Bool { result == 0 }
}

// A guest system language shipped by the current device's ROM.
struct EKA2L1LanguageItem: Identifiable, Hashable {
    let code: Int
    let name: String

    var id: Int { code }
}

struct CpuSmokeReport {
    enum Backend {
        case dyncom
        case dynarmic
    }

    let requestedBackend: Backend
    let resolvedBackend: Backend
    let fallbackReason: String?
    let pass: Bool
    let instructionsExecuted: UInt32
    let registers: [UInt32]
    let pc: UInt32
    let sp: UInt32
    let lr: UInt32
    let cpsr: UInt32
    let diff: String?
}

@MainActor
final class EKA2L1Bridge {
    static let shared = EKA2L1Bridge()

    private let emulator = EKA2L1Emulator.shared()

    private init() {}

    func start(documentsPath: String) -> Bool {
        emulator.start(withDocumentsPath: documentsPath)
    }

    func installedDevices() -> [EKA2L1DeviceItem] {
        emulator.installedDevices().map {
            EKA2L1DeviceItem(index: Int($0.index), firmwareCode: $0.firmwareCode,
                             manufacturer: $0.manufacturer, model: $0.model)
        }
    }

    func currentDeviceIndex() -> Int {
        emulator.currentDeviceIndex()
    }

    func availableLanguages() -> [EKA2L1LanguageItem] {
        emulator.availableLanguages().map {
            EKA2L1LanguageItem(code: Int($0.code), name: $0.name)
        }
    }

    func currentLanguageCode() -> Int {
        emulator.currentLanguageCode()
    }

    func setSystemLanguage(code: Int) {
        emulator.setSystemLanguageCode(code)
    }

    // Heavy operations (ROM dump / system rebuild) — exposed as nonisolated so
    // the frontend can run them off the main queue while a spinner shows. The
    // Obj-C side serialises against the emulator loop internally.
    nonisolated static func installDevice(romPath: String, rpkgPath: String?) -> EKA2L1InstallResult {
        EKA2L1Emulator.shared().installDevice(romPath: romPath, rpkgPath: rpkgPath)
    }

    nonisolated static func bootDevice(at index: Int) -> Bool {
        EKA2L1Emulator.shared().bootDevice(at: UInt(index))
    }

    nonisolated static func unzipArchive(atPath path: String, toDirectory destination: String) throws {
        try EKA2L1Emulator.unzipArchive(atPath: path, toDirectory: destination)
    }

    func rescanApps() -> [EKA2L1AppItem] {
        emulator.rescanApps().map {
            EKA2L1AppItem(uid: $0.uid, name: $0.name, system: $0.system)
        }
    }

    // Launch runs off the main thread inside the bridge (it drives synchronous
    // graphics commands that would deadlock a main-thread caller against the
    // graphics worker's main-queue CAEAGLLayer attach). The completion, when
    // provided, is delivered back on the main queue with the launch result.
    func launchApp(uid: UInt32, completion: ((Bool) -> Void)? = nil) {
        emulator.launchApp(withUID: uid, completion: completion)
    }

    // Set/clear the callback fired (on the main queue) when the running app's
    // process exits — used to close the emulator screen when the guest app
    // leaves via Exit soft key, panic, or normal termination.
    func setAppExitHandler(_ handler: ((String?) -> Void)?) {
        emulator.appExitHandler = handler
    }

    // Kill the running app in lockstep with the frontend closing its screen.
    func closeRunningApp() {
        emulator.closeRunningApp()
    }

    func installSis(atPath path: String) -> Bool {
        emulator.installSis(atPath: path)
    }

    nonisolated static func installNGageGame(folderPath: String) -> EKA2L1NGageInstallItem {
        let report = EKA2L1Emulator.shared().installNGageGame(atFolderPath: folderPath)
        return EKA2L1NGageInstallItem(result: report.result, gameName: report.gameName)
    }

    func uninstallApp(uid: UInt32) -> Bool {
        emulator.uninstallApp(withUID: uid)
    }

    func attach(layer: CAEAGLLayer, pixelSize: CGSize, scale: CGFloat) {
        emulator.attach(layer: layer, pixelSize: pixelSize, scale: scale)
    }

    func detachLayer() {
        emulator.detachLayer()
    }

    func pause() {
        emulator.pause()
    }

    func resume() {
        emulator.resume()
    }

    func advanceGuestScreenMode(appUID: UInt32, completion: @escaping @Sendable (Int) -> Void) {
        emulator.advanceGuestScreenMode(forAppUID: appUID, completion: completion)
    }

    func submitPointer(x: CGFloat, y: CGFloat, phase: EKA2L1PointerPhase, pointerId: UInt) {
        emulator.submitPointer(x: x, y: y, phase: phase, pointerId: pointerId)
    }

    // True when the booted ROM drives its UI by touch (S60v5 / Symbian^3+);
    // those default to the fullscreen keypad layout.
    func currentDeviceIsTouchScreen() -> Bool {
        emulator.currentDeviceIsTouchScreen()
    }

    // Anchor the presented guest picture's top edge at `pixels` from the top of
    // the render surface (negative = centred). Used to keep the picture clear
    // of a bottom keypad overlay.
    func setDisplayAnchorTop(pixels: Int) {
        emulator.setDisplayAnchorTopPixels(pixels)
    }

    // Report the emulator screen's interface orientation so accelerometer
    // samples can follow the displayed guest (see IosEmulator.h).
    func setHostInterfaceRotation(degrees: Int) {
        emulator.setHostInterfaceRotationDegrees(degrees)
    }

    func submitRawKey(_ scanCode: UInt32, pressed: Bool) {
        emulator.submitRawKey(scanCode, pressed: pressed)
    }

    nonisolated static func submitRawKey(_ scanCode: UInt32, pressed: Bool) {
        EKA2L1Emulator.shared().submitRawKey(scanCode, pressed: pressed)
    }

    func tapRawKey(_ scanCode: UInt32) {
        emulator.tapRawKey(scanCode)
    }

    func currentConfigSnapshot() -> [String: Any] {
        emulator.currentConfigSnapshot()
    }

    func applyConfigSnapshot(_ snapshot: [String: Any]) -> Bool {
        emulator.applyConfigSnapshot(snapshot)
    }

    // YES when this build carries the dynarmic JIT (sideload/simulator builds
    // only; App Store / TestFlight builds compile without it).
    var jitCompiledIn: Bool {
        emulator.jitCompiledIn
    }

    // YES when the running process additionally has JIT permission (debugger /
    // JIT enabler). Without it the emulator falls back to the interpreter.
    var jitAvailable: Bool {
        emulator.jitAvailable
    }

    func testVibration() {
        emulator.testVibration()
    }

    func renderedFrameCount() -> UInt64 {
        emulator.renderedFrameCount()
    }

    nonisolated static func iconPNGData(uid: UInt32, sizePx: UInt) -> Data? {
        EKA2L1Emulator.shared().iconPNGData(forUID: uid, sizePx: sizePx)
    }

    nonisolated static func runSmoke(backend: CpuSmokeReport.Backend) -> CpuSmokeReport {
        let rawBackend: EKA2L1SmokeBackend = backend == .dyncom ? .dyncom : .dynarmic
        let raw = EKA2L1CpuSmokeBridge.run(with: rawBackend)
        return CpuSmokeReport(
            requestedBackend: mapSmokeBackend(raw.requestedBackend),
            resolvedBackend: mapSmokeBackend(raw.resolvedBackend),
            fallbackReason: raw.fallbackReason,
            pass: raw.pass,
            instructionsExecuted: raw.instructionsExecuted,
            registers: raw.registers.map { $0.uint32Value },
            pc: raw.pc,
            sp: raw.sp,
            lr: raw.lr,
            cpsr: raw.cpsr,
            diff: raw.diff
        )
    }

    private nonisolated static func mapSmokeBackend(_ backend: EKA2L1SmokeBackend) -> CpuSmokeReport.Backend {
        backend == .dynarmic ? .dynarmic : .dyncom
    }
}
