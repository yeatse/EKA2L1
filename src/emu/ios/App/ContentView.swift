import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// Home surface:
//   - No device installed → ContentUnavailableView prompting a device import
//     (Android `no_device_installed`). The CTA opens the import Form.
//   - One or more devices → app grid for the current device. The navigation
//     title doubles as a device menu (tap the title) holding the device
//     switcher and, below a divider, "Install device"; the ellipsis menu holds
//     Settings, the system-apps toggle and help; the "+" menu installs a SIS,
//     a classic N-Gage game card, or an N-Gage 2.0 package onto the device.

// SIS files only — device ROM / RPKG go through ImportDeviceView's own picker.
private let sisTypes: [UTType] = {
    var v: [UTType] = []
    if let sis = UTType("com.eka2l1.sis") { v.append(sis) }
    if let sisx = UTType("com.eka2l1.sisx") { v.append(sisx) }
    v.append(.data) // fallback so SIS files without UTI hints still pick
    return v
}()

// N-Gage 2.0 game packages (.n-gage). Copied onto the E drive for the N-Gage
// launcher to install from; see handleNGage2Import.
private let ngage2Types: [UTType] = {
    var v: [UTType] = []
    if let pkg = UTType("com.eka2l1.ngage") { v.append(pkg) }
    v.append(.data) // fallback so packages without UTI hints still pick
    return v
}()

private enum HomeImportTarget {
    case sis
    case ngage    // classic N-Gage game card folder (installed onto E:)
    case ngage2   // N-Gage 2.0 .n-gage package (staged into E:\n-gage)
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
    @State private var homeImportTarget: HomeImportTarget = .sis
    @State private var showingHomeImporter = false
    @State private var showingSettings = false
    @State private var showingOnboarding = false
    @AppStorage("ios.onboarding.completed") private var onboardingCompleted = false

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

    // Files handed over by the system ("Open in EKA2L1" from the Files app /
    // share sheet). On a cold launch onOpenURL can fire before the emulator
    // has booted, so URLs are queued here and drained once boot completes.
    @State private var pendingOpenURLs: [URL] = []

