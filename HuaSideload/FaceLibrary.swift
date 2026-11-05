import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    // App-specific type for .hwt, declared in project.yml (UTExportedTypeDeclarations + CFBundleDocumentTypes), so
    // Files offers this app in "Open in…" and the share sheet
    static let hwt = UTType(exportedAs: "com.huasideload.hwt", conformingTo: .data)
}

// Watch faces kept by the app in Application Support/Watch Faces. Every .hwt that reaches the app (the picker, Open In
// or share sheet from Files, AirDrop) is read while its security-scoped access is open and copied here unchanged, so
// it stays usable after the picker closes and after a restart. Each copy is analyzed (HWTAnalyzer); corrupted files
// are refused with the reasons, everything else is kept, UNKNOWN included. The same file twice is recognised by its
// SHA-256. Deleting removes only the copy on this iPhone.
@MainActor
final class FaceLibrary: ObservableObject {
    struct InstallRecord: Codable, Equatable {
        var date: Date
        var result: String
        var succeeded: Bool
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id: String          // SHA-256 of the file
        var fileName: String
        var title: String
        var size: Int
        var importedAt: Date
        var analysis: HWTAnalysis
        var hasPreview = false
        var lastInstall: InstallRecord?
    }

    enum ImportOutcome: Equatable {
        case added(Entry)
        case duplicate(Entry)

        var entry: Entry {
            switch self {
            case .added(let e), .duplicate(let e): return e
            }
        }
    }

    enum LibraryError: LocalizedError, Equatable {
        case inaccessible(String)
        case tooLarge(Int)
        case corrupted([String])

        var errorDescription: String? {
            switch self {
            case .inaccessible(let why):
                return L("The file could not be read: ", "Dosya okunamadı: ") + why
            case .tooLarge(let size):
                return L("The file is too large for a watch face (\(size / 1_048_576) MB)", "Dosya bir kadran için çok büyük (\(size / 1_048_576) MB)")
            case .corrupted(let reasons):
                return HWTAnalysis.Status.corrupted.label + ": " + reasons.joined(separator: "; ")
            }
        }
    }

    // Watch faces are a few MB at most; anything far larger is not one
    nonisolated static let maxSize = 64 * 1_048_576

    @Published private(set) var entries: [Entry] = []
    let directory: URL
    let target: TargetProfile

    static let shared = FaceLibrary(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Watch Faces", isDirectory: true))

    init(directory: URL, target: TargetProfile = .fit4Pro) {
        self.directory = directory
        self.target = target
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private var indexURL: URL { directory.appendingPathComponent("library.json") }

    func url(for entry: Entry) -> URL { directory.appendingPathComponent(entry.fileName) }
    func previewURL(for entry: Entry) -> URL { directory.appendingPathComponent(entry.id + ".preview") }

    func importFile(at source: URL) async throws -> ImportOutcome {
        defer { Self.removeIfInbox(source) }
        let data = try await Self.read(source)
        try Task.checkCancellation()
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = entries.first(where: { $0.id == id }) { return .duplicate(existing) }

        let target = self.target
        let result = await Task.detached(priority: .userInitiated) { HWTAnalyzer.analyze(data, target: target) }.value
        guard result.analysis.status != .corrupted else { throw LibraryError.corrupted(result.analysis.reasons) }
        try Task.checkCancellation()

        let title = result.analysis.title.isEmpty ? source.deletingPathExtension().lastPathComponent : result.analysis.title
        let fileName = uniqueFileName(Self.sanitized(title))
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        var entry = Entry(id: id, fileName: fileName, title: title, size: data.count, importedAt: Date(), analysis: result.analysis)
        if let preview = result.preview, (try? Data(preview).write(to: previewURL(for: entry), options: .atomic)) != nil {
            entry.hasPreview = true
        }
        entries.append(entry)
        save()
        return .added(entry)
    }

    // Newest import first
    var sorted: [Entry] { entries.sorted { $0.importedAt > $1.importedAt } }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: url(for: entry))
        try? FileManager.default.removeItem(at: previewURL(for: entry))
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func recordInstall(_ entry: Entry, result: String, succeeded: Bool, at date: Date = Date()) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].lastInstall = InstallRecord(date: date, result: result, succeeded: succeeded)
        save()
    }

    // MARK: - Files

    // Off the main thread, while the security-scoped access is open: a coordinated read lets iCloud Drive and other
    // file providers download the file first
    nonisolated static func read(_ url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxSize {
                throw LibraryError.tooLarge(size)
            }
            var coordinationError: NSError?
            var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
                result = Result { try Data(contentsOf: readURL) }
            }
            do {
                if let coordinationError { throw coordinationError }
                let data = try result.get()
                guard data.count <= maxSize else { throw LibraryError.tooLarge(data.count) }
                return data
            } catch let error as LibraryError {
                throw error
            } catch {
                throw LibraryError.inaccessible(error.localizedDescription)
            }
        }.value
    }

    // "Open in…" from another app hands over a copy in Documents/Inbox; it is in the library now
    nonisolated static func removeIfInbox(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == "Inbox",
              url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Documents" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\0").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        return String((cleaned.isEmpty ? "Watch face" : cleaned).prefix(80))
    }

    private func uniqueFileName(_ base: String) -> String {
        var name = base + ".hwt"
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(base) \(n).hwt"
            n += 1
        }
        return name
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = saved.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
