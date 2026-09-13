import Cocoa
import ScreenCaptureKit

/// The permission request is reachable only after the user accepts the explanation.
/// Injected actions let tests cover denial and cancellation without changing TCC.
@MainActor struct LayoutHelperPermissionFlow {
    enum Outcome: Equatable { case alreadyAllowed, iconsOnly, allowed, needsSettings }
    var isAllowed: () -> Bool
    var explain: () -> Bool
    var request: () async -> Bool
    var openSettings: () -> Void

    func run() async -> Outcome {
        if isAllowed() { return .alreadyAllowed }
        guard explain() else { return .iconsOnly }
        let granted = await request()
        if granted || isAllowed() { return .allowed }
        openSettings()
        return .needsSettings
    }
}

enum LayoutHelperPermission {
    private static var requesting = false
    static var previewsSupported: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    static var previewsAllowed: Bool {
        previewsSupported && CGPreflightScreenCaptureAccess()
    }

    static func explanationAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enable window previews for Layout Helper?"
        alert.informativeText = "Rectangle needs Screen Recording permission to show thumbnails of your open windows. It takes still images for the picker; images are not saved and audio is not captured.\n\nClick Enable Previews to request access. If System Settings opens, turn on Rectangle under Privacy & Security → Screen & System Audio Recording. If Rectangle is missing, click + and select Rectangle in Applications. Reopen Rectangle if macOS asks.\n\nYou can also keep using Layout Helper with app icons and window titles. Window Divider is a separate feature and does not need Screen Recording permission."
        alert.addButton(withTitle: "Enable Previews")
        alert.addButton(withTitle: "Use Icons and Titles")
        return alert
    }

    /// Keep the UI responsive while ScreenCaptureKit waits for the system consent dialog.
    /// Enumeration requests access but does not capture images or start a recording.
    static func guideIfNeeded(completion: @escaping () -> Void = {}) {
        guard #available(macOS 14, *), !requesting else { completion(); return }
        requesting = true
        Task { @MainActor in
            defer { requesting = false; completion() }
            _ = await LayoutHelperPermissionFlow(
                isAllowed: { previewsAllowed },
                explain: {
                    NSApp.activate(ignoringOtherApps: true)
                    return explanationAlert().runModal() == .alertFirstButtonReturn
                },
                request: {
                    NSLog("Layout Helper: requesting ScreenCaptureKit access for %@", Bundle.main.bundleIdentifier ?? "Rectangle")
                    do {
                        _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                        NSLog("Layout Helper: ScreenCaptureKit access succeeded")
                        return true
                    } catch {
                        let error = error as NSError
                        NSLog("Layout Helper: ScreenCaptureKit access failed (%@, %ld)", error.domain, error.code)
                        return false
                    }
                },
                openSettings: {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                    if !NSWorkspace.shared.open(url) {
                        AlertUtil.oneButtonAlert(question: "Enable Screen Recording for Rectangle",
                            text: "Open System Settings → Privacy & Security → Screen & System Audio Recording, then enable Rectangle. If it is missing, click + and select Rectangle in Applications. Reopen Rectangle if macOS asks. Layout Helper can still use icons and titles.")
                    }
                }
            ).run()
        }
    }
}