    private var currentDevice: EKA2L1DeviceItem? {
        devices.first { $0.index == currentIndex } ?? devices.first
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

    private var homeImporterTypes: [UTType] {
        switch homeImportTarget {
        case .sis:
            return sisTypes
        case .ngage:
            return [.folder]
        case .ngage2:
            return ngage2Types
        }
    }

    private var homeImporterAllowsMultipleSelection: Bool {
        // Folder-based classic N-Gage install picks a single game card; SIS and
        // .n-gage packages can be batch-imported.
        homeImportTarget != .ngage
    }

    var body: some View {
        NavigationStack {
            Group {
                if let bootError {
                    if #available(iOS 17, *) {
                        ContentUnavailableView(String(localized: "home.error.initTitle"),
                                               systemImage: "exclamationmark.triangle",
                                               description: Text(bootError))
                    } else {
                        FallbackUnavailableView(title: String(localized: "home.error.initTitle"),
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
            .toolbarTitleMenu { titleMenuContent }
            .navigationDestination(isPresented: $showingSettings) { SettingsView() }
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
            .fileImporter(isPresented: $showingHomeImporter,
                          allowedContentTypes: homeImporterTypes,
                          allowsMultipleSelection: homeImporterAllowsMultipleSelection) {
                handleHomeImport($0)
            }
        }
        .onAppear {
            bootIfNeeded()
            if !onboardingCompleted && !Self.isAutomationLaunch {
                showingOnboarding = true
            }
        }
        .onOpenURL { url in
            pendingOpenURLs.append(url)
            processPendingOpenURLs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .eka2l1AppListInvalidated)) { _ in
            // A settings action (e.g. a system-language switch) changed how the
            // app list should render; re-scan so the new captions show.
            guard booted, currentIndex >= 0 else { return }
            apps = EKA2L1Bridge.shared.rescanApps()
        }
        .onReceive(NotificationCenter.default.publisher(for: .eka2l1DevicesChanged)) { note in
            handleDevicesChanged(note)
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

    // Context-menu content for an app. Every app exposes a "copy UID" entry
    // (the hex UID doubles as the label); only user-installed apps additionally
    // offer uninstall — ROM/system apps cannot be removed.
    @ViewBuilder
    private func appContextMenu(for app: EKA2L1AppItem) -> some View {
        Button {
            UIPasteboard.general.string = uidHexString(app.uid)
            banner = String(localized: "home.banner.copied \(uidHexString(app.uid))")
        } label: {
            Label(uidHexString(app.uid), systemImage: "doc.on.doc")
        }

        if !app.system {
            Button(role: .destructive) {
                pendingUninstall = app
            } label: {
                Label("home.uninstall.action", systemImage: "trash")
            }
        }
    }

    // Canonical hex form used both on the menu label and on the clipboard.
    private func uidHexString(_ uid: UInt32) -> String {
        String(format: "0x%08X", uid)
    }

    @ViewBuilder
    private var emptyState: some View {
        if #available(iOS 17, *) {
            ContentUnavailableView {
                Label("home.noDevice.title", systemImage: "iphone.slash")
            } description: {
                Text("import.noDeviceInstalled")
            } actions: {
                Button("import.title") { showingImportDevice = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            FallbackUnavailableView(title: String(localized: "home.noDevice.title"),
                                    systemImage: "iphone.slash",
                                    message: String(localized: "import.noDeviceInstalled")) {
                Button("import.title") { showingImportDevice = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var appList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("home.appsCount \(visibleApps.count)")
                    .font(.headline)

                if visibleApps.isEmpty {
                    Text(emptyAppsHint)
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    // Narrower columns so a phone-width screen fits four icons
                    // per row (72pt icon + label, ~4pt slack).
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)],
                              spacing: 16) {
                        ForEach(visibleApps, id: \.uid) { app in
                            NavigationLink(destination: EmulatorView(uid: app.uid)) {
                                AppGridCell(uid: app.uid, name: app.name)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { appContextMenu(for: app) }
                            // Attached to the icon itself (rather than the
                            // NavigationStack root) so the confirmation is
                            // anchored to the pressed app's cell, matching
                            // iOS 26's popover-style presentation instead of
                            // detaching to a generic bottom sheet.
                            .confirmationDialog(Text("home.uninstall.title \(app.name)"),
                                                isPresented: Binding(
                                                    get: { pendingUninstall?.uid == app.uid },
                                                    set: { if !$0 { pendingUninstall = nil } }),
                                                titleVisibility: .visible) {
                                Button("home.uninstall.confirm", role: .destructive) { uninstall(app) }
                                Button("common.cancel", role: .cancel) { pendingUninstall = nil }
                            } message: {
                                Text("home.uninstall.message")
                            }
                        }
                    }
                    .id(currentIndex)
                }
            }
            .padding()
        }
    }

    // The navigation title's tap menu (SwiftUI toolbarTitleMenu): the device
    // switcher with a checkmark on the active device, then "Install device"
    // below a divider.
    @ViewBuilder
    private var titleMenuContent: some View {
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
            .disabled(switching)
        }

        Divider()

        Button {
            showingImportDevice = true
        } label: {
            Label("import.title", systemImage: "square.and.arrow.down")
        }
        .disabled(switching)

        Button {
            rescanDevices()
        } label: {
            Label("device.rescan", systemImage: "arrow.clockwise")
        }
        .disabled(switching)
    }

    private var statusToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .status) {
            HStack(spacing: 6) {
                if switching {
                    ProgressView()
                        .controlSize(.small)
                }
                if let banner {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Status text (install/boot results) lives in the bottom-center status
        // toolbar slot; a spinner joins it while a long-running task (device
        // switch, SIS/N-Gage install) is in flight. On iOS 26 the shared glass
        // background is hidden so the text sits directly on the content.
        if switching || banner != nil {
            if #available(iOS 26.0, *) {
                statusToolbarItem.sharedBackgroundVisibility(.hidden)
            } else {
                statusToolbarItem
            }
        }

        if !devices.isEmpty {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        homeImportTarget = .sis
                        showingHomeImporter = true
                    } label: {
                        Label("home.install.sis", systemImage: "square.and.arrow.down")
                    }

                    // A second Text in a menu button's label renders as the item
                    // subtitle (UIMenuElement.subtitle), spelling out the ROM /
                    // launcher prerequisite for each N-Gage flavour.
                    Button {
                        homeImportTarget = .ngage
                        showingHomeImporter = true
                    } label: {
                        Text("home.installNGage")
                        Text("home.installNGage.subtitle")
                        Image(systemName: "folder.badge.plus")
                    }

                    Button {
                        homeImportTarget = .ngage2
                        showingHomeImporter = true
                    } label: {
                        Text("home.installNGage2")
                        Text("home.installNGage2.subtitle")
                        Image(systemName: "arrow.down.doc")
                    }
                } label: {
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
                        showSystemApps.toggle()
                    } label: {
                        if showSystemApps {
                            Label("home.hideSystemApps", systemImage: "eye.slash")
                        } else {
                            Label("home.showSystemApps", systemImage: "eye")
                        }
                    }

                    Divider()

                    Button {
                        showingOnboarding = true
                    } label: {
                        Label("onboarding.title", systemImage: "questionmark.circle")
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
            processPendingOpenURLs()
        } else {
            bootError = String(localized: "home.error.checkConsole")
        }
    }

    // Drains system-opened files once the emulator is up. SIS packages are
    // auto-installed onto the current device; .n-gage packages are staged onto
    // the E drive (both mirror the "+" importer); other registered types
    // (fonts, ROM zips) are staged by ImportRouter.
    private func processPendingOpenURLs() {
        guard booted, !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs = []

        let sisURLs = urls.filter { ["sis", "sisx"].contains($0.pathExtension.lowercased()) }
        let ngage2URLs = urls.filter { $0.pathExtension.lowercased() == "n-gage" }
        let otherURLs = urls.filter { !sisURLs.contains($0) && !ngage2URLs.contains($0) }

        if !otherURLs.isEmpty {
            banner = ImportRouter.shared.ingest(urls: otherURLs)
            refresh()
        }
        if !ngage2URLs.isEmpty {
            handleNGage2Import(.success(ngage2URLs))
        }
        guard !sisURLs.isEmpty else { return }
        guard currentIndex >= 0 else {
            banner = String(localized: "home.banner.installDeviceFirst")
            return
        }
        handleSisImport(.success(sisURLs))
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
            bootError = String(localized: "home.error.launchRomMissing \(code)")
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
                    bootError = String(localized: "home.error.bootRomFailed \(target.firmwareCode)")
                    return
                }
                currentIndex = target.index
                apps = EKA2L1Bridge.shared.rescanApps()
                banner = String(localized: "home.banner.booted \(target.displayName) \(target.firmwareCode)")
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

    // Mirrors the Android device-list screen's "Rescan devices" action: rebuild
    // device_manager from what's on drive Z (recovers devices dropped from
    // devices.yml), then boot the resulting current device (always index 0
    // when the scan finds anything).
    private func rescanDevices() {
        guard !switching else { return }
        switching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = EKA2L1Bridge.rescanDevices()
            let bootedOK = found && EKA2L1Bridge.bootDevice(at: 0)
            DispatchQueue.main.async {
                devices = EKA2L1Bridge.shared.installedDevices()
                if bootedOK {
                    currentIndex = 0
                    apps = EKA2L1Bridge.shared.rescanApps()
                } else if devices.isEmpty {
                    currentIndex = -1
                    apps = []
                }
                banner = String(localized: "common.completed")
                switching = false
            }
        }
    }

    private func uninstall(_ app: EKA2L1AppItem) {
        pendingUninstall = nil
        let ok = EKA2L1Bridge.shared.uninstallApp(uid: app.uid)
        apps = EKA2L1Bridge.shared.rescanApps()
        banner = ok ? String(localized: "home.banner.uninstalled \(app.name)")
                    : String(localized: "home.banner.uninstallFailed \(app.name)")
    }

    // A ROM was deleted or all data was reset from Settings. Re-sync the device
    // list; if the booted device itself was removed, boot device_manager's
    // adjusted current (the previous ROM) so the running system matches
    // devices.yml, or drop to the empty state when nothing remains.
    private func handleDevicesChanged(_ note: Notification) {
        // A rename only rewrites device titles; the count and current index are
        // unchanged, so just re-read the list (refreshing the nav title + device
        // switcher) without rebooting or re-scanning apps.
        if note.userInfo?["renamed"] as? Bool == true {
            devices = EKA2L1Bridge.shared.installedDevices()
            return
        }

        let deletedFirmcode = note.userInfo?["firmcode"] as? String
        let wasCurrent = deletedFirmcode.map { code in
            currentDevice?.firmwareCode.caseInsensitiveCompare(code) == .orderedSame
        } ?? true

        let newDevices = EKA2L1Bridge.shared.installedDevices()
        devices = newDevices
        banner = nil

        if newDevices.isEmpty {
            currentIndex = -1
            apps = []
            return
        }

        guard wasCurrent else {
            // The booted device is unchanged; only indices shifted. Re-sync
            // from device_manager's adjusted current.
            currentIndex = EKA2L1Bridge.shared.currentDeviceIndex()
            apps = EKA2L1Bridge.shared.rescanApps()
            return
        }

        // The booted device was deleted: fall back to the previous ROM in the
        // list (clamped into range), so repeated deletes walk backwards until
        // the list is empty. `currentIndex` still holds the deleted device's
        // old position at this point.
        let target = min(max(0, currentIndex - 1), newDevices.count - 1)
        switching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = EKA2L1Bridge.bootDevice(at: target)
            DispatchQueue.main.async {
                if ok {
                    currentIndex = target
                    apps = EKA2L1Bridge.shared.rescanApps()
                }
                switching = false
            }
        }
    }

    private func handleHomeImport(_ result: Result<[URL], Error>) {
        switch homeImportTarget {
        case .sis:
            handleSisImport(result)
        case .ngage:
            handleNGageImport(result)
        case .ngage2:
            handleNGage2Import(result)
        }
    }

    private func handleSisImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            banner = String(localized: "home.banner.importFailed \(err.localizedDescription)")
        case .success(let urls):
            // Install straight from the picked/opened location. The installer
            // extracts everything onto the device drives, so the package file
            // itself is not needed afterwards — no staging copy. The URLs are
            // security-scoped, so hold the scope across the install call.
            // Extraction can take a while for large packages, so run it off
            // the main thread with the busy indicator up.
            switching = true
            banner = String(localized: "home.banner.installingPackages \(urls.count)")
            DispatchQueue.global(qos: .userInitiated).async {
                var installed = 0
                for url in urls {
                    let ext = url.pathExtension.lowercased()
                    guard ext == "sis" || ext == "sisx" else { continue }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if EKA2L1Bridge.shared.installSis(atPath: url.path) { installed += 1 }
                }
                DispatchQueue.main.async {
                    switching = false
                    apps = EKA2L1Bridge.shared.rescanApps()
                    banner = String(localized: "home.banner.installedPackages \(installed)")
                }
            }
        }
    }

    private func handleNGageImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            banner = String(localized: "home.ngage.importFailed \(err.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else { return }
            switching = true
            banner = String(localized: "home.ngage.installing")
            DispatchQueue.global(qos: .userInitiated).async {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let report = EKA2L1Bridge.installNGageGame(folderPath: url.path)
                DispatchQueue.main.async {
                    switching = false
                    apps = EKA2L1Bridge.shared.rescanApps()
                    if report.succeeded {
                        let name = report.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
                        banner = name.isEmpty ? String(localized: "home.ngage.installed")
                                              : String(localized: "home.ngage.installedNamed \(name)")
                    } else {
                        banner = ngageErrorMessage(report.result)
                    }
                }
            }
        }
    }

    // N-Gage 2.0 install directory on the E drive. The mounted physical path is
    // <Documents>/data/drives/e/ (see IosEmulator mount), and the N-Gage
    // launcher reads packages from E:\n-gage.
    private static func ngage2StagingDir() -> String {
        (documentsRoot() as NSString).appendingPathComponent("data/drives/e/n-gage")
    }

    // N-Gage 2.0 packages aren't installed by us — they're just copied onto the
    // E drive so the (separately installed) N-Gage launcher can pick them up.
    // Same security-scoped copy pattern as the SIS importer.
    private func handleNGage2Import(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            banner = String(localized: "home.ngage.importFailed \(err.localizedDescription)")
        case .success(let urls):
            switching = true
            banner = String(localized: "home.ngage2.importing \(urls.count)")
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = Self.ngage2StagingDir()
                let fm = FileManager.default
                var imported = 0
                do {
                    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    for url in urls {
                        guard url.pathExtension.lowercased() == "n-gage" else { continue }
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let dst = (dir as NSString).appendingPathComponent(url.lastPathComponent)
                        if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
                        try fm.copyItem(at: url, to: URL(fileURLWithPath: dst))
                        imported += 1
                    }
                } catch {
                    DispatchQueue.main.async {
                        switching = false
                        banner = String(localized: "home.ngage.importFailed \(error.localizedDescription)")
                    }
                    return
                }
                DispatchQueue.main.async {
                    switching = false
                    banner = String(localized: "home.ngage2.imported \(imported)")
                }
            }
        }
    }

    private func ngageErrorMessage(_ code: Int) -> String {
        switch code {
        case 1:
            return String(localized: "home.ngage.error.chooseFolder")
        case 2:
            return String(localized: "home.ngage.error.multipleGames")
        case 3:
            return String(localized: "home.ngage.error.regMissing")
        case 4:
            return String(localized: "home.ngage.error.regCorrupt")
        default:
            return String(localized: "home.ngage.error.generic \(code)")
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
                    Text("import.recommendedDevices")
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
                    Button("common.cancel") { dismiss() }.disabled(installing)
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

// App icon shared by the grid and row cells. The registered icon
// (MIF/MBM/SVGB/NVG → RGBA → PNG) is lazily decoded off the main queue so
// scrolling stays smooth; the bridge returns nil for apps without a usable
// icon, which falls back to a generic SF Symbol placeholder.
private struct AppIconView: View {
    let uid: UInt32
    // Pixel size requested from the icon decoder; iconSide/placeholderSide are
    // the on-screen point sizes for the decoded icon and the fallback symbol.
    let decodePx: UInt
    let iconSide: CGFloat
    let placeholderSide: CGFloat

    @State private var icon: UIImage?
    @State private var loadedUID: UInt32?

    var body: some View {
        ZStack {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSide, height: iconSide)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .frame(width: placeholderSide, height: placeholderSide)
                    .foregroundColor(.secondary)
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
            let data = EKA2L1Bridge.iconPNGData(uid: uid, sizePx: decodePx)
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                guard self.uid == uid, self.loadedUID == uid else { return }
                self.icon = image
            }
        }
    }
}

// A large centered icon with the app name beneath, sized to fit the adaptive
// LazyVGrid cells.
struct AppGridCell: View {
    let uid: UInt32
    let name: String

    var body: some View {
        VStack(spacing: 8) {
            AppIconView(uid: uid, decodePx: 144, iconSide: 64, placeholderSide: 48)
                .frame(width: 72, height: 72)

            Text(name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    ContentView()
}
