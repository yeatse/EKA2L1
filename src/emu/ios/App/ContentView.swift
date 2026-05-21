import SwiftUI

// Stage-2 navigation shell:
//   1. Rom list   — picks a folder under <Documents>/roms.
//   2. App list   — applist_server scan + "Install SIS" affordance.
//   3. Emulator   — full-screen UIKit/EAGL view (EmulatorView.swift).
// The CPU smoke surface from stage 1 moves into Diagnostics so it stays
// reachable but does not block the main flow.

struct ContentView: View {
    @State private var booted = false
    @State private var roms: [String] = []
    @State private var apps: [EKA2L1AppEntry] = []
    @State private var sisFiles: [String] = []
    @State private var bootError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if let bootError {
                    Text(bootError).foregroundColor(.red).padding()
                }
                List {
                    Section("Documents/roms") {
                        if roms.isEmpty {
                            Text("Drop a ROM folder into Documents/roms (Files app or scripts/seed_ios_simulator_documents.sh)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        ForEach(roms, id: \.self) { name in
                            NavigationLink(name) {
                                AppListView(romName: name, apps: $apps, sisFiles: $sisFiles)
                            }
                        }
                    }
                    Section("Diagnostics") {
                        NavigationLink("CPU smoke (stage 1)") { DiagnosticsView() }
                    }
                }
            }
            .navigationTitle("EKA2L1")
            .toolbar {
                Button("Rescan", action: refresh)
            }
        }
        .onAppear(perform: bootIfNeeded)
    }

    private func bootIfNeeded() {
        guard !booted else { return }
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
        if EKA2L1Emulator.shared().start(withDocumentsPath: docs) {
            booted = true
            refresh()
        } else {
            bootError = "Emulator failed to initialise. Check Console for details."
        }
    }

    private func refresh() {
        roms = EKA2L1Emulator.shared().availableRoms()
        let fm = FileManager.default
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
        let sisDir = (docs as NSString).appendingPathComponent("sis")
        sisFiles = ((try? fm.contentsOfDirectory(atPath: sisDir)) ?? []).filter {
            $0.lowercased().hasSuffix(".sis") || $0.lowercased().hasSuffix(".sisx")
        }
    }
}

struct AppListView: View {
    let romName: String
    @Binding var apps: [EKA2L1AppEntry]
    @Binding var sisFiles: [String]

    @State private var mountedRom: String?
    @State private var mountError: String?

    var body: some View {
        List {
            Section("ROM") {
                if mountedRom != romName {
                    Button("Mount \(romName)") { mount() }
                } else {
                    Text("Mounted: \(romName)").font(.caption).foregroundColor(.secondary)
                }
                if let e = mountError {
                    Text(e).foregroundColor(.red).font(.caption)
                }
            }
            Section("Apps (\(apps.count))") {
                ForEach(apps, id: \.uid) { app in
                    NavigationLink(destination: EmulatorView(uid: app.uid)) {
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(String(format: "uid=0x%08X", app.uid))
                                .font(.caption2.monospaced()).foregroundColor(.secondary)
                        }
                    }
                }
            }
            Section("Install SIS") {
                if sisFiles.isEmpty {
                    Text("Drop a .sis into Documents/sis to install.")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(sisFiles, id: \.self) { name in
                    Button(name) { install(name) }
                }
            }
        }
        .navigationTitle(romName)
    }

    private func mount() {
        if EKA2L1Emulator.shared().mountRomNamed(romName) {
            mountedRom = romName
            apps = EKA2L1Emulator.shared().rescanApps()
        } else {
            mountError = "Mount failed (no device installed under this ROM folder?)"
        }
    }

    private func install(_ filename: String) {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
        let full = (docs as NSString).appendingPathComponent("sis/\(filename)")
        _ = EKA2L1Emulator.shared().installSis(atPath: full)
        apps = EKA2L1Emulator.shared().rescanApps()
    }
}

struct DiagnosticsView: View {
    @State private var dyncomResult: EKA2L1CpuSmokeResult?
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let r = dyncomResult {
                    Text(r.pass ? "PASS" : "FAIL").bold().foregroundColor(r.pass ? .green : .red)
                    Text("instrs: \(r.instructionsExecuted)").font(.caption.monospaced())
                    Text(String(format: "pc=0x%08X", r.pc)).font(.caption.monospaced())
                    if let reason = r.fallbackReason {
                        Text("fallback: \(reason)").font(.caption).foregroundColor(.orange)
                    }
                } else {
                    Text("Tap to run").font(.caption).foregroundColor(.secondary)
                }
                Button(running ? "Running…" : "Run dyncom smoke") {
                    running = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let r = EKA2L1CpuSmokeBridge.run(with: .dyncom)
                        DispatchQueue.main.async {
                            dyncomResult = r
                            running = false
                        }
                    }
                }.disabled(running)
            }.padding()
        }.navigationTitle("Diagnostics")
    }
}

#Preview {
    ContentView()
}
