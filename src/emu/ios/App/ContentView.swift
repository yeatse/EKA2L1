import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// Home surface:
//   - No device installed → ContentUnavailableView prompting a device import
//     (Android `no_device_installed`). The CTA opens the import Form.
//   - One or more devices → app list for the current device. Title is the
//     device name; the ellipsis menu holds Settings, a device switcher,
//     "Install device" and Diagnostics; the leading "+" installs a SIS onto
//     the running device.

// SIS files only — device ROM / RPKG go through ImportDeviceView's own picker.
private let sisTypes: [UTType] = {
    var v: [UTType] = []
    if let sis = UTType("com.eka2l1.sis") { v.append(sis) }
    if let sisx = UTType("com.eka2l1.sisx") { v.append(sisx) }
    v.append(.data) // fallback so SIS files without UTI hints still pick
    return v
}()

private func documentsRoot() -> String {
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSHomeDirectory()
}

// iOS 16 fallback for ContentUnavailableView (which is iOS 17+). Mimics its
// centered icon + title + description + optional action layout so the home
// surface looks consistent across deployment targets.
private struct FallbackUnavailableView<Actions: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title2).bold()
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            actions()
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ContentView: View {
    @State private var booted = false
    @State private var devices: [EKA2L1DeviceItem] = []
    @State private var currentIndex: Int = -1
    @State private var apps: [EKA2L1AppItem] = []
    @State private var bootError: String?
    @State private var banner: String?
    @State private var switching = false

    @State private var showingImportDevice = false
    @State private var showingSisImporter = false
    @State private var showingNGageImporter = false
    @State private var showingSettings = false
    @State private var showingDiagnostics = false
    @State private var showingOnboarding = false
    @AppStorage("ios.onboarding.completed") private var onboardingCompleted = false

    // App list presentation: adaptive icon grid (default) or compact rows.
    // Persisted so the choice sticks across launches.
    @AppStorage("appListUsesGrid") private var usesGridLayout = true

    // Whether to show built-in ROM/system apps alongside user-installed ones.
    // Defaults to false so the list shows only what the user installed.
    @AppStorage("appListShowSystemApps") private var showSystemApps = false

    // Dev/testing convenience: choose a firmware, then launch straight into a
    // given app on startup, skipping the scroll-and-tap. Pass launch arguments
    // as iOS NSArgumentDomain pairs, e.g.
    //   xcrun simctl launch booted com.eka2l1.emulator \
    //     -LaunchROMCode rm-409 -LaunchAppUID 0x2000023D
    // (decimal UID also accepted).
    @State private var autoLaunchUID: UInt32?
    @State private var showingAutoLaunch = false
    @State private var autoLaunchHandled = false
    @State private var launchRomHandled = false

    // App pending uninstall confirmation (set from the long-press context menu).
    @State private var pendingUninstall: EKA2L1AppItem?

    private var currentDevice: EKA2L1DeviceItem? {
        devices.first { $0.index == currentIndex } ?? devices.first
    }

    // Drives the uninstall confirmation dialog off `pendingUninstall`.
    private var uninstallDialogShown: Binding<Bool> {
        Binding(get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } })
    }

    // Apps shown in the list, honouring the "show system apps" toggle.
    private var visibleApps: [EKA2L1AppItem] {
        showSystemApps ? apps : apps.filter { !$0.system }
    }

    // Hint shown when the visible list is empty. If system apps are hidden but
    // some exist, point the user at the toggle instead of the install prompt.
    private var emptyAppsHint: String {
        if !showSystemApps && !apps.isEmpty {
            return String(localized: "home.empty.hiddenSystemApps")
        }
        return String(localized: "home.empty.noApps")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let bootError {
                    if #available(iOS 17, *) {
                        ContentUnavailableView("Emulator failed to initialise",
                                               systemImage: "exclamationmark.triangle",
                                               description: Text(bootError))
                    } else {
                        FallbackUnavailableView(title: "Emulator failed to initialise",
                                                systemImage: "exclamationmark.triangle",
                                                message: bootError) { EmptyView() }
                    }
                } else if devices.isEmpty {
                    emptyState
                } else {
                    appList
                }
            }
            .navigationTitle(currentDevice?.displayName ?? "EKA2L1")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(isPresented: $showingSettings) { SettingsView() }
            .navigationDestination(isPresented: $showingDiagnostics) { DiagnosticsView() }
            .navigationDestination(isPresented: $showingAutoLaunch) {
                if let uid = autoLaunchUID { EmulatorView(uid: uid) }
            }
            .sheet(isPresented: $showingImportDevice) {
                ImportDeviceView { installed in
                    if installed { bootNewestDevice() }
                }
            }
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView {
                    onboardingCompleted = true
                }
            }
            .fileImporter(isPresented: $showingSisImporter,
                          allowedContentTypes: sisTypes,
                          allowsMultipleSelection: true) { handleSisImport($0) }
            .fileImporter(isPresented: $showingNGageImporter,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { handleNGageImport($0) }
            .confirmationDialog("Uninstall \(pendingUninstall?.name ?? "")?",
                                isPresented: uninstallDialogShown,
                                titleVisibility: .visible) {
                if let app = pendingUninstall {
                    Button("Uninstall", role: .destructive) { uninstall(app) }
                }
                Button("Cancel", role: .cancel) { pendingUninstall = nil }
            } message: {
                Text("This removes the package and its files from the device.")
            }
        }
        .onAppear {
            bootIfNeeded()
            if !onboardingCompleted && !Self.isAutomationLaunch {
                showingOnboarding = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
                return
            }
            switch type {
            case .began:
                EKA2L1Bridge.shared.pause()
            case .ended:
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                if options.contains(.shouldResume) {
                    EKA2L1Bridge.shared.resume()
                }
            @unknown default:
                break
            }
        }
    }

    // Context-menu content for an app. Only user-installed apps can be removed;
    // ROM/system apps get no menu items (the menu simply won't appear).
    @ViewBuilder
    private func uninstallMenu(for app: EKA2L1AppItem) -> some View {
        if !app.system {
            Button(role: .destructive) {
                pendingUninstall = app
            } label: {
                Label("Uninstall", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if #available(iOS 17, *) {
            ContentUnavailableView {
                Label("No device installed", systemImage: "iphone.slash")
            } description: {
                Text("import.noDeviceInstalled")
            } actions: {
                Button("import.title") { showingImportDevice = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            FallbackUnavailableView(title: "No device installed",
                                    systemImage: "iphone.slash",
                                    message: String(localized: "import.noDeviceInstalled")) {
                Button("import.title") { showingImportDevice = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var appList: some View {
        if usesGridLayout {
            appGrid
        } else {
            appRows
        }
    }

    private var appGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let banner {
                    Text(banner).font(.caption).foregroundColor(.green)
                }

                Text("Apps (\(visibleApps.count))")
                    .font(.headline)

                if visibleApps.isEmpty {
                    Text(emptyAppsHint)
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)],
                              spacing: 16) {
                        ForEach(visibleApps, id: \.uid) { app in
                            NavigationLink(destination: EmulatorView(uid: app.uid)) {
                                AppGridCell(uid: app.uid, name: app.name)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { uninstallMenu(for: app) }
                        }
                    }
                    .id(currentIndex)
                }
            }
            .padding()
        }
    }

    private var appRows: some View {
        List {
            if let banner {
                Section { Text(banner).font(.caption).foregroundColor(.green) }
            }
            Section("Apps (\(visibleApps.count))") {
                if visibleApps.isEmpty {
                    Text(emptyAppsHint)
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(visibleApps, id: \.uid) { app in
                    NavigationLink(destination: EmulatorView(uid: app.uid)) {
                        AppRow(uid: app.uid, name: app.name)
                    }
                    .contextMenu { uninstallMenu(for: app) }
                }
            }
        }
        .id(currentIndex)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !devices.isEmpty {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingSisImporter = true } label: {
                    Image(systemName: "plus")
                }
                .disabled(switching)

                Menu {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("settings.title", systemImage: "gearshape")
                    }

                    Button {
                        usesGridLayout.toggle()
                    } label: {
                        if usesGridLayout {
                            Label("home.layout.list", systemImage: "list.bullet")
                        } else {
                            Label("home.layout.grid", systemImage: "square.grid.2x2")
                        }
                    }

                    Button {
                        showSystemApps.toggle()
                    } label: {
                        if showSystemApps {
                            Label("Hide System Apps", systemImage: "eye.slash")
                        } else {
                            Label("Show System Apps", systemImage: "eye")
                        }
                    }

                    Menu {
                        ForEach(devices) { dev in
                            Button {
                                switchDevice(to: dev.index)
                            } label: {
                                if dev.index == currentIndex {
                                    Label(dev.displayName, systemImage: "checkmark")
                                } else {
                                    Text(dev.displayName)
                                }
                            }
                        }
                    } label: {
                        Label("Devices", systemImage: "iphone")
                    }

                    Button {
                        showingOnboarding = true
                    } label: {
                        Label("onboarding.title", systemImage: "questionmark.circle")
                    }

                    Button {
                        showingImportDevice = true
                    } label: {
                        Label("import.title", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        showingNGageImporter = true
                    } label: {
                        Label("Install N-Gage Game", systemImage: "folder.badge.plus")
                    }

                    Divider()

                    Button {
                        showingDiagnostics = true
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(switching)
            }
        }
    }

    private func bootIfNeeded() {
        guard !booted else { return }
        if EKA2L1Bridge.shared.start(documentsPath: documentsRoot()) {
            booted = true
            refresh()
            selectLaunchRomThenAutoLaunch()
        } else {
            bootError = "Check Console for details."
        }
    }

    // If launched with -LaunchROMCode, boot that device before any auto app
    // navigation. EmulatorViewController waits for the graphics driver before
    // calling launchApp.
    private func selectLaunchRomThenAutoLaunch() {
        guard !launchRomHandled, let code = Self.launchRomCodeArgument() else {
            maybeAutoLaunch()
            return
        }
        launchRomHandled = true

        guard let target = devices.first(where: { $0.firmwareCode.caseInsensitiveCompare(code) == .orderedSame }) else {
            bootError = "Launch ROM code \(code) is missing."
            return
        }
        guard target.index != currentIndex else {
            maybeAutoLaunch()
            return
        }

        switching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = EKA2L1Bridge.bootDevice(at: target.index)
            DispatchQueue.main.async {
                switching = false
                guard ok else {
                    bootError = "Failed to boot ROM code \(target.firmwareCode)."
                    return
                }
                currentIndex = target.index
                apps = EKA2L1Bridge.shared.rescanApps()
                banner = "Booted \(target.displayName) (\(target.firmwareCode))."
                maybeAutoLaunch()
            }
        }
    }

    private func maybeAutoLaunch() {
        guard !autoLaunchHandled, currentIndex >= 0, let uid = Self.launchAppUIDArgument() else { return }
        autoLaunchHandled = true
        autoLaunchUID = uid
        Task { @MainActor in
            try? await Task.sleep(until: .now + .seconds(1))
            self.showingAutoLaunch = true
        }
    }

    private static func launchAppUIDArgument() -> UInt32? {
        guard let raw = UserDefaults.standard.string(forKey: "LaunchAppUID")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("0x") {
            return UInt32(raw.dropFirst(2), radix: 16)
        }
        return UInt32(raw)
    }

    private static var isAutomationLaunch: Bool {
        launchAppUIDArgument() != nil || UserDefaults.standard.bool(forKey: "EKA2L1RegressionMode")
    }

    private static func launchRomCodeArgument() -> String? {
        for key in ["LaunchROMCode", "LaunchROM", "LaunchDeviceCode", "LaunchDevice"] {
            if let raw = UserDefaults.standard.string(forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                return raw
            }
        }
        return nil
    }

    private func refresh() {
        devices = EKA2L1Bridge.shared.installedDevices()
        currentIndex = EKA2L1Bridge.shared.currentDeviceIndex()
        apps = currentIndex >= 0 ? EKA2L1Bridge.shared.rescanApps() : []
    }

    private func switchDevice(to index: Int) {
        guard index != currentIndex, !switching else { return }
        switching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = EKA2L1Bridge.bootDevice(at: index)
            DispatchQueue.main.async {
                if ok {
                    currentIndex = index
                    apps = EKA2L1Bridge.shared.rescanApps()
                    banner = nil
                }
                switching = false
            }
        }
    }

    // Called after a successful device install. installedDevices() appends the
    // newly-added device last, so boot that one.
    private func bootNewestDevice() {
        devices = EKA2L1Bridge.shared.installedDevices()
        guard let newest = devices.last else { return }
        switching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = EKA2L1Bridge.bootDevice(at: newest.index)
            DispatchQueue.main.async {
                if ok {
                    currentIndex = newest.index
                    apps = EKA2L1Bridge.shared.rescanApps()
                    banner = String(localized: "common.completed")
                }
                switching = false
            }
        }
    }

    private func uninstall(_ app: EKA2L1AppItem) {
        pendingUninstall = nil
        let ok = EKA2L1Bridge.shared.uninstallApp(uid: app.uid)
        apps = EKA2L1Bridge.shared.rescanApps()
        banner = ok ? "Uninstalled \(app.name)." : "Failed to uninstall \(app.name)."
    }

    private func handleSisImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            banner = "Import failed: \(err.localizedDescription)"
        case .success(let urls):
            // Copy into Documents/sis via the shared router (handles the
            // security-scoped URLs), then install each onto the live device.
            _ = ImportRouter.shared.ingest(urls: urls)
            let docs = documentsRoot()
            var installed = 0
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard ext == "sis" || ext == "sisx" else { continue }
                let full = (docs as NSString).appendingPathComponent("sis/\(url.lastPathComponent)")
                if EKA2L1Bridge.shared.installSis(atPath: full) { installed += 1 }
            }
            apps = EKA2L1Bridge.shared.rescanApps()
            banner = "Installed \(installed) package(s)."
        }
    }

    private func handleNGageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            banner = "N-Gage import failed: \(err.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            switching = true
            banner = "Installing N-Gage game..."
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let report = EKA2L1Bridge.installNGageGame(folderPath: url.path)
                DispatchQueue.main.async {
                    switching = false
                    apps = EKA2L1Bridge.shared.rescanApps()
                    if report.succeeded {
                        let name = report.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
                        banner = name.isEmpty ? "Installed N-Gage game." : "Installed N-Gage game: \(name)."
                    } else {
                        banner = ngageErrorMessage(report.result)
                    }
                }
            }
        }
    }

    private func ngageErrorMessage(_ code: Int) -> String {
        switch code {
        case 1:
            return "N-Gage import failed: choose the game card folder that contains the system folder."
        case 2:
            return "N-Gage import failed: that folder contains more than one game."
        case 3:
            return "N-Gage import failed: the registration file is missing."
        case 4:
            return "N-Gage import failed: the registration file is corrupted."
        default:
            return "N-Gage import failed (error \(code))."
        }
    }
}

