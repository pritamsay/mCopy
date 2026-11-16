import Foundation

public enum UninstallRecovery {
    // Stop the app before calling this. Cancel owned incomplete copies and
    // restore recovery files before the installer removes any resume records.
    public static func prepare(applicationSupport: URL) throws {
        let files = FileManager.default
        let legacy = applicationSupport.appendingPathComponent("Mover/transfer.json")
        if files.fileExists(atPath: legacy.path) {
            do {
                _ = try TransferEngine(journal: legacy).load()
            } catch {
                throw TransferError.unsafe("An older myCopy transfer is saved. Finish that transfer before uninstalling; its recovery record was retained.")
            }
            try TransferEngine(journal: legacy).cancelSavedTransfer()
        }
        let jobs = applicationSupport.appendingPathComponent("mCopy/Requests/Jobs")
        guard files.fileExists(atPath: jobs.path) else { return }
        for journal in try files.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try TransferEngine(journal: journal).cancelSavedTransfer()
        }
    }
}
