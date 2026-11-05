import UniformTypeIdentifiers
import XCTest
@testable import HuaSideloadParsing

// Importing .hwt files into the app's own library: copy, analyze, de-duplicate, persist
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

    private func file(_ name: String, _ data: Data, in dir: URL? = nil) throws -> URL {
        let folder = dir ?? root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func package(title: String = "Night Sky", screen: String = "HWHD13", bin: [UInt8] = [1, 2, 3]) -> Data {
        var o = TestHWT.Options()
        o.title = title
        o.screen = screen
        o.bin = bin
        return TestHWT.package(o)
    }

    private func storedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: libraryDir.path)) ?? []).filter { $0.hasSuffix(".hwt") }.sorted()
    }

    // MARK: - Import

    func testImportCopiesAnalyzesAndPersists() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let source = try file("download.hwt", package())
        guard case .added(let entry) = try await library.importFile(at: source) else { return XCTFail() }
        XCTAssertEqual(entry.title, "Night Sky")
        XCTAssertEqual(entry.fileName, "Night Sky.hwt")
        XCTAssertEqual(entry.analysis.status, .compatible)
        XCTAssertEqual(entry.id.count, 64)
        XCTAssertTrue(entry.hasPreview)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.previewURL(for: entry).path))
        XCTAssertEqual(storedFiles(), ["Night Sky.hwt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))     // the original is left alone
        XCTAssertEqual(try Data(contentsOf: library.url(for: entry)), try Data(contentsOf: source))   // copied unchanged

        XCTAssertEqual(FaceLibrary(directory: libraryDir).entries, [entry])   // after a restart
    }

    func testRealSampleIsKeptAsIncompatible() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let entry = try await library.importFile(at: try file("Donen.hwt", try TestHWT.sample("Donen.hwt"))).entry
        XCTAssertEqual(entry.analysis.status, .incompatible)
        XCTAssertEqual(entry.title, "Donen")
    }

    func testUnknownFilesAreKept() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let entry = try await library.importFile(at: try file("x.hwt", package(screen: "HWHD99"))).entry
        XCTAssertEqual(entry.analysis.status, .unknown)
        XCTAssertEqual(library.entries.count, 1)
    }

    func testSameFileTwiceIsADuplicate() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let data = package()
        _ = try await library.importFile(at: try file("a.hwt", data))
        guard case .duplicate = try await library.importFile(at: try file("renamed copy.hwt", data)) else { return XCTFail() }
        XCTAssertEqual(library.entries.count, 1)
        XCTAssertEqual(storedFiles(), ["Night Sky.hwt"])
    }

    func testDifferentFacesWithTheSameTitleGetUniqueNames() async throws {
        let library = FaceLibrary(directory: libraryDir)
        _ = try await library.importFile(at: try file("1.hwt", package(title: "Face", bin: [1])))
        _ = try await library.importFile(at: try file("2.hwt", package(title: "Face", bin: [2])))
        XCTAssertEqual(storedFiles(), ["Face 2.hwt", "Face.hwt"])
    }

    func testCorruptedFilesAreRefusedWithReasons() async throws {
        let library = FaceLibrary(directory: libraryDir)
        var damaged = TestHWT.Options()
        damaged.badCRC = ["description.xml"]
        for (name, data) in [("photo.hwt", Data(TestHWT.jpeg(10, 10))), ("damaged.hwt", TestHWT.package(damaged))] {
            do {
                _ = try await library.importFile(at: try file(name, data))
                XCTFail("\(name) was accepted")
            } catch let error as FaceLibrary.LibraryError {
                guard case .corrupted(let reasons) = error else { return XCTFail("\(error)") }
                XCTAssertFalse(reasons.isEmpty)
                XCTAssertTrue(error.localizedDescription.hasPrefix("CORRUPTED"))
            }
        }
        XCTAssertEqual(storedFiles(), [])
        XCTAssertEqual(library.entries, [])
    }

    func testUnreadableFileIsAnAccessError() async {
        let library = FaceLibrary(directory: libraryDir)
        do {
            _ = try await library.importFile(at: root.appendingPathComponent("gone.hwt"))
            XCTFail("expected an error")
        } catch let error as FaceLibrary.LibraryError {
            guard case .inaccessible = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(library.entries, [])
    }

    func testCancelledImportStoresNothing() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let source = try file("a.hwt", package())
        let task = Task { try await library.importFile(at: source) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(storedFiles(), [])
        XCTAssertEqual(library.entries, [])
    }

    func testOpenInCopyIsRemovedFromInbox() async throws {
        let incoming = try file("shared.hwt", package(title: "Shared"), in: root.appendingPathComponent("Documents/Inbox"))
        let library = FaceLibrary(directory: libraryDir)
        _ = try await library.importFile(at: incoming)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertEqual(storedFiles(), ["Shared.hwt"])
    }

    // MARK: - Library operations

    func testDeleteRemovesOnlyTheLocalCopy() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let entry = try await library.importFile(at: try file("a.hwt", package())).entry
        library.delete(entry)
        XCTAssertEqual(storedFiles(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.previewURL(for: entry).path))
        XCTAssertEqual(FaceLibrary(directory: libraryDir).entries, [])
    }

    func testEntriesWithMissingFilesAreDropped() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let entry = try await library.importFile(at: try file("a.hwt", package())).entry
        try FileManager.default.removeItem(at: library.url(for: entry))
        XCTAssertEqual(FaceLibrary(directory: libraryDir).entries, [])
    }

    func testNewestFirstAndInstallHistory() async throws {
        let library = FaceLibrary(directory: libraryDir)
        let first = try await library.importFile(at: try file("1.hwt", package(title: "Ocean", bin: [1]))).entry
        _ = try await library.importFile(at: try file("2.hwt", package(title: "Forest", bin: [2])))
        XCTAssertEqual(library.sorted.map(\.title), ["Forest", "Ocean"])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        library.recordInstall(first, result: WatchFaceInstallStage.installed.label, succeeded: true, at: date)
        let saved = FaceLibrary(directory: libraryDir).entries.first { $0.id == first.id }?.lastInstall
        XCTAssertEqual(saved, FaceLibrary.InstallRecord(date: date, result: WatchFaceInstallStage.installed.label, succeeded: true))
    }

    // MARK: - Helpers

    func testSanitizedNames() {
        XCTAssertEqual(FaceLibrary.sanitized("a/b:c?"), "a-b-c")
        XCTAssertEqual(FaceLibrary.sanitized("  ..  "), "Watch face")
        XCTAssertEqual(FaceLibrary.sanitized(String(repeating: "x", count: 200)).count, 80)
    }

    // Its conformance comes from the app's Info.plist (UTExportedTypeDeclarations), which the test process does not
    // load; the CI step "Verify .hwt document registration" checks it in the built app
    func testType() {
        XCTAssertEqual(UTType.hwt.identifier, "com.huasideload.hwt")
    }
}