// Device-install Form. ROM file is mandatory; RPKG is supplied only when the
// installer needs it (S60v2+ dumps). Both files are staged into the sandbox at
// pick time so their paths survive past the security-scoped access window.
struct ImportDeviceView: View {
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private struct StagedFile { let name: String; let path: String }
    private enum PickTarget { case rom, rpkg }

    @State private var rom: StagedFile?
    @State private var rpkg: StagedFile?
    // A single fileImporter driven by which row was tapped. Stacking two
    // .fileImporter modifiers on one view makes SwiftUI drop one of them, so
    // we multiplex through this instead. `pickTarget` is read in the
    // completion handler, so it is left set until then (only the bool drives
    // presentation).
    @State private var pickTarget: PickTarget = .rom
    @State private var showingImporter = false
    @State private var installing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { pickTarget = .rom; showingImporter = true } label: {
                        fileRow(title: String(localized: "import.romFile"), value: rom?.name)
                    }
                    Button { pickTarget = .rpkg; showingImporter = true } label: {
                        fileRow(title: String(localized: "import.rpkgFile"), value: rpkg?.name)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("import.note.rpkg")
                        Text("import.recommendedDevices")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundColor(.red) }
                }

                Section {
                    Button(action: install) {
                        HStack(spacing: 8) {
                            if installing { ProgressView() }
                            Text(installing ? String(localized: "common.processing") : String(localized: "common.install"))
                        }
                    }
                    .disabled(rom == nil || installing)
                }
            }
            .navigationTitle("import.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(installing)
                }
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                let isRpkg = pickTarget == .rpkg
                stage(result, kind: isRpkg ? "rpkg" : "rom") { staged in
                    if isRpkg { rpkg = staged } else { rom = staged }
                }
            }
            .interactiveDismissDisabled(installing)
        }
    }

    private func fileRow(title: String, value: String?) -> some View {
        HStack {
            Text(title).foregroundColor(.primary)
            Spacer()
            Text(value ?? String(localized: "import.noFileSelected"))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func stage(_ result: Result<[URL], Error>, kind: String, assign: (StagedFile?) -> Void) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let tmpDir = (documentsRoot() as NSString).appendingPathComponent("import_tmp")
        let dst = (tmpDir as NSString).appendingPathComponent("\(kind)_\(url.lastPathComponent)")
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.copyItem(at: url, to: URL(fileURLWithPath: dst))
            assign(StagedFile(name: url.lastPathComponent, path: dst))
            errorMessage = nil
        } catch {
            errorMessage = "Failed to read file: \(error.localizedDescription)"
        }
    }

    private func install() {
        guard let rom else { return }
        installing = true
        errorMessage = nil
        let romPath = rom.path
        let rpkgPath = rpkg?.path
        DispatchQueue.global(qos: .userInitiated).async {
            let result = EKA2L1Bridge.installDevice(romPath: romPath, rpkgPath: rpkgPath)
            DispatchQueue.main.async {
                installing = false
                cleanupStaging()
                if result == .success {
                    onFinish(true)
                    dismiss()
                } else {
                    errorMessage = installMessage(for: result)
                }
            }
        }
    }

    private func installMessage(for result: EKA2L1InstallResult) -> String {
        switch result {
        case .success:
            return String(localized: "common.completed")
        case .alreadyExist:
            return String(localized: "import.error.alreadyExists")
        case .determineProductFailure:
            return String(localized: "import.error.determineProduct")
        case .insufficient:
            return String(localized: "import.error.insufficient")
        case .notExist:
            return String(localized: "import.error.notExist")
        case .rpkgCorrupt:
            return String(localized: "import.error.rpkgCorrupt")
        case .vplInvalid:
            return String(localized: "import.error.vplInvalid")
        case .romCorrupt:
            return String(localized: "import.error.romCorrupt")
        case .rofsCorrupt:
            return String(localized: "import.error.rofsCorrupt")
        case .fpsxCorrupt:
            return String(localized: "import.error.fpsxCorrupt")
        case .romFailToCopy:
            return String(localized: "import.error.romCopy")
        case .needRpkg:
            return String(localized: "import.error.needRpkg")
        case .generalFailure:
            return String(localized: "common.error")
        @unknown default:
            return String(localized: "common.error")
        }
    }

    private func cleanupStaging() {
        let tmpDir = (documentsRoot() as NSString).appendingPathComponent("import_tmp")
        try? FileManager.default.removeItem(atPath: tmpDir)
        rom = nil
        rpkg = nil
    }
}

