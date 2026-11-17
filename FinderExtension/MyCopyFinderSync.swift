import AppKit
import FinderSync

@objc(MyCopyFinderSync)
final class MyCopyFinderSync: FIFinderSync {
    var selected: [URL] = []
    var target: URL?
    var currentMenuKind = FIMenuKind.contextualMenuForContainer
    var volumeTimer: Timer?
    var registeredDirectories: Set<URL> = []

    override init() {
        super.init()
        registerVolumes()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged), name: NSWorkspace.didUnmountNotification, object: nil)
        volumeTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.registerVolumes()
        }
    }

    deinit {
        volumeTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc func volumesChanged(_ notification: Notification) { registerVolumes() }

    func registerVolumes() {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        let directories = Set([URL(fileURLWithPath: "/"), FileManager.default.homeDirectoryForCurrentUser] + mounted)
        if directories != registeredDirectories {
            FIFinderSyncController.default().directoryURLs = directories
            registeredDirectories = directories
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        selected = controller.selectedItemURLs() ?? []
        target = controller.targetedURL()
        currentMenuKind = menuKind
        let menu = NSMenu(title: "mCopy")
        menu.autoenablesItems = false
        let submenu = NSMenu(title: "mCopy")
        submenu.autoenablesItems = false
        let isItem = menuKind == .contextualMenuForItems || menuKind == .contextualMenuForSidebar
        let commands = FinderMenu.commands(hasSelection: isItem && !selected.isEmpty,
            hasClipboard: FinderClipboard.hasSelection(), clickedFolder: folderDestination != nil)
        guard !commands.isEmpty else { return nil }
        for command in commands {
            switch command {
            case .copy: add(command.rawValue, action: #selector(copyFiles), enabled: true, to: submenu)
            case .cut: add(command.rawValue, action: #selector(cutFiles), enabled: true, to: submenu)
            case .paste: add(command.rawValue, action: #selector(pasteFiles), enabled: pasteDestination != nil, to: submenu)
            case .pasteToFolder: add(command.rawValue, action: #selector(pasteToFolder), enabled: true, to: submenu)
            }
        }
        let root = NSMenuItem(title: "mCopy", action: nil, keyEquivalent: "")
        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    func add(_ title: String, action: Selector, enabled: Bool, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    var pasteDestination: URL? {
        FinderMenu.pasteDestination(target: target, selected: selected,
                                    itemMenu: currentMenuKind == .contextualMenuForItems)
    }

    var folderDestination: URL? {
        guard currentMenuKind == .contextualMenuForItems || currentMenuKind == .contextualMenuForSidebar else { return nil }
        return FinderMenu.folderDestination(target: target, selected: selected,
            itemMenu: currentMenuKind == .contextualMenuForItems, isFolder: isFolder)
    }

    func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    @objc func copyFiles(_ sender: Any?) { FinderClipboard.write(selected, move: false) }
    @objc func cutFiles(_ sender: Any?) { FinderClipboard.write(selected, move: true) }
    @objc func pasteFiles(_ sender: Any?) { if let destination = pasteDestination { handoff(destination) } }
    @objc func pasteToFolder(_ sender: Any?) { if let destination = folderDestination { handoff(destination) } }

    func handoff(_ destination: URL) {
        let urls = FinderClipboard.files()
        guard !urls.isEmpty else { return }
        let move = FinderClipboard.operation() == "move"
        let token = UUID().uuidString
        guard FinderClipboard.write(urls, move: move, token: token) else { return }
        var parts = URLComponents()
        parts.scheme = "mycopy"
        parts.host = "paste"
        parts.queryItems = [URLQueryItem(name: "destination", value: destination.path),
                            URLQueryItem(name: "token", value: token)]
        guard let url = parts.url else { return }
        openApp(url)
    }

    func openApp(_ url: URL) {
        // Launch the containing app explicitly, even when another build of myCopy exists.
        let application = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--background"]
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, error in
            if let error { NSLog("myCopy: app handoff error %@", error.localizedDescription) }
        }
    }
}
