import Foundation

enum NetworkVolumeAccess {
    // Launched by the installer as the app itself, so macOS attributes the
    // approval to mCopy. The user clicks the native Allow button, not Settings.
    // A directory listing requests access without copying or changing files.
    static func requestMountedVolumes() {
        let files = FileManager.default
        let volumes = files.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: []) ?? []
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: [.volumeIsLocalKey]), values.volumeIsLocal == false else { continue }
            do {
                _ = try files.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                NSLog("mCopy: network-volume access available at %@", volume.path)
                // Network-volume permission is a system category, not a grant
                // for just this directory. Avoid scanning every mounted share.
                return
            } catch {
                NSLog("mCopy: network-volume setup could not access %@: %@", volume.path, error.localizedDescription)
                return
            }
        }
        NSLog("mCopy: no NAS is mounted. macOS will request access on the first network-volume transfer.")
    }
}