// A large centered icon with the app name beneath, sized to fit the adaptive
// LazyVGrid cells. The registered icon (MIF/MBM/SVGB/NVG → RGBA → PNG) is
// lazily decoded off the main queue so scrolling the app grid stays smooth.
// The bridge returns nil for apps without a usable icon, which falls back to
// a generic SF Symbol placeholder.
struct AppGridCell: View {
    let uid: UInt32
    let name: String

    @State private var icon: UIImage?
    @State private var loadedUID: UInt32?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let icon {
                    Image(uiImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 72, height: 72)

            Text(name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
        .onAppear(perform: loadIcon)
        .onChange(of: uid) { _ in
            icon = nil
            loadedUID = nil
            loadIcon()
        }
    }

    private func loadIcon() {
        guard loadedUID != uid else { return }
        let uid = self.uid
        loadedUID = uid
        DispatchQueue.global(qos: .userInitiated).async {
            let data = EKA2L1Bridge.iconPNGData(uid: uid, sizePx: 144)
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                guard self.uid == uid, self.loadedUID == uid else { return }
                self.icon = image
            }
        }
    }
}

// Compact row used by the List layout: small leading icon, name, and UID.
// Icon decoding mirrors AppGridCell (off the main queue, generic placeholder
// when the bridge has no usable icon).
struct AppRow: View {
    let uid: UInt32
    let name: String

    @State private var icon: UIImage?
    @State private var loadedUID: UInt32?

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
            }
        }
        .onAppear(perform: loadIcon)
        .onChange(of: uid) { _ in
            icon = nil
            loadedUID = nil
            loadIcon()
        }
    }

    private func loadIcon() {
        guard loadedUID != uid else { return }
        let uid = self.uid
        loadedUID = uid
        DispatchQueue.global(qos: .userInitiated).async {
            let data = EKA2L1Bridge.iconPNGData(uid: uid, sizePx: 72)
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                guard self.uid == uid, self.loadedUID == uid else { return }
                self.icon = image
            }
        }
    }
}

struct DiagnosticsView: View {
    @State private var dyncomResult: CpuSmokeReport?
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
                        let r = EKA2L1Bridge.runSmoke(backend: .dyncom)
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
