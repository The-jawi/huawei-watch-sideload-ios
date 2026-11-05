import UniformTypeIdentifiers
import XCTest
@testable import HuaSideloadParsing

// Importing .hwt files into the app's own library: copy, validate, de-duplicate, persist
@MainActor
final class FaceLibraryTests: XCTestCase {
    private var root: URL!
    private var libraryDir: URL { root.appendingPathComponent("Library") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FaceLibraryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.set("en", forKey: AppLanguage.storageKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Test packages (stored zip entries)

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }

    private func zip(_ files: [(String, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for (name, data) in files {
            let offset = out.count
            let n = Array(name.utf8)
            out += le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(data.count) + le32(data.count) + le16(n.count) + le16(0) + n + data
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(data.count) + le32(data.count) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(offset) + n
        }
        let centralOffset = out.count
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(centralOffset) + le16(0)
        return out
    }

    private func hwt(title: String, screen: String = "HWHD13", body: [UInt8] = [1, 2, 3]) -> Data {
        let xml = "<HwTheme><title>\(title)</title><screen>\(screen)</screen><version>1.2.3</version></HwTheme>"
        return Data(zip([("description.xml", Array(xml.utf8)), ("com.huawei.watchface", zip([("watchface.bin", body)])),
                         ("preview/cover.jpg", [0xFF])]))
    }

    private func file(_ name: String, _ data: Data, in dir: URL? = nil) throws -> URL {
        let folder = dir ?? root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: libraryDir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: - Import

    func testImportCopiesValidatesAndPersists() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let source = try file("download.hwt", hwt(title: "Night Sky"))
        let outcome = try await library.importFile(at: source)
        guard case .added(let entry) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(entry.title, "Night Sky")
        XCTAssertEqual(entry.screen, "HWHD13")
        XCTAssertEqual(entry.version, "1.2.3")
        XCTAssertEqual(entry.fileName, "Night Sky.hwt")
        XCTAssertEqual(entry.id.count, 64)
        XCTAssertEqual(files(), ["Night Sky.hwt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))     // the original is left alone
        XCTAssertEqual(try Data(contentsOf: library.url(for: entry)), try Data(contentsOf: source))

        let reopened = FaceLibrary(directory: libraryDir)
        XCTAssertEqual(reopened.entries, [entry])
    }

    func testSameFileTwiceIsADuplicate() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let data = hwt(title: "Night Sky")
        _ = try await library.importFile(at: try file("a.hwt", data))
        let second = try await library.importFile(at: try file("renamed copy.hwt", data))
        guard case .duplicate = second else { return XCTFail("\(second)") }
        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(files(), ["Night Sky.hwt"])
    }

    func testDifferentFacesWithTheSameTitleGetUniqueNames() async throws {
        let library = FaceLibrary(directory: libraryDir)
        _ = try await library.importFile(at: try file("1.hwt", hwt(title: "Face", body: [1])))
        _ = try await library.importFile(at: try file("2.hwt", hwt(title: "Face", body: [2])))
        XCTAssertEqual(files(), ["Face 2.hwt", "Face.hwt"])
    }

    func testNonWatchFacesAreRejectedAndNotKept() async throws {
        let library = FaceLibrary(directory: libraryDir)
        for (name, data) in [("photo.hwt", Data([0xFF, 0xD8, 0xFF])), ("archive.hwt", Data(zip([("readme.txt", [1])])))] {
            do {
                _ = try await library.importFile(at: try file(name, data))
                XCTFail("\(name) was accepted")
            } catch let error as FaceLibrary.LibraryError {
                guard case .notAWatchFace = error else { return XCTFail("\(error)") }
                XCTAssertTrue(error.localizedDescription.hasPrefix("Not a watch face package"))
            }
        }
        XCTAssertEqual(files(), [])
        XCTAssertEqual(library.entries, [])
    }

    func testMissingSourceFileThrows() async {
        let library = FaceLibrary(directory: libraryDir)
        do {
            _ = try await library.importFile(at: root.appendingPathComponent("nope.hwt"))
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(library.entries, [])
    }

    func testOpenInCopyIsRemovedFromInbox() async throws {
        let inbox = root.appendingPathComponent("Documents/Inbox")
        let incoming = try file("shared.hwt", hwt(title: "Shared"), in: inbox)
        let library = FaceLibrary(directory: libraryDir)
        _ = try await library.importFile(at: incoming)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertEqual(files(), ["Shared.hwt"])
    }

    func testFilesDroppedIntoTheFolderAreAdopted() async throws {
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        _ = try file("Dropped.hwt", hwt(title: "Dropped In"), in: libraryDir)
        _ = try file("notes.txt", Data("x".utf8), in: libraryDir)
        let library = FaceLibrary(directory: libraryDir)
        await library.adoptUntrackedFiles()
        XCTAssertEqual(library.entries.map(\.title), ["Dropped In"])
        XCTAssertEqual(library.entries.first?.fileName, "Dropped.hwt")
    }

    // MARK: - Library operations

    func testDeleteRemovesOnlyTheLocalCopy() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let entry = try await library.importFile(at: try file("a.hwt", hwt(title: "A"))).entry
        library.delete(entry)
        XCTAssertEqual(files(), [])
        XCTAssertEqual(FaceLibrary(directory: libraryDir).entries, [])
    }

    func testEntriesWithMissingFilesAreDropped() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let entry = try await library.importFile(at: try file("a.hwt", hwt(title: "A"))).entry
        try FileManager.default.removeItem(at: library.url(for: entry))
        XCTAssertEqual(FaceLibrary(directory: libraryDir).entries, [])
    }

    func testFavoritesSortFirstAndSearchFilters() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let old = try await library.importFile(at: try file("1.hwt", hwt(title: "Ocean", body: [1]))).entry
        _ = try await library.importFile(at: try file("2.hwt", hwt(title: "Forest", body: [2])))
        XCTAssertEqual(library.visible().map(\.title), ["Forest", "Ocean"])       // newest first
        library.toggleFavorite(old)
        XCTAssertEqual(library.visible().map(\.title), ["Ocean", "Forest"])       // favorite first
        XCTAssertEqual(library.visible(search: "fOr").map(\.title), ["Forest"])
        XCTAssertEqual(library.visible(search: "  ").count, 2)
        XCTAssertTrue(FaceLibrary(directory: libraryDir).entries.first { $0.id == old.id }?.favorite == true)
    }

    func testInstallHistoryIsKept() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let entry = try await library.importFile(at: try file("a.hwt", hwt(title: "A"))).entry
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        library.recordInstall(entry, result: WatchFaceInstallStage.installed.label, succeeded: true, at: date)
        let saved = FaceLibrary(directory: libraryDir).entries.first?.lastInstall
        XCTAssertEqual(saved, FaceLibrary.InstallRecord(date: date, result: WatchFaceInstallStage.installed.label, succeeded: true))
    }

    // MARK: - Helpers

    func testSanitizedNames() {
        XCTAssertEqual(FaceLibrary.sanitized("a/b:c?"), "a-b-c")
        XCTAssertEqual(FaceLibrary.sanitized("  ..  "), "Watch face")
        XCTAssertEqual(FaceLibrary.sanitized(String(repeating: "x", count: 200)).count, 80)
    }

    func testType() {
        XCTAssertEqual(UTType.hwt.identifier, "com.huasideload.hwt")
        XCTAssertTrue(UTType.hwt.conforms(to: .data))
    }
}
