import SwiftUI
import UniformTypeIdentifiers

// Stage-2 navigation shell:
//   1. Rom list   — picks a folder under <Documents>/roms.
//   2. App list   — applist_server scan + "Install SIS" affordance.
//   3. Emulator   — full-screen UIKit/EAGL view (EmulatorView.swift).
// The CPU smoke surface from stage 1 moves into Diagnostics so it stays
// reachable but does not block the main flow.

// Stage 3.5 import surface. .fileImporter wraps UIDocumentPickerViewController
// and handles security-scoped URLs cleanly. We accept SIS / SISX / ZIP (ROM
// bundle) / TTF / OTF — see Info.plist CFBundleDocumentTypes for the matching
// UTI declarations.
private let importTypes: [UTType] = {
    var v: [UTType] = []
    if let sis = UTType("com.eka2l1.sis") { v.append(sis) }
    if let sisx = UTType("com.eka2l1.sisx") { v.append(sisx) }
    v.append(.zip)
    v.append(.font)
    v.append(.data) // fallback so SIS files from sources without UTI hints still pick
    return v
}()

struct ContentView: View {
    @State private var booted = false
    @State private var roms: [String] = []
    @State private var apps: [EKA2L1AppEntry] = []
    @State private var sisFiles: [String] = []
    @State private var bootError: String?
    @State private var importBanner: String?
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if let bootError {
                    Text(bootError).foregroundColor(.red).padding()
                }
                if let importBanner {
                    Text(importBanner).font(.caption).foregroundColor(.green).padding(.horizontal)
                }
                List {
                    Section("Documents/roms") {
                        if roms.isEmpty {
                            Text("Tap Import to add a ROM bundle (.zip) or SIS / font.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        ForEach(roms, id: \.self) { name in
                            NavigationLink(name) {
                                AppListView(romName: name, apps: $apps, sisFiles: $sisFiles, importBanner: $importBanner)
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
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
                handleImport(result)
            }
        }
        .onAppear(perform: bootIfNeeded)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            importBanner = "Import failed: \(err.localizedDescription)"
        case .success(let urls):
            let outcome = ImportRouter.shared.ingest(urls: urls)
            importBanner = outcome
            refresh()
        }
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
    @Binding var importBanner: String?

    @State private var mountedRom: String?
    @State private var mountError: String?
    @State private var showingImporter = false

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
                ForEach(Array(apps.enumerated()), id: \.offset) { _, app in
                    NavigationLink(destination: EmulatorView(uid: app.uid)) {
                        AppRow(uid: app.uid, name: app.name)
                    }
                }
            }
            Section("Install SIS") {
                if sisFiles.isEmpty {
                    Text("Tap Import to add a .sis / .sisx file.")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(sisFiles, id: \.self) { name in
                    Button(name) { install(name) }
                }
            }
        }
        .navigationTitle(romName)
        .toolbar {
            Button {
                showingImporter = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .failure(let err):
                importBanner = "Import failed: \(err.localizedDescription)"
            case .success(let urls):
                importBanner = ImportRouter.shared.ingest(urls: urls)
                refreshSisFiles()
            }
        }
    }

    private func refreshSisFiles() {
        let fm = FileManager.default
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
        let sisDir = (docs as NSString).appendingPathComponent("sis")
        sisFiles = ((try? fm.contentsOfDirectory(atPath: sisDir)) ?? []).filter {
            $0.lowercased().hasSuffix(".sis") || $0.lowercased().hasSuffix(".sisx")
        }
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

// 3.6: lazily decode the registered icon (MIF/MBM/SVGB/NVG → RGBA → PNG)
// off the main queue so scrolling the AppList stays smooth. The bridge
// returns nil for apps without a usable icon, which falls back to a
// generic SF Symbol placeholder.
struct AppRow: View {
    let uid: UInt32
    let name: String

    @State private var icon: UIImage?
    @State private var attempted = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let icon {
                    Image(uiImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 36, height: 36)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading) {
                Text(name)
                Text(String(format: "uid=0x%08X", uid))
                    .font(.caption2.monospaced()).foregroundColor(.secondary)
            }
        }
        .onAppear(perform: loadIcon)
    }

    private func loadIcon() {
        guard !attempted else { return }
        attempted = true
        let uid = self.uid
        DispatchQueue.global(qos: .userInitiated).async {
            let data = EKA2L1Emulator.shared().iconPNGData(forUID: uid, sizePx: 72)
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                self.icon = image
            }
        }
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
