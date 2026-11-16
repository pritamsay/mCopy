import XCTest
import AppKit
@testable import MoverCore

final class FinderWorkflowTests: XCTestCase {
    func testClickedFolderWinsOverFinderParentTarget() {
        let parent = URL(fileURLWithPath: "/Users/example/Source")
        let folder = parent.appendingPathComponent("SelectedFolder")
        let folderTarget = FinderMenu.folderDestination(target: parent, selected: [folder], itemMenu: true,
                                                        isFolder: { _ in true })
        XCTAssertEqual(folderTarget, folder)
        XCTAssertEqual(FinderMenu.pasteDestination(target: parent, selected: [folder], itemMenu: true)?.path, parent.path)
    }

    func testClickedFileDoesNotOfferItsParentAsPasteToFolder() {
        let parent = URL(fileURLWithPath: "/Users/example/Source")
        let file = parent.appendingPathComponent("file.txt")
        XCTAssertNil(FinderMenu.folderDestination(target: parent, selected: [file], itemMenu: true,
                                                  isFolder: { $0 == parent }))
        XCTAssertEqual(FinderMenu.pasteDestination(target: parent, selected: [file], itemMenu: true)?.path, parent.path)
    }

    func testFileMenuInitiallyContainsOnlyCopyAndCut() {
        XCTAssertEqual(FinderMenu.commands(hasSelection: true, hasClipboard: false, clickedFolder: false), [.copy, .cut])
    }

    func testFileMenuDoesNotOfferPasteToFolder() {
        XCTAssertEqual(FinderMenu.commands(hasSelection: true, hasClipboard: true, clickedFolder: false), [.copy, .cut, .paste])
    }

    func testFolderMenuOffersBothPasteCommandsAfterSelection() {
        XCTAssertEqual(FinderMenu.commands(hasSelection: true, hasClipboard: true, clickedFolder: true), [.copy, .cut, .paste, .pasteToFolder])
        XCTAssertEqual(FinderMenu.commands(hasSelection: true, hasClipboard: false, clickedFolder: true), [.copy, .cut])
    }

    func testBackgroundMenuOffersPasteOnly() {
        XCTAssertEqual(FinderMenu.commands(hasSelection: false, hasClipboard: true, clickedFolder: false), [.paste])
        XCTAssertTrue(FinderMenu.commands(hasSelection: false, hasClipboard: false, clickedFolder: false).isEmpty)
    }

    func testCutClipboardDoesNotExposeNativeFinderCopyFallback() {
        let pasteboard = NSPasteboard(name: .init("mycopy-test-" + UUID().uuidString))
        defer { pasteboard.clearContents() }
        let file = URL(fileURLWithPath: "/private/tmp/mycopy-sample.txt")
        XCTAssertTrue(FinderClipboard.write([file], move: true, token: "cut", to: pasteboard))
        XCTAssertTrue(FinderClipboard.hasSelection(in: pasteboard))
        XCTAssertEqual(FinderClipboard.files(in: pasteboard), [file])
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) ?? true)
        XCTAssertTrue(FinderClipboard.write([file], move: false, token: "copy", to: pasteboard))
        XCTAssertTrue(FinderClipboard.hasSelection(in: pasteboard))
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) ?? true)
    }

    func testFinishingAnOldMoveDoesNotClearANewClipboard() {
        let pasteboard = NSPasteboard(name: .init("mycopy-test-" + UUID().uuidString))
        defer { pasteboard.clearContents() }
        FinderClipboard.write([URL(fileURLWithPath: "/private/tmp/new.txt")], move: false, token: "new", to: pasteboard)
        FinderClipboard.clear(ifToken: "old", in: pasteboard)
        XCTAssertTrue(FinderClipboard.hasSelection(in: pasteboard))
        FinderClipboard.clear(ifToken: "new", in: pasteboard)
        XCTAssertFalse(FinderClipboard.hasSelection(in: pasteboard))
    }

    func testRequestQueueSurvivesRestartInCreationOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mycopy-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RequestStore(directory: directory)
        var first = TransferRequest(sources: [URL(fileURLWithPath: "/private/tmp/a")], destination: directory, move: true, token: "a")
        first.created = Date(timeIntervalSince1970: 1)
        var second = TransferRequest(sources: [URL(fileURLWithPath: "/private/tmp/b")], destination: directory, move: false, token: "b")
        second.created = Date(timeIntervalSince1970: 2)
        try store.save(second)
        try store.save(first)
        let restarted = RequestStore(directory: directory)
        XCTAssertEqual(try restarted.pending().map(\.id), [first.id, second.id])
        first.cancelled = true
        try restarted.save(first)
        XCTAssertTrue(try XCTUnwrap(restarted.pending().first).cancelled)
        try restarted.remove(first)
        XCTAssertEqual(try restarted.pending().map(\.id), [second.id])
    }
}
