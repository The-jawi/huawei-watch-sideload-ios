import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    // Declared in project.yml (UTExportedTypeDeclarations + CFBundleDocumentTypes), so Files offers this app for
    // .hwt in "Open in…" and the share sheet
    static let hwt = UTType(exportedAs: "com.huasideload.hwt", conformingTo: .data)
}

// Watch faces kept by the app, in Documents/Watch Faces (also visible in the Files app: On My iPhone > HuaSideload).
// Every .hwt that reaches the app (the in-app picker, Open In / share sheet from Files, AirDrop) is copied here first,
// so nothing depends on a security-scoped URL or an iCloud file that may go away. A file is kept only if it reads as a
// watch face package (WatchFacePackage); the same file imported twice is recognised by its SHA-256.
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
        var screen: String
        var version: String
        var size: Int
        var importedAt: Date
        var favorite = false
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
        case tooLarge(Int)
        case notAWatchFace(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let size):
                return L("The file is too large for a watch face (\(size / 1_048_576) MB)", "Dosya bir kadran için çok büyük (\(size / 1_048_576) MB)")
            case .notAWatchFace(let why):
                return L("Not a watch face package: ", "Kadran paketi değil: ") + why
            }
        }
    }

    // Watch faces are a few MB at most; anything far larger is not one
    nonisolated static let maxSize = 64 * 1_048_576

    @Published private(set) var entries: [Entry] = []
    let directory: URL

    static let shared = FaceLibrary(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Watch Faces", isDirectory: true))

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private var indexURL: URL { directory.appendingPathComponent(".library.json") }

    func url(for entry: Entry) -> URL { directory.appendingPathComponent(entry.fileName) }

    // Favorites first, then the newest import; optionally only titles containing the search text
    func visible(search: String = "") -> [Entry] {
        let text = search.trimmingCharacters(in: .whitespaces)
        return entries
            .filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) || $0.fileName.localizedCaseInsensitiveContains(text) }
            .sorted { ($0.favorite ? 1 : 0, $0.importedAt) > ($1.favorite ? 1 : 0, $1.importedAt) }
    }

    func importFile(at source: URL) async throws -> ImportOutcome {
        defer { Self.removeIfInbox(source) }
        let (data, package) = try await Self.readPackage(source)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = entries.first(where: { $0.id == id }) { return .duplicate(existing) }

        let base = package.title == "?" ? source.deletingPathExtension().lastPathComponent : package.title
        let fileName = uniqueFileName(Self.sanitized(base))
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        let entry = Entry(id: id, fileName: fileName, title: package.title == "?" ? base : package.title, screen: package.screen,
                          version: package.version, size: data.count, importedAt: Date())
        entries.append(entry)
        save()
        return .added(entry)
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: url(for: entry))
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func toggleFavorite(_ entry: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].favorite.toggle()
        save()
    }

    func recordInstall(_ entry: Entry, result: String, succeeded: Bool, at date: Date = Date()) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].lastInstall = InstallRecord(date: date, result: result, succeeded: succeeded)
        save()
    }

    // .hwt files put into the folder another way (e.g. copied in the Files app) join the library
    func adoptUntrackedFiles() async {
        let known = Set(entries.map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "hwt" && !known.contains(file.lastPathComponent) {
            guard let read = try? await Self.readPackage(file) else { continue }
            let (data, package) = read
            let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard !entries.contains(where: { $0.id == id }) else { continue }
            entries.append(Entry(id: id, fileName: file.lastPathComponent, title: package.title, screen: package.screen,
                                 version: package.version, size: data.count, importedAt: Date()))
        }
        save()
    }

    // MARK: - Files

    // Off the main thread: security-scoped access (files picked from other providers) and a coordinated read
    // (lets iCloud Drive and other file providers download the file first)
    nonisolated static func readPackage(_ url: URL) async throws -> (Data, WatchFacePackage) {
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
            if let coordinationError { throw coordinationError }
            let data = try result.get()
            guard data.count <= maxSize else { throw LibraryError.tooLarge(data.count) }
            do {
                return (data, try WatchFacePackage(hwt: data))
            } catch {
                throw LibraryError.notAWatchFace(error.localizedDescription)
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
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
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
