import AppKit

public enum FinderClipboard {
    public static let operationType = NSPasteboard.PasteboardType("local.pritam.mycopy.operation")
    public static let tokenType = NSPasteboard.PasteboardType("local.pritam.mycopy.request-token")
    public static let pathsType = NSPasteboard.PasteboardType("local.pritam.mycopy.paths")

    public static func hasSelection(in pasteboard: NSPasteboard = .general) -> Bool {
        let operation = pasteboard.string(forType: operationType)
        return (operation == "copy" || operation == "move") &&
            pasteboard.string(forType: tokenType) != nil && !files(in: pasteboard).isEmpty
    }

    public static func clear(ifToken token: String, in pasteboard: NSPasteboard = .general) {
        if pasteboard.string(forType: tokenType) == token { pasteboard.clearContents() }
    }

    public static func files(in pasteboard: NSPasteboard = .general) -> [URL] {
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
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
