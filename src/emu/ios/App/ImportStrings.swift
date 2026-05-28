import Foundation

// User-facing copy for the device-import surface. Text is ported verbatim
// from the Android frontend's res/values/strings.xml so the two stay in sync
// (no_device_installed, install_device_note_may_need_rpkg,
// recommended_devices_to_install, and the install_* error messages).
enum ImportStrings {
    static let noDeviceInstalled =
        "Please install a device. Files and ROM of a Symbian device are needed for the installation.\n\nNote: Each app will need suitable Symbian device to run."

    static let installDeviceNoteMayNeedRpkg =
        "For S60v2 devices or higher, you may need to provide additional file called RPKG. The path chooser will pop up if the installer detects the need for it."

    static let recommendedDevicesToInstall = "Recommend devices to install"

    static let romFilePrompt = "ROM file"
    static let rpkgFilePrompt = "RPKG file (optional)"
    static let noFileSelected = "Tap to choose…"

    static let installCTA = "Install"
    static let processing = "Processing…"
    static let completed = "Completed!"
    static let importDeviceTitle = "Install device"

    static func message(for result: EKA2L1InstallResult) -> String {
        switch result {
        case .success:
            return completed
        case .alreadyExist:
            return "Device to install already exists!"
        case .determineProductFailure:
            return "Fail to determine product information!"
        case .insufficient:
            return "RPKG file is too small, the dump might be unfinished!"
        case .notExist:
            return "RPKG file specified can't be opened!"
        case .rpkgCorrupt:
            return "The RPKG file provided is corrupt!"
        case .vplInvalid:
            return "The firmware description file (VPL) file is invalid!"
        case .romCorrupt:
            return "ROM file is corrupted!"
        case .rofsCorrupt:
            return "ROFS file is corrupted!"
        case .fpsxCorrupt:
            return "FPSX file is corrupted!"
        case .romFailToCopy:
            return "Fail to copy ROM to target destination!"
        case .needRpkg:
            return "This ROM requires an additional RPKG file. Please choose one and try again."
        case .generalFailure:
            return "Error"
        @unknown default:
            return "Error"
        }
    }
}
