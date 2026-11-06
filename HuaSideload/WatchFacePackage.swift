import Compression
import Foundation

// Huawei watch face package (.hwt, exported by Huawei Theme Studio): a zip holding description.xml,
// preview/cover.jpg and com.huawei.watchface, which is itself a zip with watchface.bin (older packages
// carry the bin directly). Like Gadgetbridge, only watchface.bin is uploaded (file type 1).
struct WatchFacePackage {
    let title: String
    let screen: String
    let version: String
    let bin: [UInt8]
    let package: [UInt8]        // com.huawei.watchface as stored in the .hwt (WatchFaceUploadMethod)
    // What the archive holds, for the pre-install check (sizes and names only)
    let root: String            // HwTheme (Huawei) or HnTheme (Honor)
    let files: [String]
    let binWasZipped: Bool      // com.huawei.watchface was a zip holding watchface.bin (newer packages)
    let hasPreview: Bool

    // Problems that do not stop the upload but are worth showing
    var warnings: [String] {
        var list: [String] = []
        if root != "HwTheme" && root != "HnTheme" {
            list.append(L("description.xml has no HwTheme/HnTheme root", "description.xml'de HwTheme/HnTheme kökü yok"))
        }
        if screen == "?" { list.append(L("no <screen> in description.xml", "description.xml'de <screen> yok")) }
        if version == "?" { list.append(L("no <version> in description.xml", "description.xml'de <version> yok")) }
        if !hasPreview { list.append(L("no preview/cover.jpg", "preview/cover.jpg yok")) }
        if bin.isEmpty { list.append(L("watchface.bin is empty", "watchface.bin boş")) }
        return list
    }

    enum PackageError: LocalizedError {
        case notZip
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .notZip: return L("This is not a watch face package (.hwt)", "Bu bir kadran paketi (.hwt) değil")
            case .missing(let name): return L("The package has no \(name)", "Pakette \(name) yok")
            }
        }
    }

    init(hwt data: Data) throws {
        let outer = try ZipArchive([UInt8](data))
        guard var xml = outer.file("description.xml") else { throw PackageError.missing("description.xml") }
        if xml.starts(with: [0xEF, 0xBB, 0xBF]) { xml.removeFirst(3) }
        let text = String(decoding: xml, as: UTF8.self)
        title = Self.tag("title", in: text) ?? "?"
        screen = Self.tag("screen", in: text) ?? "?"
        version = Self.tag("version", in: text) ?? "?"
        root = text.contains("<HnTheme") ? "HnTheme" : (text.contains("<HwTheme") ? "HwTheme" : "?")
        files = outer.names
        hasPreview = outer.names.contains("preview/cover.jpg")
        guard let inner = outer.file("com.huawei.watchface") ?? outer.file("com.honor.watchface") else {
            throw PackageError.missing("com.huawei.watchface")
        }
        package = inner
        if let innerZip = try? ZipArchive(inner), let bin = innerZip.file("watchface.bin") {
            self.bin = bin
            binWasZipped = true
        } else {
            self.bin = inner
            binWasZipped = false
        }
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"), let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Watch faces bundled inside the iPhone app (WatchFaces/*.hwt); each shows up with an "Install" button.
// The file name is the name shown in the app.
enum WatchFaceCatalog {
    static let all: [URL] = (Bundle.main.urls(forResourcesWithExtension: "hwt", subdirectory: nil) ?? [])
        .sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }

    // Screen code of each bundled face (description.xml), read once
    static let screens: [URL: String] = Dictionary(uniqueKeysWithValues: all.compactMap { url in
        (try? Data(contentsOf: url)).flatMap { try? WatchFacePackage(hwt: $0) }.map { (url, $0.screen) }
    })
}

// Minimal zip reader: central directory, stored (0) and deflate (8) entries; no zip64.
struct ZipArchive {
    private let bytes: [UInt8]
    private var entries: [String: (method: Int, compressed: Int, size: Int, offset: Int, crc: UInt32)] = [:]

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        // End of central directory record, searched from the end (the comment can be up to 64 KB)
        guard bytes.count >= 22 else { throw WatchFacePackage.PackageError.notZip }
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 22 - 65_535) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw WatchFacePackage.PackageError.notZip }
        let count = Self.u16(bytes, eocd + 10)
        var p = Self.u32(bytes, eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= bytes.count, Self.u32(bytes, p) == 0x0201_4B50 else { throw WatchFacePackage.PackageError.notZip }
            let method = Self.u16(bytes, p + 10)
            let crc = UInt32(Self.u32(bytes, p + 16))
            let compressed = Self.u32(bytes, p + 20)
            let size = Self.u32(bytes, p + 24)
            let nameLength = Self.u16(bytes, p + 28)
            let extraLength = Self.u16(bytes, p + 30)
            let commentLength = Self.u16(bytes, p + 32)
            let local = Self.u32(bytes, p + 42)
            guard p + 46 + nameLength <= bytes.count else { throw WatchFacePackage.PackageError.notZip }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries[name] = (method, compressed, size, local, crc)
            p += 46 + nameLength + extraLength + commentLength
        }
    }

    var names: [String] { entries.keys.sorted() }

    // The stored CRC-32 of an entry and its compression method (HWTAnalyzer checks every entry against it)
    func info(_ name: String) -> (method: Int, crc: UInt32, size: Int)? {
        entries[name].map { ($0.method, $0.crc, $0.size) }
    }

    func file(_ name: String) -> [UInt8]? {
        guard let entry = entries[name], entry.offset + 30 <= bytes.count, Self.u32(bytes, entry.offset) == 0x0403_4B50 else {
            return nil
        }
        let start = entry.offset + 30 + Self.u16(bytes, entry.offset + 26) + Self.u16(bytes, entry.offset + 28)
        guard start + entry.compressed <= bytes.count else { return nil }
        let data = Array(bytes[start..<(start + entry.compressed)])
        switch entry.method {
        case 0:
            return data
        case 8:
            // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what zip uses
            var output = [UInt8](repeating: 0, count: max(entry.size, 1))
            let written = data.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { target in
                    compression_decode_buffer(target.baseAddress!, entry.size, source.baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            return written == entry.size ? Array(output.prefix(written)) : nil
        default:
            return nil
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }
}
