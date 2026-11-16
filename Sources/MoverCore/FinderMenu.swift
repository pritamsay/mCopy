import Foundation

public enum FinderCommand: String {
    case copy = "Copy"
    case cut = "Cut"
    case paste = "Paste"
    case pasteToFolder = "Paste to Folder"
}

public enum FinderMenu {
    public static func pasteDestination(target: URL?, selected: [URL], itemMenu: Bool) -> URL? {
        // In Finder item menus targetedURL can be the containing directory.
        // selectedItemURLs identifies the actual clicked/selected entries.
        if itemMenu { return selected.first?.deletingLastPathComponent() }
        return target
    }

    public static func folderDestination(target: URL?, selected: [URL], itemMenu: Bool,
                                         isFolder: (URL) -> Bool) -> URL? {
        if itemMenu {
            if selected.count == 1, isFolder(selected[0]) { return selected[0] }
            if let target, selected.contains(target), isFolder(target) { return target }
            return nil
        }
        if let target, isFolder(target) { return target }
        return nil
    }

    public static func commands(hasSelection: Bool, hasClipboard: Bool, clickedFolder: Bool) -> [FinderCommand] {
        var commands: [FinderCommand] = []
        if hasSelection { commands += [.copy, .cut] }
        if hasClipboard {
            commands.append(.paste)
            if clickedFolder { commands.append(.pasteToFolder) }
        }
        return commands
    }
}
