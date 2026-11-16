import AppKit

// macOS owns these permissions. Explain the one-time system setup without
// pretending that our own Allow button can grant Full Disk Access.
final class PermissionSetup {
    static func showIfNeeded() {
        let path = Bundle.main.bundleURL.path
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/myCopy.app").path
        guard path == installed || path == "/Applications/myCopy.app",
              !UserDefaults.standard.bool(forKey: "fileAccessSetupShown") else { return }
        show()
    }

    static func show() {
        let alert = NSAlert()
        alert.messageText = "Set up mCopy file access once"
        alert.informativeText = "For copying across protected folders, external disks and NAS locations, add myCopy in System Settings → Privacy & Security → Full Disk Access and turn it on. macOS remembers your choice for this installed app.\n\nYou can also keep your existing permissions and allow individual locations when macOS asks. NAS usernames/passwords and server file permissions are managed separately.\n\nThe new Finder workflow shares only mCopy’s own selection and does not read other apps’ clipboard contents."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Use Existing Permissions")
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        // Record that the explanation was shown, never a claim that access was
        // granted. The Permissions button can reopen it at any time.
        UserDefaults.standard.set(true, forKey: "fileAccessSetupShown")
        if result == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
