import AppKit

public enum FinderClipboard {
    public static let operationType = NSPasteboard.PasteboardType("local.pritam.mycopy.operation")
    public static let tokenType = NSPasteboard.PasteboardType("local.pritam.mycopy.request-token")
    public static let pathsType = NSPasteboard.PasteboardType("local.pritam.mycopy.paths")
    static let changeType = NSPasteboard.PasteboardType("local.pritam.mycopy.clipboard-change")
    static let selection = NSPasteboard(name: .init("local.pritam.mycopy.selection"))

    // Share only our own selection through a named pasteboard. We never read
    // another app's general clipboard, including while Finder builds a menu.
    static func storage(_ pasteboard: NSPasteboard) -> NSPasteboard { pasteboard.name == .general ? selection : pasteboard }

    static func isCurrent(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.name != .general { return true }
        return pasteboard.types?.contains(tokenType) == true &&
            selection.string(forType: changeType) == String(pasteboard.changeCount)
    }

    public static func token(in pasteboard: NSPasteboard = .general) -> String? {
        guard isCurrent(pasteboard) else { return nil }
        return storage(pasteboard).string(forType: tokenType)
    }

    public static func operation(in pasteboard: NSPasteboard = .general) -> String? {
        guard isCurrent(pasteboard) else { return nil }
        return storage(pasteboard).string(forType: operationType)
    }

    public static func hasSelection(in pasteboard: NSPasteboard = .general) -> Bool {
        let operation = operation(in: pasteboard)
        return (operation == "copy" || operation == "move") &&
            token(in: pasteboard) != nil && !files(in: pasteboard).isEmpty
    }

    public static func clear(ifToken token: String, in pasteboard: NSPasteboard = .general) {
        if self.token(in: pasteboard) == token {
            storage(pasteboard).clearContents()
            if pasteboard.name == .general { pasteboard.clearContents() }
        }
    }

    public static func files(in pasteboard: NSPasteboard = .general) -> [URL] {
        guard isCurrent(pasteboard) else { return [] }
        let pasteboard = storage(pasteboard)
        if let data = pasteboard.data(forType: pathsType),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    @discardableResult
    public static func write(_ urls: [URL], move: Bool, token: String = UUID().uuidString,
                             to pasteboard: NSPasteboard = .general) -> Bool {
        guard !urls.isEmpty else { return false }
        let item = NSPasteboardItem()
        guard let data = try? JSONEncoder().encode(urls.map(\.path)) else { return false }
        item.setData(data, forType: pathsType)
        item.setString(move ? "move" : "copy", forType: operationType)
        item.setString(token, forType: tokenType)
        // Private clipboard types keep these transfers inside mCopy. Advertising
        // public file URLs can fail sandbox extension creation inside Finder Sync.
        if pasteboard.name == .general {
            let marker = NSPasteboardItem()
            marker.setString(token, forType: tokenType)
            pasteboard.clearContents()
            guard pasteboard.writeObjects([marker]) else { return false }
            item.setString(String(pasteboard.changeCount), forType: changeType)
        }
        let storage = storage(pasteboard)
        storage.clearContents()
        return storage.writeObjects([item])
    }
}
