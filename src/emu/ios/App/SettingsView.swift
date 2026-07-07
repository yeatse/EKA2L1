import SwiftUI

struct SettingsView: View {
    @AppStorage("ios.showVirtualKeypad") private var showVirtualKeypad = true
    @AppStorage("ios.enableControllerInput") private var enableControllerInput = true
    @AppStorage(KeypadLayout.storageKey) private var keypadLayoutRaw = KeypadLayout.default.rawValue
    @AppStorage("ios.showFPSOverlay") private var showFPSOverlay = true

    @State private var audioMasterVolume = 100.0
    @State private var integerScaling = true
    @State private var nearestNeighborFiltering = true
    @State private var hideSystemApps = true
    @State private var deviceDisplayName = "EKA2L1"
    @State private var useJIT = false
    @State private var storageBytes: UInt64 = 0
    @State private var clearDataMessage: String?
    @State private var showingClearDataConfirmation = false

    private var logURL: URL {
        URL(fileURLWithPath: settingsDocumentsRoot()).appendingPathComponent("data/EKA2L1.log")
    }

    private var storageText: String {
        ByteCountFormatter.string(fromByteCount: Int64(storageBytes), countStyle: .file)
    }

    var body: some View {
        Form {
            Section("settings.device") {
                TextField("settings.displayName", text: $deviceDisplayName)
            }
            // Only sideload/simulator builds carry the dynarmic JIT; App Store /
            // TestFlight builds compile without it and never show this section.
            if EKA2L1Bridge.shared.jitCompiledIn {
                Section {
                    Toggle("settings.jit", isOn: $useJIT)
                } header: {
                    Text("settings.system")
                } footer: {
                    if !EKA2L1Bridge.shared.jitAvailable {
                        Text("settings.jit.unavailable")
                    } else {
                        Text("settings.jit.hint")
                    }
                }
            }
            Section("settings.graphics") {
                Toggle("settings.integerScaling", isOn: $integerScaling)
                Toggle("settings.nearestFiltering", isOn: $nearestNeighborFiltering)
            }
            Section("settings.audio") {
                Slider(value: $audioMasterVolume, in: 0...100, step: 1)
                Text("\(Int(audioMasterVolume))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Section("settings.input") {
                Toggle("settings.virtualKeypad", isOn: $showVirtualKeypad)
                if showVirtualKeypad {
                    Picker("settings.keypadLayout", selection: $keypadLayoutRaw) {
                        ForEach(KeypadLayout.allCases) { layout in
                            Text(layout.displayName).tag(layout.rawValue)
                        }
                    }
                }
                Toggle("settings.gameController", isOn: $enableControllerInput)
                Toggle("settings.fpsOverlay", isOn: $showFPSOverlay)
                Button("settings.testVibration") {
                    EKA2L1Bridge.shared.testVibration()
                }
            }
            Section("settings.library") {
                Toggle("settings.hideSystemApps", isOn: $hideSystemApps)
            }
            Section("settings.support") {
                LabeledContent("settings.storageUsed", value: storageText)
                if FileManager.default.fileExists(atPath: logURL.path) {
                    ShareLink(item: logURL) {
                        Label("settings.exportLog", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("settings.noLog", systemImage: "doc")
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    showingClearDataConfirmation = true
                } label: {
                    Label("settings.clearData", systemImage: "trash")
                }
                if let clearDataMessage {
                    Text(clearDataMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("settings.title")
        .onAppear {
            load()
            refreshStorageUsage()
        }
        .onChange(of: audioMasterVolume) { _ in save() }
        .onChange(of: useJIT) { _ in save() }
        .onChange(of: integerScaling) { _ in save() }
        .onChange(of: nearestNeighborFiltering) { _ in save() }
        .onChange(of: hideSystemApps) { _ in save() }
        .onChange(of: deviceDisplayName) { _ in save() }
        .confirmationDialog("settings.clearData.title",
                            isPresented: $showingClearDataConfirmation,
                            titleVisibility: .visible) {
            Button("settings.clearData.confirm", role: .destructive, action: clearData)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.clearData.message")
        }
    }

    private func load() {
        let snapshot = EKA2L1Bridge.shared.currentConfigSnapshot()
        if let volume = snapshot["audioMasterVolume"] as? NSNumber {
            audioMasterVolume = Double(truncating: volume)
        }
        if let value = snapshot["integerScaling"] as? NSNumber {
            integerScaling = value.boolValue
        }
        if let value = snapshot["nearestNeighborFiltering"] as? NSNumber {
            nearestNeighborFiltering = value.boolValue
        }
        if let value = snapshot["hideSystemApps"] as? NSNumber {
            hideSystemApps = value.boolValue
        }
        if let value = snapshot["deviceDisplayName"] as? String {
            deviceDisplayName = value
        }
        if let value = snapshot["jitEnabled"] as? NSNumber {
            useJIT = value.boolValue
        }
    }

    private func save() {
        let snapshot: [String: Any] = [
            "audioMasterVolume": Int(audioMasterVolume),
            "integerScaling": integerScaling,
            "nearestNeighborFiltering": nearestNeighborFiltering,
            "hideSystemApps": hideSystemApps,
            "jitEnabled": useJIT && EKA2L1Bridge.shared.jitCompiledIn,
            "deviceDisplayName": deviceDisplayName
        ]
        _ = EKA2L1Bridge.shared.applyConfigSnapshot(snapshot)
    }

    private func refreshStorageUsage() {
        DispatchQueue.global(qos: .utility).async {
            let bytes = directorySize(at: URL(fileURLWithPath: settingsDocumentsRoot()))
            DispatchQueue.main.async {
                storageBytes = bytes
            }
        }
    }

    private func clearData() {
        EKA2L1Bridge.shared.pause()
        EKA2L1Bridge.shared.closeRunningApp()
        let root = URL(fileURLWithPath: settingsDocumentsRoot())
        let fm = FileManager.default
        for name in ["data", "sis", "roms", "import_tmp"] {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        clearDataMessage = String(localized: "settings.clearData.done")
        refreshStorageUsage()
    }
}

private func settingsDocumentsRoot() -> String {
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
}

private func directorySize(at url: URL) -> UInt64 {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    ) else {
        return 0
    }

    var total: UInt64 = 0
    for case let fileURL as URL in enumerator {
        guard let values = try? fileURL.resourceValues(forKeys: keys),
              values.isRegularFile == true else {
            continue
        }
        total += UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
    return total
}
