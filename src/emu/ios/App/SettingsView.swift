import SwiftUI

struct SettingsView: View {
    @AppStorage("ios.showVirtualKeypad") private var showVirtualKeypad = true
    @AppStorage("ios.orientation") private var orientation = "auto"

    @State private var audioMasterVolume = 100.0
    @State private var integerScaling = true
    @State private var nearestNeighborFiltering = true
    @State private var hideSystemApps = true
    @State private var extensiveLogging = false
    @State private var cpuBackend = "dynarmic"
    @State private var deviceDisplayName = "EKA2L1"
    @State private var logFilter = ""

    var body: some View {
        Form {
            Section("Device") {
                TextField("Display name", text: $deviceDisplayName)
                Picker("Orientation", selection: $orientation) {
                    Text("Auto").tag("auto")
                    Text("Portrait").tag("portrait")
                    Text("Landscape").tag("landscape")
                }
            }
            Section("Graphics") {
                Toggle("Integer scaling", isOn: $integerScaling)
                Toggle("Nearest filtering", isOn: $nearestNeighborFiltering)
            }
            Section("Audio") {
                Slider(value: $audioMasterVolume, in: 0...100, step: 1)
                Text("\(Int(audioMasterVolume))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Section("Input") {
                Toggle("Virtual keypad", isOn: $showVirtualKeypad)
                Button("Test vibration") {
                    EKA2L1Bridge.shared.testVibration()
                }
            }
            Section("Runtime") {
                Picker("CPU", selection: $cpuBackend) {
                    Text("Dynarmic").tag("dynarmic")
                    Text("Dyncom").tag("dyncom")
                }
                Toggle("Hide system apps", isOn: $hideSystemApps)
                Toggle("Extensive logging", isOn: $extensiveLogging)
                TextField("Log filter", text: $logFilter, axis: .vertical)
                    .lineLimit(2...4)
                LabeledContent("JIT", value: "Stage 4")
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            Button("Save", action: save)
        }
        .onAppear(perform: load)
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
        if let value = snapshot["extensiveLogging"] as? NSNumber {
            extensiveLogging = value.boolValue
        }
        if let value = snapshot["cpuBackend"] as? String {
            cpuBackend = value
        }
        if let value = snapshot["deviceDisplayName"] as? String {
            deviceDisplayName = value
        }
        if let value = snapshot["logFilter"] as? String {
            logFilter = value
        }
    }

    private func save() {
        let snapshot: [String: Any] = [
            "audioMasterVolume": Int(audioMasterVolume),
            "integerScaling": integerScaling,
            "nearestNeighborFiltering": nearestNeighborFiltering,
            "hideSystemApps": hideSystemApps,
            "extensiveLogging": extensiveLogging,
            "cpuBackend": cpuBackend,
            "deviceDisplayName": deviceDisplayName,
            "logFilter": logFilter
        ]
        _ = EKA2L1Bridge.shared.applyConfigSnapshot(snapshot)
    }
}
