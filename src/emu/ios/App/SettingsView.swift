import SwiftUI

struct SettingsView: View {
    @AppStorage("ios.showVirtualKeypad") private var showVirtualKeypad = true
    @AppStorage(KeypadLayout.storageKey) private var keypadLayoutRaw = KeypadLayout.default.rawValue
    @ObservedObject private var peripheralManager = PeripheralManager.shared
    @State private var mappingTarget: PeripheralManager.Peripheral?
    @AppStorage("ios.showFPSOverlay") private var showFPSOverlay = true

    @State private var audioMasterVolume = 100.0
    @State private var integerScaling = true
    @State private var nearestNeighborFiltering = true
    @State private var hideSystemApps = true
    @State private var deviceDisplayName = "EKA2L1"
    @State private var useJIT = false
    @State private var availableLanguages: [EKA2L1LanguageItem] = []
    @State private var systemLanguageCode = -1
    @State private var storageBytes: UInt64 = 0
    @State private var clearDataMessage: String?
    @State private var showingClearDataConfirmation = false

    private var logURL: URL {
        URL(fileURLWithPath: documentsRoot()).appendingPathComponent("data/EKA2L1.log")
    }

    private var storageText: String {
        ByteCountFormatter.string(fromByteCount: Int64(storageBytes), countStyle: .file)
    }

    var body: some View {
        Form {
            Section("settings.device") {
                TextField("settings.displayName", text: $deviceDisplayName)
                if !availableLanguages.isEmpty {
                    Picker("settings.systemLanguage", selection: $systemLanguageCode) {
                        ForEach(availableLanguages) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                }
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
                Toggle("settings.fpsOverlay", isOn: $showFPSOverlay)
                Button("settings.testVibration") {
                    EKA2L1Bridge.shared.testVibration()
                }
            }
            Section("settings.peripherals") {
                if peripheralManager.peripherals.isEmpty {
                    Text("controllerMapping.noController")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(peripheralManager.peripherals) { peripheral in
                        peripheralRow(peripheral)
                    }
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
        .navigationDestination(isPresented: Binding(
            get: { mappingTarget != nil },
            set: { if !$0 { mappingTarget = nil } }
        )) {
            if let mappingTarget {
                KeyMappingView(peripheral: mappingTarget)
            }
        }
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
        .onChange(of: systemLanguageCode) { newCode in
            // -1 = load() hasn't found a booted device yet; don't write it back.
            if newCode >= 0, newCode != EKA2L1Bridge.shared.currentLanguageCode() {
                EKA2L1Bridge.shared.setSystemLanguage(code: newCode)
            }
        }
        .confirmationDialog("settings.clearData.title",
                            isPresented: $showingClearDataConfirmation,
                            titleVisibility: .visible) {
            Button("settings.clearData.confirm", role: .destructive, action: clearData)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.clearData.message")
        }
    }

    // Connected-peripheral row: tapping the name area makes the device the
    // active input source, the info button opens its key mapping editor.
    // Borderless styles keep the two buttons independently tappable in the
    // same Form row.
    private func peripheralRow(_ peripheral: PeripheralManager.Peripheral) -> some View {
        let isActive = peripheral.id == peripheralManager.activeID
        return HStack {
            Button {
                peripheralManager.setActive(peripheral.id)
            } label: {
                HStack {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    Text(peripheral.name)
                        .foregroundStyle(Color.primary)
                }
            }
            .buttonStyle(.borderless)
            Spacer()
            Button {
                mappingTarget = peripheral
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
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
        availableLanguages = EKA2L1Bridge.shared.availableLanguages()
        systemLanguageCode = EKA2L1Bridge.shared.currentLanguageCode()
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
            let bytes = directorySize(at: URL(fileURLWithPath: documentsRoot()))
            DispatchQueue.main.async {
                storageBytes = bytes
            }
        }
    }

    private func clearData() {
        EKA2L1Bridge.shared.pause()
        EKA2L1Bridge.shared.closeRunningApp()
        let root = URL(fileURLWithPath: documentsRoot())
        let fm = FileManager.default
        for name in ["data", "sis", "roms", "import_tmp"] {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        clearDataMessage = String(localized: "settings.clearData.done")
        refreshStorageUsage()
    }
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
