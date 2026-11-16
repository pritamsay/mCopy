# mCopy 3.1.0

- One-command installation and uninstallation from GitHub.
- Prebuilt universal app for Apple Silicon and Intel, macOS 13 or later.
- SHA-256 and code-signature checks before installation.
- Clean login-item and Finder-extension removal, with recovery of unfinished transfers.
- Legacy build cleanup without needing Xcode on the destination Mac.
- Finder-only Copy/Cut/Paste workflow, background verification, NAS retries, SMB timestamp handling, and replacement recovery.

The app is signed locally, not Apple-notarized. macOS may request approval for the Finder extension, login item, or running the app. Transfer tests and a real connected-SMB-share test passed; physical disconnect/power-loss tests and execution on Intel hardware are not claimed.
